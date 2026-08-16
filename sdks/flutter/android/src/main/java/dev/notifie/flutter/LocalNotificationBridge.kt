package dev.notifie.flutter

import android.content.Context
import dev.notifie.LocalNotification
import dev.notifie.LocalNotificationAndroidOptions
import dev.notifie.Notifie
import dev.notifie.LocalSchedule
import dev.notifie.LocalScheduleError
import dev.notifie.LocalSchedulePrecision
import dev.notifie.LocalScheduleResult

/**
 * Translates method-channel arguments into the native scheduler's API.
 *
 * Deliberately a translator and nothing more. Persistence, reboot recovery,
 * alarm precision and drift-free recurrence all live in the Android SDK this
 * delegates to; reimplementing any of it here would create a second engine to
 * diverge from the first, and the divergence would be silent.
 */
internal object LocalNotificationBridge {

    fun schedule(context: Context, arguments: Map<*, *>): Map<String, Any?> {
        val notification = try {
            decode(arguments)
        } catch (error: IllegalArgumentException) {
            return failure("invalid_request", error.message)
        }

        return when (val result = Notifie.schedule(context, notification)) {
            is LocalScheduleResult.Scheduled -> mapOf(
                // The granted precision, not the requested one: Android
                // downgrades exact alarms without the 12+ permission.
                "precision" to when (result.precision) {
                    LocalSchedulePrecision.EXACT -> "exact"
                    LocalSchedulePrecision.INEXACT -> "inexact"
                },
                "nextTrigger" to result.nextTriggerAtMillis,
            )
            is LocalScheduleResult.Failed -> failure(code(result.error), result.message)
        }
    }

    fun cancel(context: Context, arguments: Map<*, *>) {
        val id = arguments["id"] as? String ?: return
        Notifie.cancelScheduled(context, id)
    }

    fun pending(context: Context): List<Map<String, Any?>> =
        Notifie.pendingScheduled(context).map {
            mapOf("id" to it.id, "nextTrigger" to it.nextTriggerAtMillis)
        }

    fun capabilities(context: Context): Map<String, Any?> = mapOf(
        "permission" to permissionState(context),
        "canScheduleExactAlarms" to canScheduleExactAlarms(context),
        "supportedSchedules" to listOf("at", "after", "daily", "weekly"),
        // Android publishes no fixed pending-notification limit, unlike iOS.
        // Reporting null is honest; inventing a number would not be.
        "pendingCapacity" to null,
    )

    fun permissionState(context: Context): String {
        val manager = androidx.core.app.NotificationManagerCompat.from(context)
        return if (manager.areNotificationsEnabled()) "granted" else "denied"
    }

    private fun canScheduleExactAlarms(context: Context): Boolean {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.S) return true
        val manager = context.getSystemService(android.app.AlarmManager::class.java)
        return manager?.canScheduleExactAlarms() ?: false
    }

    private fun code(error: LocalScheduleError): String = when (error) {
        LocalScheduleError.INVALID_REQUEST -> "invalid_request"
        LocalScheduleError.PERMISSION_DENIED -> "permission_denied"
        LocalScheduleError.SCHEDULE_IN_PAST -> "schedule_in_past"
        LocalScheduleError.PLATFORM_ERROR -> "platform_error"
    }

    private fun failure(code: String, message: String?): Map<String, Any?> =
        mapOf("error" to code, "message" to message)

    internal fun decode(arguments: Map<*, *>): LocalNotification {
        val scheduleArgs = arguments["schedule"] as? Map<*, *>
            ?: throw IllegalArgumentException("schedule is required")

        val android = (arguments["android"] as? Map<*, *>).let { options ->
            LocalNotificationAndroidOptions(
                channelId = options?.get("channelId") as? String,
                exact = options?.get("exact") as? Boolean ?: false,
                allowWhileIdle = options?.get("allowWhileIdle") as? Boolean ?: false,
                groupKey = options?.get("groupKey") as? String,
            )
        }

        val data = (arguments["customData"] as? Map<*, *>).orEmpty()
            .entries
            .mapNotNull { (key, value) ->
                val name = key as? String ?: return@mapNotNull null
                name to value.toString()
            }
            .toMap()

        return LocalNotification(
            id = arguments["id"] as? String
                ?: throw IllegalArgumentException("id is required"),
            title = arguments["title"] as? String
                ?: throw IllegalArgumentException("title is required"),
            body = arguments["body"] as? String
                ?: throw IllegalArgumentException("body is required"),
            schedule = decodeSchedule(scheduleArgs),
            deepLink = arguments["deepLink"] as? String,
            customData = data,
            android = android,
        )
    }

    private fun decodeSchedule(arguments: Map<*, *>): LocalSchedule =
        when (val type = arguments["type"] as? String) {
            "at" -> {
                // Parsed as an instant with its explicit offset. A bare local
                // timestamp would be reinterpreted in the device's timezone.
                val raw = arguments["timestamp"] as? String
                    ?: throw IllegalArgumentException("timestamp is required")
                LocalSchedule.At(parseIso8601(raw))
            }
            "after" -> LocalSchedule.After(requireLong(arguments, "seconds"))
            "daily" -> LocalSchedule.Daily(
                hour = requireInt(arguments, "hour"),
                minute = requireInt(arguments, "minute"),
            )
            "weekly" -> LocalSchedule.Weekly(
                weekday = requireInt(arguments, "weekday"),
                hour = requireInt(arguments, "hour"),
                minute = requireInt(arguments, "minute"),
            )
            else -> throw IllegalArgumentException("unknown schedule type \"$type\"")
        }

    private fun parseIso8601(raw: String): Long = try {
        java.time.Instant.parse(raw).toEpochMilli()
    } catch (error: java.time.format.DateTimeParseException) {
        throw IllegalArgumentException("timestamp must be ISO-8601 with an offset")
    }

    private fun requireInt(arguments: Map<*, *>, key: String): Int =
        (arguments[key] as? Number)?.toInt()
            ?: throw IllegalArgumentException("$key is required")

    private fun requireLong(arguments: Map<*, *>, key: String): Long =
        (arguments[key] as? Number)?.toLong()
            ?: throw IllegalArgumentException("$key is required")
}
