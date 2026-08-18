package dev.notifie

import dev.notifie.Notifie
import dev.notifie.NotifieNotifications

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import org.json.JSONObject
import java.util.Calendar

/**
 * Local notifications.
 *
 * Scheduled and presented by the operating system on this device. They need no
 * API key, no network and no Notifie account, so an application can ship
 * reminders without a backend.
 *
 * Android has no equivalent of the iOS pending-notification store, so the SDK
 * owns persistence: definitions live in app-private storage, `AlarmManager`
 * holds the wake-up, and both are re-established after a reboot or upgrade.
 */

/** When a local notification fires. */
public sealed class LocalSchedule {
    /** Fires once at an absolute instant. */
    public data class At(val epochMillis: Long) : LocalSchedule()

    /** Fires once after an interval measured from scheduling. */
    public data class After(val seconds: Long) : LocalSchedule()

    /**
     * Fires every day at a wall-clock time.
     *
     * Wall clock rather than a fixed 24-hour interval: a 9am reminder must stay
     * at 9am across a daylight-saving change rather than drifting an hour and
     * staying there.
     */
    public data class Daily(val hour: Int, val minute: Int) : LocalSchedule()

    /** Fires weekly. Monday is 1 and Sunday is 7, matching ISO-8601. */
    public data class Weekly(val weekday: Int, val hour: Int, val minute: Int) : LocalSchedule()
}

/** Android-specific options, isolated from the portable fields. */
public data class LocalNotificationAndroidOptions(
    val channelId: String? = null,
    /**
     * Requests exact delivery.
     *
     * Off by default: exact alarms are a scarce system resource and need a
     * user-visible permission on Android 12+. A denied request degrades to
     * inexact and is reported through [LocalScheduleResult.precision] rather
     * than failing.
     */
    val exact: Boolean = false,
    /** Fires during Doze. Reserve for user-critical alarms. */
    val allowWhileIdle: Boolean = false,
    val groupKey: String? = null,
)

/** A local notification to schedule. */
public data class LocalNotification(
    val id: String,
    val title: String,
    val body: String,
    val schedule: LocalSchedule,
    val deepLink: String? = null,
    val customData: Map<String, String> = emptyMap(),
    val android: LocalNotificationAndroidOptions = LocalNotificationAndroidOptions(),
)

/** Delivery precision actually granted, which may be less than requested. */
public enum class LocalSchedulePrecision { EXACT, INEXACT }

/** Why scheduling failed. */
public enum class LocalScheduleError {
    INVALID_REQUEST,
    PERMISSION_DENIED,
    SCHEDULE_IN_PAST,
    PLATFORM_ERROR,
}

/** The outcome of a scheduling attempt. */
public sealed class LocalScheduleResult {
    public data class Scheduled(
        val precision: LocalSchedulePrecision,
        val nextTriggerAtMillis: Long,
    ) : LocalScheduleResult()

    public data class Failed(
        val error: LocalScheduleError,
        val message: String? = null,
    ) : LocalScheduleResult()
}

/** A scheduled notification awaiting delivery. */
public data class PendingLocalNotification(
    val id: String,
    val nextTriggerAtMillis: Long,
)

internal object LocalNotificationStore {
    const val PREFERENCES = "notifie.local_notifications"
    const val ID_NAMESPACE = "notifie.local."
    const val MAX_ID_LENGTH = 64
    const val MAX_TITLE_LENGTH = 100
    const val MAX_BODY_LENGTH = 250
    const val MAX_DATA_KEYS = 20
    const val MAX_DATA_BYTES = 4096

    private val idPattern = Regex("^[A-Za-z0-9._:-]+$")

    fun validate(notification: LocalNotification): String? {
        val id = notification.id
        if (id.isEmpty() || id.length > MAX_ID_LENGTH) {
            return "id must be 1-$MAX_ID_LENGTH characters"
        }
        if (id.startsWith(ID_NAMESPACE)) {
            return "id must not start with the reserved \"$ID_NAMESPACE\" namespace"
        }
        if (!idPattern.matches(id)) {
            return "id may contain only letters, digits, dot, underscore, colon or hyphen"
        }
        if (notification.title.isEmpty() || notification.title.length > MAX_TITLE_LENGTH) {
            return "title must be 1-$MAX_TITLE_LENGTH characters"
        }
        if (notification.body.isEmpty() || notification.body.length > MAX_BODY_LENGTH) {
            return "body must be 1-$MAX_BODY_LENGTH characters"
        }
        if (notification.customData.size > MAX_DATA_KEYS) {
            return "at most $MAX_DATA_KEYS custom data fields"
        }
        if (notification.customData.keys.any { it.startsWith("gk_") }) {
            return "custom data must not use the reserved gk_ prefix"
        }
        // Measured in UTF-8 because the payload budget is bytes; a character
        // count passes for text that then fails to store or deliver.
        val bytes = notification.customData.entries.sumOf {
            it.key.toByteArray(Charsets.UTF_8).size + it.value.toByteArray(Charsets.UTF_8).size
        }
        if (bytes > MAX_DATA_BYTES) return "custom data must be at most 4 KB"

        return when (val schedule = notification.schedule) {
            is LocalSchedule.After ->
                if (schedule.seconds < 1) "interval must be at least 1 second" else null
            is LocalSchedule.Daily -> timeError(schedule.hour, schedule.minute)
            is LocalSchedule.Weekly ->
                if (schedule.weekday !in 1..7) "weekday must be 1-7 with Monday as 1"
                else timeError(schedule.hour, schedule.minute)
            is LocalSchedule.At -> null
        }
    }

    private fun timeError(hour: Int, minute: Int): String? = when {
        hour !in 0..23 -> "hour must be 0-23"
        minute !in 0..59 -> "minute must be 0-59"
        else -> null
    }

    /**
     * The next firing instant, or null for a one-shot schedule already past.
     *
     * Recurring slots are recomputed from the intended wall-clock time rather
     * than from the previous execution. Adding a fixed interval accumulates the
     * delay of every late alarm, so a daily reminder drifts later each day, and
     * loses or gains an hour permanently at a daylight-saving boundary.
     */
    fun nextOccurrence(
        schedule: LocalSchedule,
        nowMillis: Long,
        calendar: Calendar = Calendar.getInstance(),
    ): Long? = when (schedule) {
        is LocalSchedule.At -> schedule.epochMillis.takeIf { it > nowMillis }
        is LocalSchedule.After -> nowMillis + schedule.seconds * 1000L
        is LocalSchedule.Daily -> {
            val next = calendar.atTime(nowMillis, schedule.hour, schedule.minute)
            if (next.timeInMillis <= nowMillis) next.add(Calendar.DAY_OF_MONTH, 1)
            next.timeInMillis
        }
        is LocalSchedule.Weekly -> {
            val next = calendar.atTime(nowMillis, schedule.hour, schedule.minute)
            // Calendar counts Sunday as 1; the contract is ISO with Monday as 1.
            val target = (schedule.weekday % 7) + 1
            var delta = target - next.get(Calendar.DAY_OF_WEEK)
            if (delta < 0) delta += 7
            if (delta == 0 && next.timeInMillis <= nowMillis) delta = 7
            next.add(Calendar.DAY_OF_MONTH, delta)
            next.timeInMillis
        }
    }

    private fun Calendar.atTime(nowMillis: Long, hour: Int, minute: Int): Calendar {
        val copy = clone() as Calendar
        copy.timeInMillis = nowMillis
        copy.set(Calendar.HOUR_OF_DAY, hour)
        copy.set(Calendar.MINUTE, minute)
        copy.set(Calendar.SECOND, 0)
        copy.set(Calendar.MILLISECOND, 0)
        return copy
    }

    fun isRecurring(schedule: LocalSchedule): Boolean =
        schedule is LocalSchedule.Daily || schedule is LocalSchedule.Weekly

    fun save(context: Context, notification: LocalNotification) {
        preferences(context).edit()
            .putString(notification.id, encode(notification).toString())
            .apply()
    }

    fun remove(context: Context, id: String) {
        preferences(context).edit().remove(id).apply()
    }

    fun load(context: Context, id: String): LocalNotification? =
        preferences(context).getString(id, null)?.let(::decode)

    fun all(context: Context): List<LocalNotification> =
        preferences(context).all.values
            .filterIsInstance<String>()
            .mapNotNull(::decode)

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun encode(notification: LocalNotification): JSONObject {
        val json = JSONObject()
        json.put("id", notification.id)
        json.put("title", notification.title)
        json.put("body", notification.body)
        notification.deepLink?.let { json.put("deepLink", it) }
        json.put("data", JSONObject(notification.customData.toMap()))
        json.put("exact", notification.android.exact)
        json.put("allowWhileIdle", notification.android.allowWhileIdle)
        notification.android.channelId?.let { json.put("channelId", it) }
        notification.android.groupKey?.let { json.put("groupKey", it) }

        when (val schedule = notification.schedule) {
            is LocalSchedule.At -> {
                json.put("type", "at")
                json.put("epochMillis", schedule.epochMillis)
            }
            is LocalSchedule.After -> {
                json.put("type", "after")
                json.put("seconds", schedule.seconds)
            }
            is LocalSchedule.Daily -> {
                json.put("type", "daily")
                json.put("hour", schedule.hour)
                json.put("minute", schedule.minute)
            }
            is LocalSchedule.Weekly -> {
                json.put("type", "weekly")
                json.put("weekday", schedule.weekday)
                json.put("hour", schedule.hour)
                json.put("minute", schedule.minute)
            }
        }
        return json
    }

    fun decode(raw: String): LocalNotification? = try {
        val json = JSONObject(raw)
        val schedule = when (json.getString("type")) {
            "at" -> LocalSchedule.At(json.getLong("epochMillis"))
            "after" -> LocalSchedule.After(json.getLong("seconds"))
            "daily" -> LocalSchedule.Daily(json.getInt("hour"), json.getInt("minute"))
            "weekly" -> LocalSchedule.Weekly(
                json.getInt("weekday"),
                json.getInt("hour"),
                json.getInt("minute"),
            )
            else -> null
        }
        if (schedule == null) {
            null
        } else {
            val dataJson = json.optJSONObject("data") ?: JSONObject()
            val data = buildMap {
                dataJson.keys().forEach { key -> put(key, dataJson.optString(key)) }
            }
            LocalNotification(
                id = json.getString("id"),
                title = json.getString("title"),
                body = json.getString("body"),
                schedule = schedule,
                deepLink = json.optString("deepLink").ifEmpty { null },
                customData = data,
                android = LocalNotificationAndroidOptions(
                    channelId = json.optString("channelId").ifEmpty { null },
                    exact = json.optBoolean("exact", false),
                    allowWhileIdle = json.optBoolean("allowWhileIdle", false),
                    groupKey = json.optString("groupKey").ifEmpty { null },
                ),
            )
        }
    } catch (error: Exception) {
        // A single unreadable entry must not prevent every other reminder from
        // being restored after a reboot.
        null
    }
}

/**
 * Allocates the integers Android uses to identify a scheduled notification.
 *
 * A caller's identifier is a string, but a `PendingIntent` request code is an
 * `Int`, so the two must be mapped. Hashing the string looked like the obvious
 * way and is genuinely stable — `String.hashCode` is specified by the language,
 * so it survives a restart — but it is not unique. Two identifiers that hash
 * alike share one `PendingIntent`: scheduling the second silently replaced the
 * first's alarm, cancelling either cancelled both, and the store went on
 * listing two reminders when only one could ever fire.
 *
 * Codes are therefore handed out from a counter and persisted against the
 * identifier that owns them. That keeps the stability cancellation depends on
 * while making a collision impossible rather than merely unlikely.
 */
internal object LocalNotificationIds {
    private const val PREFERENCES = "notifie.local_notification_ids"

    /**
     * Namespaced so it can never be mistaken for a caller's identifier:
     * `LocalNotificationStore.validate` rejects any id in this namespace.
     */
    private const val NEXT_CODE_KEY = "notifie.local.next_request_code"

    /** Zero means "no code allocated", so allocation starts above it. */
    private const val FIRST_CODE = 1

    private val lock = Any()

    /** The code owned by [id], allocating one the first time it is asked for. */
    fun requestCode(context: Context, id: String): Int = synchronized(lock) {
        val preferences = preferences(context)
        val existing = preferences.getInt(id, 0)
        if (existing != 0) {
            existing
        } else {
            val code = preferences.getInt(NEXT_CODE_KEY, FIRST_CODE)
                .let { if (it == 0) FIRST_CODE else it }
            // Committed rather than applied: this mapping is the only handle on
            // the alarm it identifies, so losing it to a crash would strand a
            // reminder that keeps firing and can no longer be cancelled.
            preferences.edit()
                .putInt(id, code)
                .putInt(NEXT_CODE_KEY, code + 1)
                .commit()
            code
        }
    }

    /** The code owned by [id], or null when none was ever allocated. */
    fun peek(context: Context, id: String): Int? = synchronized(lock) {
        preferences(context).getInt(id, 0).takeIf { it != 0 }
    }

    fun release(context: Context, id: String) {
        synchronized(lock) {
            preferences(context).edit().remove(id).commit()
        }
    }

    /**
     * The derivation used before codes were allocated.
     *
     * Kept only so an alarm armed by an earlier version can still be found and
     * cleared after an upgrade. Nothing is ever scheduled with it again.
     */
    fun legacyRequestCode(id: String): Int =
        (LocalNotificationStore.ID_NAMESPACE + id).hashCode()

    private fun preferences(context: Context) =
        context.applicationContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
}

internal object LocalNotificationScheduler {

    fun schedule(
        context: Context,
        notification: LocalNotification,
        nowMillis: Long = System.currentTimeMillis(),
    ): LocalScheduleResult {
        LocalNotificationStore.validate(notification)?.let {
            return LocalScheduleResult.Failed(LocalScheduleError.INVALID_REQUEST, it)
        }

        val triggerAt = LocalNotificationStore.nextOccurrence(notification.schedule, nowMillis)
            ?: return LocalScheduleResult.Failed(LocalScheduleError.SCHEDULE_IN_PAST)

        // Persisted before the alarm is set: a definition without an alarm is
        // recoverable at next boot, whereas an alarm without a definition fires
        // a notification whose content has been lost.
        LocalNotificationStore.save(context, notification)

        return arm(context, notification, triggerAt)
    }

    fun arm(
        context: Context,
        notification: LocalNotification,
        triggerAtMillis: Long,
    ): LocalScheduleResult {
        val manager = context.getSystemService(AlarmManager::class.java)
            ?: return LocalScheduleResult.Failed(
                LocalScheduleError.PLATFORM_ERROR,
                "AlarmManager unavailable",
            )

        val exactGranted = notification.android.exact && canScheduleExact(manager)
        clearLegacyAlarm(context, notification.id, manager)
        val pendingIntent = firePendingIntent(context, notification.id)

        return try {
            when {
                exactGranted && notification.android.allowWhileIdle ->
                    manager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent,
                    )
                exactGranted ->
                    manager.setExact(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                notification.android.allowWhileIdle ->
                    manager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent,
                    )
                else -> manager.set(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
            }
            LocalScheduleResult.Scheduled(
                precision = if (exactGranted) {
                    LocalSchedulePrecision.EXACT
                } else {
                    LocalSchedulePrecision.INEXACT
                },
                nextTriggerAtMillis = triggerAtMillis,
            )
        } catch (error: SecurityException) {
            // Reached when exact-alarm permission is revoked between the check
            // and the call. Degrading is better than losing the reminder.
            manager.set(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
            LocalScheduleResult.Scheduled(LocalSchedulePrecision.INEXACT, triggerAtMillis)
        }
    }

    fun cancel(context: Context, id: String) {
        val manager = context.getSystemService(AlarmManager::class.java)
        if (manager != null) {
            LocalNotificationIds.peek(context, id)
                ?.let { armedAlarm(context, id, it) }
                ?.let { alarm ->
                    manager.cancel(alarm)
                    alarm.cancel()
                }
            clearLegacyAlarm(context, id, manager)
        }
        forget(context, id)
    }

    /**
     * The reminders that will actually fire.
     *
     * The store records what the caller asked for; the alarm is only the
     * mechanism. Reporting the store alone described reminders the operating
     * system had no alarm for and would never deliver, so each entry is
     * reconciled against the alarm that is supposed to back it.
     */
    fun pending(
        context: Context,
        nowMillis: Long = System.currentTimeMillis(),
    ): List<PendingLocalNotification> =
        LocalNotificationStore.all(context).mapNotNull { notification ->
            val triggerAt =
                LocalNotificationStore.nextOccurrence(notification.schedule, nowMillis)
            if (triggerAt == null) {
                // A one-shot whose moment has passed can never fire. Reporting
                // it would promise a delivery that cannot happen, and keeping
                // it would grow storage without bound.
                forget(context, notification.id)
                null
            } else {
                // A missing alarm means the intent outlived its mechanism.
                // Re-arming is what makes the answer true; dropping the entry
                // instead would silently discard a reminder the caller still
                // expects.
                if (!hasArmedAlarm(context, notification.id)) {
                    arm(context, notification, triggerAt)
                }
                PendingLocalNotification(notification.id, triggerAt)
            }
        }

    /**
     * Re-establishes every stored alarm.
     *
     * `AlarmManager` keeps nothing across a reboot or an application upgrade,
     * so without this a daily reminder stops firing after a restart and never
     * reports an error.
     */
    fun restoreAll(context: Context, nowMillis: Long = System.currentTimeMillis()) {
        for (notification in LocalNotificationStore.all(context)) {
            val triggerAt = LocalNotificationStore.nextOccurrence(notification.schedule, nowMillis)
            if (triggerAt == null) {
                // A one-shot that elapsed while the device was off can never
                // fire; dropping it keeps storage from growing without bound.
                forget(context, notification.id)
            } else {
                arm(context, notification, triggerAt)
            }
        }
    }

    private fun canScheduleExact(manager: AlarmManager): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            manager.canScheduleExactAlarms()
        } else {
            true
        }

    /**
     * A stable request code for [id], allocated on first use.
     *
     * Stability is what makes cancellation and replacement work after a
     * restart; uniqueness is what stops one reminder clobbering another.
     */
    internal fun requestCode(context: Context, id: String): Int =
        LocalNotificationIds.requestCode(context, id)

    private fun fireIntent(context: Context, id: String): Intent =
        Intent(context.applicationContext, LocalNotificationAlarmReceiver::class.java)
            .setAction(LocalNotificationAlarmReceiver.ACTION_FIRE)
            .putExtra(LocalNotificationAlarmReceiver.EXTRA_ID, id)

    private fun firePendingIntent(context: Context, id: String): PendingIntent =
        PendingIntent.getBroadcast(
            context.applicationContext,
            requestCode(context, id),
            fireIntent(context, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * The alarm already armed under [code], or null when there is none.
     *
     * `FLAG_NO_CREATE` is what makes this a question rather than an action: it
     * reports the operating system's actual state instead of creating the very
     * thing it was asked about.
     */
    private fun armedAlarm(context: Context, id: String, code: Int): PendingIntent? =
        PendingIntent.getBroadcast(
            context.applicationContext,
            code,
            fireIntent(context, id),
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )

    /** True while the operating system still holds an alarm for [id]. */
    private fun hasArmedAlarm(context: Context, id: String): Boolean {
        val allocated = LocalNotificationIds.peek(context, id)
        if (allocated != null && armedAlarm(context, id, allocated) != null) return true
        return armedAlarm(context, id, LocalNotificationIds.legacyRequestCode(id)) != null
    }

    /**
     * Clears an alarm armed by a version that derived its request code from a
     * hash. Without this an upgrade would leave that alarm running invisibly
     * beside the newly allocated one, and the reminder would fire twice.
     */
    private fun clearLegacyAlarm(context: Context, id: String, manager: AlarmManager) {
        val legacy = armedAlarm(context, id, LocalNotificationIds.legacyRequestCode(id)) ?: return
        manager.cancel(legacy)
        legacy.cancel()
    }

    /** Drops every trace of [id]: the definition and the code it owned. */
    private fun forget(context: Context, id: String) {
        LocalNotificationStore.remove(context, id)
        LocalNotificationIds.release(context, id)
    }
}

/** Presents a scheduled notification and re-arms it when recurring. */
public class LocalNotificationAlarmReceiver : BroadcastReceiver() {
    public companion object {
        internal const val ACTION_FIRE = "dev.notifie.LOCAL_NOTIFICATION_FIRE"
        internal const val EXTRA_ID = "notifie_local_id"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(EXTRA_ID) ?: return
        val notification = LocalNotificationStore.load(context, id) ?: return

        val data = buildMap {
            putAll(notification.customData)
            notification.deepLink?.let { put(Notifie.deepLinkKey, it) }
            put(EXTRA_ID, id)
        }
        NotifieNotifications.show(
            context = context,
            title = notification.title,
            body = notification.body,
            imageUrl = null,
            data = data,
        )

        if (LocalNotificationStore.isRecurring(notification.schedule)) {
            // Recomputed from the intended wall-clock slot rather than from now,
            // so a late alarm does not push every future occurrence later.
            val next = LocalNotificationStore.nextOccurrence(
                notification.schedule,
                System.currentTimeMillis(),
            )
            if (next != null) LocalNotificationScheduler.arm(context, notification, next)
        } else {
            LocalNotificationStore.remove(context, id)
        }
    }
}

/** Restores alarms after a reboot or an application upgrade. */
public class LocalNotificationBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> LocalNotificationScheduler.restoreAll(context)
        }
    }
}
