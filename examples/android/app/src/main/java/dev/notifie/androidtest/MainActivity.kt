package dev.notifie.androidtest

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import dev.notifie.*

class MainActivity : Activity() {
    private lateinit var status: TextView

    /**
     * Cloud is optional in this demo.
     *
     * The local notification buttons below work with no key, no network and no
     * account, so the example must still run when one is absent. Requiring a
     * key to launch would contradict what it is demonstrating.
     */
    private val hasCloudKey: Boolean
        get() = BuildConfig.NOTIFIE_API_KEY.isNotBlank()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (hasCloudKey) {
            Notifie.initialize(
                context = applicationContext,
                apiKey = BuildConfig.NOTIFIE_API_KEY,
                baseUrl = BuildConfig.NOTIFIE_BASE_URL,
            )
            Notifie.setBackgroundMessageHandler { data ->
                Log.i("NotifieTest", "Background message received with keys: ${data.keys.sorted()}")
            }
            identifyDevice()
        }

        status = TextView(this).apply {
            text = if (hasCloudKey) {
                "Initialized as ${BuildConfig.NOTIFIE_EXTERNAL_USER_ID}"
            } else {
                "No API key — local notifications still work"
            }
            textSize = 18f
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            addView(status)
            addView(actionButton("Remind me in 10 seconds") { scheduleLocal(soon = true) })
            addView(actionButton("Remind me daily at 09:00") { scheduleLocal(soon = false) })
            addView(actionButton("Cancel local reminders") { cancelLocal() })
            addView(actionButton("Request notifications") {
                status.text = "Requesting notification permission and FCM token…"
                Notifie.enableNotifications(::showEnrollment)
            })
            addView(actionButton("Track purchase") {
                Notifie.track(
                    "android_blackbox_purchase",
                    mapOf(
                        "amount" to 9.99,
                        "currency" to "USD",
                        "test_device" to true,
                        "item_count" to 2,
                    ),
                )
                status.text = "Queued android_blackbox_purchase"
            })
            addView(actionButton("Track offline event") {
                Notifie.track(
                    "android_blackbox_offline",
                    mapOf("connection_expected" to "offline"),
                )
                status.text = "Queued android_blackbox_offline"
            })
            addView(actionButton("Reset identity") {
                Notifie.reset()
                status.text = "Identity reset; token revocation queued"
            })
            addView(actionButton("Re-identify device") {
                identifyDevice()
                status.text = "Re-identified as ${BuildConfig.NOTIFIE_EXTERNAL_USER_ID}"
            })
        }
        setContentView(content)
    }

    /**
     * Schedules a local reminder.
     *
     * No API key, no network and no `initialize()` — try it in airplane mode.
     */
    private fun scheduleLocal(soon: Boolean) {
        val notification = if (soon) {
            LocalNotification(
                id = "demo-soon",
                title = "Ten seconds later",
                body = "Scheduled locally with no account and no network.",
                schedule = LocalSchedule.After(seconds = 10),
            )
        } else {
            LocalNotification(
                id = "demo-daily",
                title = "Daily practice",
                body = "Repeats at 09:00 local time, including across DST.",
                schedule = LocalSchedule.Daily(hour = 9, minute = 0),
            )
        }

        status.text = when (val result = Notifie.schedule(applicationContext, notification)) {
            is LocalScheduleResult.Scheduled ->
                // Precision is reported rather than assumed: Android downgrades
                // exact alarms when the 12+ permission is absent.
                "Scheduled ${notification.id} (${result.precision})"
            is LocalScheduleResult.Failed ->
                "Not scheduled: ${result.error} ${result.message.orEmpty()}"
        }
    }

    private fun cancelLocal() {
        // Cancelling something that was never scheduled is harmless.
        Notifie.cancelScheduled(applicationContext, "demo-soon")
        Notifie.cancelScheduled(applicationContext, "demo-daily")
        val remaining = Notifie.pendingScheduled(applicationContext).size
        status.text = "Cancelled local reminders ($remaining pending)"
    }

    private fun identifyDevice() {
        Notifie.identify(
            BuildConfig.NOTIFIE_EXTERNAL_USER_ID,
            mapOf("test_device" to true, "platform" to "android"),
        )
    }

    private fun actionButton(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            setOnClickListener { action() }
        }

    private fun showEnrollment(result: NotificationEnrollment) {
        runOnUiThread {
            status.text = "Notification enrollment: ${result.name}"
        }
    }
}