package dev.notifie

import android.content.Context
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow
import kotlin.random.Random

internal data class HttpResult(val status: Int, val error: Throwable? = null) {
    val delivered: Boolean get() = status in 200..299
    val permanent: Boolean get() = status in 400..499 && status != 429
    val retryable: Boolean get() = status == 0 || status == 429 || status >= 500
}

internal fun interface NotifieTransport {
    fun send(method: String, url: String, apiKey: String, body: String): HttpResult
}

private class UrlConnectionTransport : NotifieTransport {
    override fun send(method: String, url: String, apiKey: String, body: String): HttpResult {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = method
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Authorization", "Bearer $apiKey")
            connection.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
            connection.doOutput = true
            connection.outputStream.use { output ->
                output.write(body.toByteArray(Charsets.UTF_8))
            }
            val status = connection.responseCode
            (if (status in 200..299) connection.inputStream else connection.errorStream)?.use {
                it.readBytes()
            }
            HttpResult(status)
        } catch (error: Exception) {
            HttpResult(0, error)
        } finally {
            connection.disconnect()
        }
    }
}

internal class NotifieClient(
    context: Context,
    private val apiKey: String,
    private val baseUrl: String,
    private val batchSize: Int = 20,
    private val flushIntervalSeconds: Long = 30,
    private val maxQueueSize: Int = 1000,
    private val transport: NotifieTransport = UrlConnectionTransport(),
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor(),
) {
    private val preferences = context.applicationContext
        .getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
    private val queueLock = Any()
    private val identityLock = Any()
    private var retryCount = 0
    private var retryScheduled = false
    private var retryAtMillis = 0L

    init {
        require(apiKey.isNotBlank()) { "API key cannot be empty." }
        require(batchSize in 1..maxBatchSize) { "batchSize must be between 1 and $maxBatchSize." }
        require(maxQueueSize >= batchSize) { "maxQueueSize must be at least batchSize." }
        executor.scheduleWithFixedDelay(
            { flushAll() },
            flushIntervalSeconds,
            flushIntervalSeconds,
            TimeUnit.SECONDS,
        )
        executor.execute { flushAll() }
    }

    fun anonymousId(): String = synchronized(identityLock) {
        val existing = preferences.getString(anonymousIdKey, null)
        if (!existing.isNullOrBlank()) existing
        else UUID.randomUUID().toString().lowercase().also {
            preferences.edit().putString(anonymousIdKey, it).commit()
        }
    }

    fun currentUserId(): String? = synchronized(identityLock) {
        preferences.getString(userIdKey, null)
    }

    fun identify(userId: String, properties: Map<String, Any?>) {
        require(userId.isNotBlank()) { "userId cannot be empty." }
        validateProperties(properties)
        synchronized(identityLock) {
            val retainedToken = preferences.getString(retainedPushTokenKey, null)
            preferences.edit()
                .putString(userIdKey, userId)
                .apply {
                    if (!retainedToken.isNullOrBlank()) {
                        putString(pushTokenKey, retainedToken)
                        remove(retainedPushTokenKey)
                    }
                }
                .commit()
            val payload = JSONObject()
                .put("userId", userId)
                .put("anonymousId", anonymousId())
                .put("properties", JSONObject(properties))
                .put("timestamp", timestamp())
            preferences.edit()
                .putString(pendingIdentifyKey, payload.toString())
                .remove(lastTokenRegistrationKey)
                .commit()
        }
        executor.execute { flushAll() }
    }

    fun track(
        eventName: String,
        properties: Map<String, Any?> = emptyMap(),
        messageId: String = UUID.randomUUID().toString().lowercase(),
    ) {
        require(eventName.matches(eventNamePattern)) {
            "Event name must start alphanumeric and contain only letters, numbers, spaces, _ . : -."
        }
        require(eventName.length <= 64) { "Event name must be at most 64 characters." }
        validateProperties(properties)
        val (userId, anonymousId) = identitySnapshot()
        val event = JSONObject()
            .put("messageId", messageId)
            .put("event", eventName)
            .put("timestamp", timestamp())
            .put("anonymousId", anonymousId)
            .put("properties", JSONObject(properties))
        userId?.let { event.put("userId", it) }

        val shouldFlush = synchronized(queueLock) {
            val queue = readQueue()
            queue.put(event)
            while (queue.length() > maxQueueSize) removeFirst(queue)
            writeQueue(queue)
            queue.length() >= batchSize
        }
        if (shouldFlush) executor.execute { flushEvents() }
    }

    fun registerPushToken(token: String, onResult: ((Boolean) -> Unit)? = null) {
        if (token.isBlank()) {
            onResult?.invoke(false)
            return
        }
        synchronized(identityLock) {
            preferences.edit()
                .putString(pushTokenKey, token)
                .remove(retainedPushTokenKey)
                .remove(lastTokenRegistrationKey)
                .commit()
        }
        executor.execute {
            val registered = flushPushTokenRegistration()
            onResult?.invoke(registered)
        }
    }

    fun reset() {
        val token = synchronized(identityLock) {
            preferences.getString(pushTokenKey, null)?.takeIf { it.isNotBlank() }
        }
        token?.let(::enqueueRevocation)
        synchronized(queueLock) {
            synchronized(identityLock) {
                preferences.edit()
                    .remove(queueKey)
                    .remove(userIdKey)
                    .remove(anonymousIdKey)
                    .remove(pendingIdentifyKey)
                    .remove(pushTokenKey)
                    .remove(lastTokenRegistrationKey)
                    .apply {
                        if (token != null) putString(retainedPushTokenKey, token)
                    }
                    .commit()
            }
        }
        executor.execute { flushRevocations() }
    }

    fun close() {
        executor.shutdownNow()
    }

    internal fun pendingEventCount(): Int = synchronized(queueLock) { readQueue().length() }
    internal fun pendingRevocations(): List<String> = readRevocations()
    internal fun awaitIdle() {
        executor.submit {}.get(3, TimeUnit.SECONDS)
    }

    private fun flushAll() {
        val revocationsFlushed = flushRevocations()
        flushIdentify()
        if (revocationsFlushed) flushPushTokenRegistration()
        flushEvents()
    }

    private fun flushEvents() {
        if (System.currentTimeMillis() < retryAtMillis) return
        while (true) {
            val batch = synchronized(queueLock) {
                val queue = readQueue()
                if (queue.length() == 0) return
                JSONArray().also { output ->
                    repeat(min(queue.length(), maxBatchSize)) { output.put(queue.getJSONObject(it)) }
                }
            }
            val result = send(
                "POST",
                "events",
                JSONObject().put("events", batch).put("sentAt", timestamp()),
            )
            when {
                result.delivered || result.permanent -> {
                    synchronized(queueLock) {
                        val queue = readQueue()
                        val completedMessageIds = (0 until batch.length())
                            .map { batch.getJSONObject(it).getString("messageId") }
                            .toSet()
                        val remaining = JSONArray()
                        for (index in 0 until queue.length()) {
                            val event = queue.getJSONObject(index)
                            if (event.getString("messageId") !in completedMessageIds) {
                                remaining.put(event)
                            }
                        }
                        writeQueue(remaining)
                    }
                    retryCount = 0
                    retryScheduled = false
                    retryAtMillis = 0
                }
                result.retryable -> {
                    scheduleRetry(result.error)
                    return
                }
                else -> return
            }
        }
    }

    private fun flushIdentify(): Boolean {
        val raw = synchronized(identityLock) {
            preferences.getString(pendingIdentifyKey, null)
        } ?: return true
        val result = send("POST", "identify", JSONObject(raw))
        if (result.delivered || result.permanent) {
            synchronized(identityLock) {
                if (preferences.getString(pendingIdentifyKey, null) == raw) {
                    preferences.edit().remove(pendingIdentifyKey).commit()
                }
            }
        }
        return result.delivered
    }

    private fun flushPushTokenRegistration(): Boolean {
        val token = preferences.getString(pushTokenKey, null) ?: return true
        val (userId, anonymousId) = identitySnapshot()
        val fingerprint = listOf(token, userId.orEmpty(), anonymousId).joinToString(":")
        if (preferences.getString(lastTokenRegistrationKey, null) == fingerprint) return true
        val body = JSONObject()
            .put("token", token)
            .put("platform", "android")
            .put("provider", "fcm")
            .put("anonymousId", anonymousId)
        userId?.let { body.put("userId", it) }
        val result = send("POST", "push-tokens", body)
        if (result.delivered) {
            preferences.edit().putString(lastTokenRegistrationKey, fingerprint).apply()
        }
        return result.delivered
    }

    private fun enqueueRevocation(token: String) {
        val pending = readRevocations().toMutableList()
        if (token !in pending) pending += token
        writeRevocations(pending)
    }

    private fun flushRevocations(): Boolean {
        for (token in readRevocations()) {
            val result = send("DELETE", "push-tokens", JSONObject().put("token", token))
            if (!result.delivered) return false
            writeRevocations(readRevocations().filter { it != token })
        }
        return true
    }

    private fun send(method: String, path: String, body: JSONObject): HttpResult {
        val result = transport.send(method, "$baseUrl/api/v1/$path", apiKey, body.toString())
        if (!result.delivered) {
            Log.e(logTag, "$method /api/v1/$path failed with status ${result.status}.", result.error)
        }
        return result
    }

    private fun scheduleRetry(error: Throwable?) {
        if (retryScheduled) return
        retryCount += 1
        val base = min(2.0.pow(retryCount.toDouble()), maxBackoffSeconds.toDouble())
        val delay = (base + Random.nextDouble(-0.3, 0.3) * base)
            .coerceIn(1.0, maxBackoffSeconds.toDouble())
        retryScheduled = true
        retryAtMillis = System.currentTimeMillis() + (delay * 1000).toLong()
        Log.e(logTag, "Event delivery will retry in ${"%.1f".format(delay)}s.", error)
        executor.schedule({
            retryScheduled = false
            retryAtMillis = 0
            flushAll()
        }, (delay * 1000).toLong(), TimeUnit.MILLISECONDS)
    }

    private fun validateProperties(properties: Map<String, Any?>) {
        require(properties.size <= 64) { "At most 64 properties are allowed." }
        properties.forEach { (key, value) ->
            require(key.isNotBlank() && key.length <= 128) { "Property keys must be 1-128 characters." }
            require(value == null || value is String || value is Number || value is Boolean) {
                "Properties must be flat string, number, boolean, or null values."
            }
            if (value is String) require(value.length <= 1024) {
                "String property values must be at most 1024 characters."
            }
            if (value is Double) require(value.isFinite()) { "Number properties must be finite." }
            if (value is Float) require(value.isFinite()) { "Number properties must be finite." }
        }
    }

    private fun readQueue(): JSONArray = runCatching {
        JSONArray(preferences.getString(queueKey, "[]"))
    }.getOrDefault(JSONArray())

    private fun writeQueue(queue: JSONArray) {
        preferences.edit().putString(queueKey, queue.toString()).commit()
    }

    private fun readRevocations(): List<String> = runCatching {
        val array = JSONArray(preferences.getString(revocationsKey, "[]"))
        List(array.length()) { array.getString(it) }
    }.getOrDefault(emptyList())

    private fun writeRevocations(tokens: List<String>) {
        val edit = preferences.edit()
        if (tokens.isEmpty()) edit.remove(revocationsKey)
        else edit.putString(revocationsKey, JSONArray(tokens).toString())
        edit.commit()
    }

    private fun identitySnapshot(): Pair<String?, String> = synchronized(identityLock) {
        preferences.getString(userIdKey, null) to anonymousId()
    }

    private fun removeFirst(array: JSONArray) {
        if (array.length() > 0) array.remove(0)
    }

    companion object {
        private const val preferencesName = "notifie"
        private const val queueKey = "event_queue"
        private const val anonymousIdKey = "anonymous_id"
        private const val userIdKey = "user_id"
        private const val pushTokenKey = "push_token"
        private const val retainedPushTokenKey = "retained_push_token"
        private const val lastTokenRegistrationKey = "last_push_registration"
        private const val pendingIdentifyKey = "pending_identify"
        private const val revocationsKey = "pending_push_revocations"
        private const val maxBatchSize = 100
        private const val maxBackoffSeconds = 300
        private const val logTag = "Notifie"
        private val eventNamePattern = Regex("^[A-Za-z0-9][A-Za-z0-9 _.:-]*$")

        private fun timestamp(): String = SimpleDateFormat(
            "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
            Locale.US,
        ).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(Date())
    }
}