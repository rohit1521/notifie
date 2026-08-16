package dev.notifie

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONArray
import org.json.JSONObject
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.Locale
import java.util.TimeZone

public enum class NotificationEnrollment {
    ENROLLED,
    DENIED,
    NOT_INITIALIZED,
    TOKEN_ERROR,
}

public object Notifie {
    private var client: NotifieClient? = null
    private var application: Application? = null
    private var initializedApiKey: String? = null
    private var initializedBaseUrl: String? = null
    private var currentActivity = WeakReference<Activity>(null)
    private var notificationPermissionPending = false
    private var notificationCallback: ((NotificationEnrollment) -> Unit)? = null
    private var backgroundMessageHandler: ((Map<String, String>) -> Unit)? = null
    private val notificationPersistenceLock = Any()
    private var lifecycleCallbacks: Application.ActivityLifecycleCallbacks? = null
    private var startedActivities = 0
    private var enteredBackground = false

    @JvmStatic
    @JvmOverloads
    public fun initialize(
        context: Context,
        apiKey: String,
        baseUrl: String = "https://notifie.dev",
    ) {
        require(apiKey.isNotBlank()) { "API key cannot be empty." }
        val applicationContext = context.applicationContext
        val application = applicationContext as? Application
            ?: error("Notifie requires an Android Application context.")
        val normalizedBaseUrl = baseUrl.trimEnd('/')
        if (
            client != null &&
            this.application === application &&
            initializedApiKey == apiKey &&
            initializedBaseUrl == normalizedBaseUrl
        ) {
            return
        }

        val firstInitialization = client == null
        client?.close()
        val previousApplication = this.application
        val previousCallbacks = lifecycleCallbacks
        if (previousApplication != null && previousCallbacks != null) {
            previousApplication.unregisterActivityLifecycleCallbacks(previousCallbacks)
        }
        this.application = application
        initializedApiKey = apiKey
        initializedBaseUrl = normalizedBaseUrl
        val newClient = NotifieClient(application, apiKey, normalizedBaseUrl)
        client = newClient
        replayPendingNotificationReceipts(newClient, application)
        replayPendingNotificationOpens(newClient, application)
        replayPendingBackgroundMessages(application)
        NotifieNotifications.createDefaultChannel(application)
        lifecycleCallbacks = createLifecycleCallbacks().also(application::registerActivityLifecycleCallbacks)
        if (firstInitialization) trackInitialLifecycle(newClient, application)
    }

    @JvmStatic
    public fun identify(userId: String, properties: Map<String, Any?> = emptyMap()) {
        requireClient().identify(userId, properties)
    }

    @JvmStatic
    public fun enableNotifications() {
        enableNotifications(null)
    }

    @JvmStatic
    public fun enableNotifications(onResult: ((NotificationEnrollment) -> Unit)?) {
        val client = client
        if (client == null) {
            onResult?.invoke(NotificationEnrollment.NOT_INITIALIZED)
            return
        }
        notificationCallback = onResult
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            fetchAndRegisterToken(client)
            return
        }
        val activity = currentActivity.get()
        if (activity == null) {
            notificationPermissionPending = true
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            fetchAndRegisterToken(client)
            return
        }
        notificationPermissionPending = true
        requestNotificationPermission(activity)
    }

    @JvmStatic
    public fun track(eventName: String, properties: Map<String, Any?> = emptyMap()) {
        requireClient().track(eventName, properties)
    }

    @JvmStatic
    public fun reset() {
        requireClient().reset()
    }

    @JvmStatic
    public fun registerPushToken(token: String) {
        requireClient().registerPushToken(token)
    }

    /** Forward here only when the host app already owns FirebaseMessagingService. */
    @JvmStatic
    public fun handleRemoteMessage(context: Context, message: RemoteMessage) {
        val data = message.data.toMutableMap()
        if (!isNotifieMessage(data)) return
        recordNotificationReceived(context, data)
        if (message.notification == null) {
            recordBackgroundMessage(context, data)
            return
        }
        NotifieNotifications.show(
            context = context,
            title = message.notification?.title.orEmpty(),
            body = message.notification?.body.orEmpty(),
            imageUrl = message.notification?.imageUrl?.toString() ?: data[imageUrlKey],
            data = data,
        )
    }

    internal fun isNotifieMessage(data: Map<String, String>): Boolean =
        !data[invocationIdKey].isNullOrBlank()

    @JvmStatic
    public fun registerPushToken(context: Context, token: String) {
        require(token.isNotBlank()) { "Push token cannot be empty." }
        val activeClient = client
        if (activeClient != null) activeClient.registerPushToken(token)
        else context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
            .edit().putString("push_token", token).commit()
    }

    @JvmStatic
    public fun notificationReceived(data: Map<String, String>) {
        client?.let { trackNotificationReceived(it, data) }
    }

    @JvmStatic
    public fun setBackgroundMessageHandler(
        handler: ((Map<String, String>) -> Unit)?,
    ) {
        backgroundMessageHandler = handler
        if (handler != null) application?.let(::replayPendingBackgroundMessages)
    }

    /**
     * Schedules a local notification without requiring initialization, an API
     * key or a network connection. Scheduling the same ID replaces the pending
     * request, so callers can safely reassert reminders on every launch.
     */
    @JvmStatic
    public fun schedule(
        context: Context,
        notification: LocalNotification,
    ): LocalScheduleResult = LocalNotificationScheduler.schedule(context, notification)

    /** Cancels a pending local notification. Unknown IDs are ignored. */
    @JvmStatic
    public fun cancelScheduled(context: Context, id: String) {
        LocalNotificationScheduler.cancel(context, id)
    }

    /** Local notifications this SDK scheduled that have not yet fired. */
    @JvmStatic
    public fun pendingScheduled(context: Context): List<PendingLocalNotification> =
        LocalNotificationScheduler.pending(context)

    internal fun recordNotificationReceived(context: Context, data: Map<String, String>) {
        val invocationId = data[invocationIdKey]
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        synchronized(notificationPersistenceLock) {
            if (
                invocationId != null &&
                hasProcessedInvocation(preferences, processedReceivedInvocationsKey, invocationId)
            ) {
                return
            }
            val activeClient = client
            if (activeClient != null) {
                trackNotificationReceived(activeClient, data)
                if (invocationId != null) {
                    preferences.edit().putString(
                        processedReceivedInvocationsKey,
                        processedInvocationsWith(
                            preferences,
                            processedReceivedInvocationsKey,
                            invocationId,
                        ),
                    ).commit()
                }
                return
            }

            val pending = readPendingNotificationReceipts(preferences)
            pending.put(
                JSONObject()
                    .put("messageId", notificationMessageId("received", invocationId))
                    .put("invocationId", invocationId),
            )
            while (pending.length() > maxPendingNotificationEvents) pending.remove(0)
            preferences.edit()
                .putString(pendingNotificationReceiptsKey, pending.toString())
                .apply {
                    if (invocationId != null) {
                        putString(
                            processedReceivedInvocationsKey,
                            processedInvocationsWith(
                                preferences,
                                processedReceivedInvocationsKey,
                                invocationId,
                            ),
                        )
                    }
                }
                .commit()
        }
    }

    internal fun recordBackgroundMessage(context: Context, data: Map<String, String>) {
        if (data.isEmpty()) return
        val invocationId = data[invocationIdKey]
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        synchronized(notificationPersistenceLock) {
            if (
                invocationId != null &&
                hasProcessedInvocation(preferences, processedBackgroundInvocationsKey, invocationId)
            ) {
                return
            }
            val pending = readPendingBackgroundMessages(preferences)
            pending.put(
                JSONObject()
                    .put("messageId", notificationMessageId("background", invocationId))
                    .put("data", JSONObject(data)),
            )
            while (pending.length() > maxPendingNotificationEvents) pending.remove(0)
            preferences.edit()
                .putString(pendingBackgroundMessagesKey, pending.toString())
                .apply {
                    if (invocationId != null) {
                        putString(
                            processedBackgroundInvocationsKey,
                            processedInvocationsWith(
                                preferences,
                                processedBackgroundInvocationsKey,
                                invocationId,
                            ),
                        )
                    }
                }
                .commit()
        }
        replayPendingBackgroundMessages(context)
    }

    private fun trackNotificationReceived(
        client: NotifieClient,
        data: Map<String, String>,
        messageId: String = notificationMessageId("received", data[invocationIdKey]),
    ) {
        val properties = mutableMapOf<String, Any?>()
        data[invocationIdKey]?.let { properties["invocation_id"] = it }
        client.track("notification_received", properties, messageId)
    }

    @JvmStatic
    public fun notificationOpened(data: Map<String, String>, action: String? = null) {
        client?.let { trackNotificationOpen(it, data, action) }
    }

    @JvmStatic
    public fun deepLink(data: Map<String, String>): String? = data[deepLinkKey]

    internal fun isInForeground(): Boolean = startedActivities > 0

    internal fun onNotificationPermissionResult(granted: Boolean) {
        notificationPermissionPending = false
        if (granted) {
            client?.let(::fetchAndRegisterToken)
        } else {
            notificationCallback?.invoke(NotificationEnrollment.DENIED)
            notificationCallback = null
        }
    }

    private fun requireClient(): NotifieClient = checkNotNull(client) {
        "Call Notifie.initialize() before using the SDK."
    }

    private fun fetchAndRegisterToken(client: NotifieClient) {
        val callback = notificationCallback
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                if (token.isBlank()) {
                    callback?.invoke(NotificationEnrollment.TOKEN_ERROR)
                    clearNotificationCallback(callback)
                } else {
                    client.registerPushToken(token) { registered ->
                        callback?.invoke(
                            if (registered) NotificationEnrollment.ENROLLED
                            else NotificationEnrollment.TOKEN_ERROR,
                        )
                        clearNotificationCallback(callback)
                    }
                }
            }
            .addOnFailureListener {
                callback?.invoke(NotificationEnrollment.TOKEN_ERROR)
                clearNotificationCallback(callback)
            }
    }

    private fun clearNotificationCallback(callback: ((NotificationEnrollment) -> Unit)?) {
        if (notificationCallback === callback) notificationCallback = null
    }

    private fun requestNotificationPermission(activity: Activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.startActivity(Intent(activity, NotifiePermissionActivity::class.java))
        }
    }

    private fun createLifecycleCallbacks(): Application.ActivityLifecycleCallbacks {
        return object : Application.ActivityLifecycleCallbacks {
            override fun onActivityCreated(activity: Activity, state: Bundle?) {
                if (activity is NotifiePermissionActivity) return
                recordNotificationOpen(activity.intent)
            }

            override fun onActivityStarted(activity: Activity) {
                if (activity is NotifiePermissionActivity) return
                if (startedActivities == 0 && enteredBackground) {
                    client?.track("app_open", deviceProperties(activity))
                    client?.track("session_start")
                    enteredBackground = false
                }
                startedActivities += 1
            }

            override fun onActivityResumed(activity: Activity) {
                if (activity is NotifiePermissionActivity) return
                currentActivity = WeakReference(activity)
                recordNotificationOpen(activity.intent)
                if (!notificationPermissionPending) return
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    notificationPermissionPending = false
                    client?.let(::fetchAndRegisterToken)
                } else {
                    notificationPermissionPending = false
                    requestNotificationPermission(activity)
                }
            }

            override fun onActivityPaused(activity: Activity) {
                if (activity is NotifiePermissionActivity) return
                if (currentActivity.get() === activity) currentActivity.clear()
            }

            override fun onActivityStopped(activity: Activity) {
                if (activity is NotifiePermissionActivity) return
                startedActivities = (startedActivities - 1).coerceAtLeast(0)
                if (startedActivities == 0 && !activity.isChangingConfigurations) enteredBackground = true
            }

            override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        }
    }

    private fun trackInitialLifecycle(client: NotifieClient, context: Context) {
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        val device = deviceProperties(context)
        if (!preferences.getBoolean("installed", false)) {
            preferences.edit().putBoolean("installed", true).apply()
            client.track("install", device)
            client.track("first_open")
        }
        client.track("app_open", device)
        client.track("session_start")
    }

    private fun deviceProperties(context: Context): Map<String, Any?> {
        val packageInfo = context.packageManager.getPackageInfo(context.packageName, 0)
        return mapOf(
            "platform" to "android",
            "os_version" to Build.VERSION.RELEASE,
            "app_version" to packageInfo.versionName,
            "app_build" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION") packageInfo.versionCode.toString()
            },
            "locale" to Locale.getDefault().toLanguageTag(),
            "timezone" to TimeZone.getDefault().id,
            "device_model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
        )
    }

    private fun recordNotificationOpen(intent: Intent?) {
        val extras = intent?.extras ?: return
        val context = application ?: return
        recordNotificationOpen(
            context,
            extras.keySet().associateWith { extras.getString(it).orEmpty() },
        )
    }

    internal fun recordNotificationOpen(
        context: Context,
        data: Map<String, String>,
        action: String? = null,
    ) {
        val invocationId = data[invocationIdKey] ?: return
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        synchronized(notificationPersistenceLock) {
            if (
                hasProcessedInvocation(
                    preferences,
                    processedOpenedInvocationsKey,
                    invocationId,
                )
            ) {
                return
            }
            val activeClient = client
            if (activeClient != null) {
                trackNotificationOpen(activeClient, data, action)
                preferences.edit().putString(
                    processedOpenedInvocationsKey,
                    processedInvocationsWith(
                        preferences,
                        processedOpenedInvocationsKey,
                        invocationId,
                    ),
                ).commit()
                return
            }

            val pending = readPendingNotificationOpens(preferences)
            pending.put(
                JSONObject()
                    .put("messageId", notificationMessageId("opened", invocationId))
                    .put("invocationId", invocationId)
                    .put("action", action),
            )
            while (pending.length() > maxPendingNotificationOpens) pending.remove(0)
            preferences.edit()
                .putString(pendingNotificationOpensKey, pending.toString())
                .putString(
                    processedOpenedInvocationsKey,
                    processedInvocationsWith(
                        preferences,
                        processedOpenedInvocationsKey,
                        invocationId,
                    ),
                )
                .commit()
        }
    }

    private fun replayPendingNotificationOpens(client: NotifieClient, context: Context) {
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        val pending = readPendingNotificationOpens(preferences)
        val completedKeys = mutableSetOf<String>()
        for (index in 0 until pending.length()) {
            val rawEntry = pending.opt(index)
            val entryKey = pendingEntryKey(rawEntry)
            val entry = rawEntry as? JSONObject
            if (entry == null) {
                Log.e(logTag, "Dropping malformed pending notification open.")
                completedKeys += entryKey
                continue
            }
            val invocationId = entry.optString("invocationId")
            if (invocationId.isBlank()) {
                Log.e(logTag, "Dropping malformed pending notification open.")
                completedKeys += entryKey
                continue
            }
            val action = entry.optString("action").takeIf(String::isNotBlank)
            val messageId = entry.optString("messageId").ifBlank {
                notificationMessageId("opened", invocationId)
            }
            trackNotificationOpen(
                client,
                mapOf(invocationIdKey to invocationId),
                action,
                messageId,
            )
            completedKeys += entryKey
        }
        removePendingEntries(preferences, pendingNotificationOpensKey, completedKeys)
    }

    private fun replayPendingNotificationReceipts(client: NotifieClient, context: Context) {
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        val pending = readPendingNotificationReceipts(preferences)
        val completedKeys = mutableSetOf<String>()
        for (index in 0 until pending.length()) {
            val rawEntry = pending.opt(index)
            val entryKey = pendingEntryKey(rawEntry)
            val entry = rawEntry as? JSONObject
            if (entry == null) {
                Log.e(logTag, "Dropping malformed pending notification receipt.")
                completedKeys += entryKey
                continue
            }
            val invocationId = entry.optString("invocationId").takeIf(String::isNotBlank)
            val messageId = entry.optString("messageId").ifBlank {
                notificationMessageId("received", invocationId)
            }
            trackNotificationReceived(
                client,
                invocationId?.let { mapOf(invocationIdKey to it) }.orEmpty(),
                messageId,
            )
            completedKeys += entryKey
        }
        removePendingEntries(preferences, pendingNotificationReceiptsKey, completedKeys)
    }

    private fun replayPendingBackgroundMessages(context: Context) {
        val handler = backgroundMessageHandler ?: return
        val preferences = context.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        val pending = readPendingBackgroundMessages(preferences)
        val completedKeys = mutableSetOf<String>()
        for (index in 0 until pending.length()) {
            val rawEntry = pending.opt(index)
            val entryKey = pendingEntryKey(rawEntry)
            val entry = rawEntry as? JSONObject
            if (entry == null) {
                Log.e(logTag, "Dropping malformed pending background message.")
                completedKeys += entryKey
                continue
            }
            val payload = entry.optJSONObject("data") ?: entry
            if (payload.length() == 0) {
                Log.e(logTag, "Dropping malformed pending background message.")
                completedKeys += entryKey
                continue
            }
            handler(payload.keys().asSequence().associateWith(payload::getString))
            completedKeys += entryKey
        }
        removePendingEntries(preferences, pendingBackgroundMessagesKey, completedKeys)
    }

    private fun trackNotificationOpen(
        client: NotifieClient,
        data: Map<String, String>,
        action: String?,
        messageId: String? = null,
    ) {
        val properties = mutableMapOf<String, Any?>()
        data[invocationIdKey]?.let { properties["invocation_id"] = it }
        client.track(
            "notification_opened",
            properties,
            messageId ?: notificationMessageId("opened", data[invocationIdKey]),
        )
        if (!action.isNullOrBlank()) {
            properties["action"] = action
            client.track(
                "notification_clicked",
                properties,
                notificationMessageId("clicked:$action", data[invocationIdKey]),
            )
        }
    }

    private fun readPendingNotificationOpens(
        preferences: android.content.SharedPreferences,
    ): JSONArray = runCatching {
        JSONArray(preferences.getString(pendingNotificationOpensKey, "[]"))
    }.getOrDefault(JSONArray())

    private fun readPendingNotificationReceipts(
        preferences: android.content.SharedPreferences,
    ): JSONArray = runCatching {
        JSONArray(preferences.getString(pendingNotificationReceiptsKey, "[]"))
    }.getOrDefault(JSONArray())

    private fun readPendingBackgroundMessages(
        preferences: android.content.SharedPreferences,
    ): JSONArray = runCatching {
        JSONArray(preferences.getString(pendingBackgroundMessagesKey, "[]"))
    }.getOrDefault(JSONArray())

    private fun removePendingEntries(
        preferences: android.content.SharedPreferences,
        key: String,
        completedKeys: Set<String>,
    ) {
        if (completedKeys.isEmpty()) return
        synchronized(notificationPersistenceLock) {
            val current = JSONArray(preferences.getString(key, "[]"))
            val remaining = JSONArray()
            for (index in 0 until current.length()) {
                val entry = current.opt(index)
                if (pendingEntryKey(entry) !in completedKeys) remaining.put(entry)
            }
            val edit = preferences.edit()
            if (remaining.length() == 0) edit.remove(key)
            else edit.putString(key, remaining.toString())
            edit.commit()
        }
    }

    private fun pendingEntryKey(entry: Any?): String =
        (entry as? JSONObject)?.optString("messageId").orEmpty().ifBlank {
            entry?.toString().orEmpty()
        }

    private fun hasProcessedInvocation(
        preferences: android.content.SharedPreferences,
        key: String,
        invocationId: String,
    ): Boolean = runCatching {
        val values = JSONArray(preferences.getString(key, "[]"))
        (0 until values.length()).any { values.getString(it) == invocationId }
    }.getOrDefault(false)

    private fun processedInvocationsWith(
        preferences: android.content.SharedPreferences,
        key: String,
        invocationId: String,
    ): String {
        val existing = runCatching {
            val values = JSONArray(preferences.getString(key, "[]"))
            (0 until values.length()).map(values::getString)
        }.getOrDefault(emptyList())
        return JSONArray(
            (existing.filter { it != invocationId } + invocationId)
                .takeLast(maxProcessedNotificationInvocations),
        ).toString()
    }

    private fun notificationMessageId(kind: String, invocationId: String?): String {
        if (invocationId.isNullOrBlank()) return UUID.randomUUID().toString().lowercase()
        return UUID.nameUUIDFromBytes(
            "notifie:$kind:$invocationId".toByteArray(Charsets.UTF_8),
        ).toString().lowercase()
    }

    internal const val defaultChannelId = "notifie_default"
    internal const val invocationIdKey = "gk_invocation_id"
    internal const val deepLinkKey = "gk_deep_link"
    internal const val imageUrlKey = "gk_image_url"
    private const val pendingNotificationOpensKey = "pending_notification_opens"
    private const val pendingNotificationReceiptsKey = "pending_notification_receipts"
    private const val pendingBackgroundMessagesKey = "pending_background_messages"
    private const val processedOpenedInvocationsKey = "processed_opened_invocations"
    private const val processedReceivedInvocationsKey = "processed_received_invocations"
    private const val processedBackgroundInvocationsKey = "processed_background_invocations"
    private const val maxPendingNotificationEvents = 100
    private const val maxPendingNotificationOpens = maxPendingNotificationEvents
    private const val maxProcessedNotificationInvocations = 256
    private const val logTag = "Notifie"
}