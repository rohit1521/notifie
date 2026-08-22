package dev.notifie

import android.content.Context
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Firebase configuration fetched from Notifie instead of read from
 * `google-services.json`.
 *
 * The Google Services Gradle plugin does nothing at build time except turn that
 * file into four string resources, and those four values are all the messaging
 * SDK reads. Fetching them at runtime removes a build step every developer on
 * the team, and every CI job, would otherwise have to repeat — and removes the
 * class of failure where push works locally and silently does not in release
 * builds because the file was never committed.
 *
 * None of these values is a secret. They ship inside every APK that uses
 * `google-services.json` today, and Firebase protects the API key by binding it
 * to the app's signing certificate rather than by keeping it hidden. The
 * service account, which is what can actually send a notification, stays on the
 * server.
 */
internal data class NotifieFirebaseConfig(
    val projectId: String,
    val applicationId: String,
    val apiKey: String,
    val senderId: String,
)

internal object NotifiePushConfig {
    private const val FIREBASE_APP_NAME = "notifie"

    /**
     * Reads the configuration for this app. Returns null whenever it cannot be
     * had, which is not an error: it means the SDK should use the Firebase the
     * host app already configures for itself.
     *
     * Blocking, so callers must not run it on the main thread.
     */
    fun fetch(baseUrl: String, apiKey: String): NotifieFirebaseConfig? {
        val url = "${baseUrl.trimEnd('/')}/api/v1/push-config"
        val connection = try {
            URL(url).openConnection() as HttpURLConnection
        } catch (error: Exception) {
            Log.d(Notifie.logTag, "Push config unreachable, using google-services.json", error)
            return null
        }

        return try {
            connection.requestMethod = "GET"
            connection.connectTimeout = 10_000
            connection.readTimeout = 10_000
            connection.setRequestProperty("Authorization", "Bearer $apiKey")

            if (connection.responseCode !in 200..299) return null
            val body = connection.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
            parse(body)
        } catch (error: Exception) {
            Log.d(Notifie.logTag, "Push config unreachable, using google-services.json", error)
            null
        } finally {
            connection.disconnect()
        }
    }

    /**
     * A response with `android: null` is a normal answer meaning "nothing
     * configured", not a malformed one, so it returns null rather than logging
     * a failure the developer cannot act on.
     */
    internal fun parse(body: String): NotifieFirebaseConfig? {
        return try {
            val android = JSONObject(body).optJSONObject("android") ?: return null
            val config = NotifieFirebaseConfig(
                projectId = android.optString("projectId"),
                applicationId = android.optString("applicationId"),
                apiKey = android.optString("apiKey"),
                senderId = android.optString("senderId"),
            )
            // A partially populated config produces tokens that fail later in
            // ways that look like a Notifie bug, so refuse it here.
            if (
                config.projectId.isBlank() || config.applicationId.isBlank() ||
                config.apiKey.isBlank() || config.senderId.isBlank()
            ) null else config
        } catch (error: Exception) {
            null
        }
    }

    /**
     * Returns messaging bound to a Firebase app built from [config].
     *
     * A named secondary app, never the default one: initialising the default
     * would fight the host app's own Firebase if it has one, and
     * `FirebaseMessaging.getInstance()` only ever reads the default. The
     * instance therefore has to be taken from the app itself.
     */
    fun messagingFor(context: Context, config: NotifieFirebaseConfig): FirebaseMessaging? {
        return try {
            val existing = runCatching { FirebaseApp.getInstance(FIREBASE_APP_NAME) }.getOrNull()
            val app = existing ?: FirebaseApp.initializeApp(
                context.applicationContext,
                FirebaseOptions.Builder()
                    .setProjectId(config.projectId)
                    .setApplicationId(config.applicationId)
                    .setApiKey(config.apiKey)
                    .setGcmSenderId(config.senderId)
                    .build(),
                FIREBASE_APP_NAME,
            )
            app.get(FirebaseMessaging::class.java)
        } catch (error: Exception) {
            Log.w(Notifie.logTag, "Could not initialise Firebase from server config", error)
            null
        }
    }
}
