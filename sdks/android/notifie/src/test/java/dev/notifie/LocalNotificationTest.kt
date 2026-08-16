package dev.notifie

import dev.notifie.Notifie

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.Calendar
import java.util.TimeZone

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalNotificationTest {
    private lateinit var application: Application

    /**
     * A calendar pinned to a timezone that observes daylight saving.
     *
     * Without pinning, the schedule assertions are only as meaningful as the
     * machine's timezone: in a zone without DST the transition case passes
     * trivially and would not catch a drifting implementation.
     */
    private fun newYork(): Calendar =
        Calendar.getInstance(TimeZone.getTimeZone("America/New_York"))

    private fun instant(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
    ): Long {
        val calendar = newYork()
        calendar.set(year, month - 1, day, hour, minute, 0)
        calendar.set(Calendar.MILLISECOND, 0)
        return calendar.timeInMillis
    }

    private fun reminder(
        id: String = "daily-reminder",
        title: String = "Time to practise",
        body: String = "Your streak is waiting.",
        schedule: LocalSchedule = LocalSchedule.Daily(9, 0),
        deepLink: String? = null,
        customData: Map<String, String> = emptyMap(),
        android: LocalNotificationAndroidOptions = LocalNotificationAndroidOptions(),
    ) = LocalNotification(id, title, body, schedule, deepLink, customData, android)

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
        application
            .getSharedPreferences(LocalNotificationStore.PREFERENCES, android.content.Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    // MARK: - Account-free operation

    @Test
    fun `scheduling requires no initialization`() {
        // Notifie.initialize() is never called: local notifications must work
        // without an API key, a base URL or a network.
        val result = LocalNotificationScheduler.schedule(application, reminder())

        assertTrue(result is LocalScheduleResult.Scheduled)
    }

    @Test
    fun `schedule is persisted so it survives process death`() {
        LocalNotificationScheduler.schedule(application, reminder(id = "streak"))

        val stored = LocalNotificationStore.load(application, "streak")

        assertNotNull(stored)
        assertEquals("Time to practise", stored?.title)
    }

    // MARK: - Precision

    @Test
    fun `inexact delivery is the default`() {
        val result = LocalNotificationScheduler.schedule(application, reminder())

        assertEquals(
            LocalSchedulePrecision.INEXACT,
            (result as LocalScheduleResult.Scheduled).precision,
        )
    }

    @Test
    fun `granted precision is reported rather than assumed`() {
        val result = LocalNotificationScheduler.schedule(
            application,
            reminder(android = LocalNotificationAndroidOptions(exact = true)),
        )

        // Robolectric grants exact alarms; the contract is that whatever was
        // actually granted is reported, never silently assumed.
        assertTrue(result is LocalScheduleResult.Scheduled)
        assertNotNull((result as LocalScheduleResult.Scheduled).precision)
    }

    // MARK: - Cancellation

    @Test
    fun `cancel is idempotent and forgets the definition`() {
        LocalNotificationScheduler.schedule(application, reminder(id = "streak"))

        LocalNotificationScheduler.cancel(application, "streak")
        LocalNotificationScheduler.cancel(application, "streak")
        LocalNotificationScheduler.cancel(application, "never-scheduled")

        assertNull(LocalNotificationStore.load(application, "streak"))
        assertTrue(LocalNotificationScheduler.pending(application).isEmpty())
    }

    @Test
    fun `rescheduling the same id replaces rather than duplicates`() {
        LocalNotificationScheduler.schedule(application, reminder(id = "streak", title = "First"))
        LocalNotificationScheduler.schedule(application, reminder(id = "streak", title = "Second"))

        assertEquals(1, LocalNotificationScheduler.pending(application).size)
        assertEquals("Second", LocalNotificationStore.load(application, "streak")?.title)
    }

    @Test
    fun `request codes are stable across processes`() {
        // Cancellation after a restart depends on regenerating the same code,
        // so this must not use identity or a random value.
        assertEquals(
            LocalNotificationScheduler.requestCode("streak"),
            LocalNotificationScheduler.requestCode("streak"),
        )
        assertTrue(
            LocalNotificationScheduler.requestCode("a") !=
                LocalNotificationScheduler.requestCode("b"),
        )
    }

    // MARK: - Reboot

    @Test
    fun `recurring schedules are restored after reboot`() {
        LocalNotificationScheduler.schedule(application, reminder(id = "streak"))

        LocalNotificationBootReceiver().onReceive(
            application,
            android.content.Intent(android.content.Intent.ACTION_BOOT_COMPLETED),
        )

        assertEquals(1, LocalNotificationScheduler.pending(application).size)
    }

    @Test
    fun `one-shot schedules that elapsed while off are discarded`() {
        // Keeping them would grow storage without bound and re-arm alarms that
        // can never fire.
        val past = instant(2020, 1, 1, 9, 0)
        LocalNotificationStore.save(
            application,
            reminder(id = "expired", schedule = LocalSchedule.At(past)),
        )

        LocalNotificationScheduler.restoreAll(application, instant(2026, 3, 10, 12, 0))

        assertNull(LocalNotificationStore.load(application, "expired"))
    }

    // MARK: - Schedules

    @Test
    fun `absolute time already past is rejected`() {
        val result = LocalNotificationScheduler.schedule(
            application,
            reminder(schedule = LocalSchedule.At(instant(2020, 1, 1, 9, 0))),
        )

        assertEquals(
            LocalScheduleError.SCHEDULE_IN_PAST,
            (result as LocalScheduleResult.Failed).error,
        )
    }

    @Test
    fun `daily time already passed today moves to tomorrow`() {
        val next = LocalNotificationStore.nextOccurrence(
            LocalSchedule.Daily(9, 0),
            instant(2026, 3, 10, 12, 0),
            newYork(),
        )

        assertEquals(instant(2026, 3, 11, 9, 0), next)
    }

    @Test
    fun `daily schedule holds wall-clock hour across daylight saving`() {
        // US daylight saving begins on 8 March 2026. Adding a fixed 24 hours
        // would drift the reminder to 10am and leave it there.
        val next = LocalNotificationStore.nextOccurrence(
            LocalSchedule.Daily(9, 0),
            instant(2026, 3, 7, 20, 0),
            newYork(),
        )

        val calendar = newYork()
        calendar.timeInMillis = next!!
        assertEquals(9, calendar.get(Calendar.HOUR_OF_DAY))
        assertEquals(8, calendar.get(Calendar.DAY_OF_MONTH))
    }

    @Test
    fun `weekly slot later today does not skip a week`() {
        // 10 March 2026 is a Tuesday; 18:00 is still ahead of noon.
        val next = LocalNotificationStore.nextOccurrence(
            LocalSchedule.Weekly(2, 18, 0),
            instant(2026, 3, 10, 12, 0),
            newYork(),
        )

        assertEquals(instant(2026, 3, 10, 18, 0), next)
    }

    @Test
    fun `weekly slot already passed today rolls to next week`() {
        val next = LocalNotificationStore.nextOccurrence(
            LocalSchedule.Weekly(2, 9, 0),
            instant(2026, 3, 10, 12, 0),
            newYork(),
        )

        assertEquals(instant(2026, 3, 17, 9, 0), next)
    }

    @Test
    fun `iso sunday maps to calendar sunday`() {
        val next = LocalNotificationStore.nextOccurrence(
            LocalSchedule.Weekly(7, 9, 0),
            instant(2026, 3, 10, 12, 0),
            newYork(),
        )

        val calendar = newYork()
        calendar.timeInMillis = next!!
        assertEquals(Calendar.SUNDAY, calendar.get(Calendar.DAY_OF_WEEK))
        assertEquals(15, calendar.get(Calendar.DAY_OF_MONTH))
    }

    // MARK: - Validation

    @Test
    fun `reserved namespace is rejected`() {
        val result = LocalNotificationScheduler.schedule(
            application,
            reminder(id = "notifie.local.spoofed"),
        )

        assertEquals(
            LocalScheduleError.INVALID_REQUEST,
            (result as LocalScheduleResult.Failed).error,
        )
    }

    @Test
    fun `identifier charset is rejected`() {
        for (id in listOf("has space", "has/slash", "")) {
            val result = LocalNotificationScheduler.schedule(application, reminder(id = id))
            assertTrue("expected rejection for \"$id\"", result is LocalScheduleResult.Failed)
        }
    }

    @Test
    fun `reserved custom data prefix is rejected`() {
        val result = LocalNotificationScheduler.schedule(
            application,
            reminder(customData = mapOf("gk_invocation_id" to "stolen")),
        )

        assertEquals(
            LocalScheduleError.INVALID_REQUEST,
            (result as LocalScheduleResult.Failed).error,
        )
    }

    @Test
    fun `custom data budget is measured in utf8 bytes`() {
        // 1400 three-byte characters passes any character-count limit but
        // exceeds the 4 KB byte budget.
        val wide = "한".repeat(1400)
        val result = LocalNotificationScheduler.schedule(
            application,
            reminder(customData = mapOf("note" to wide)),
        )

        assertEquals(
            LocalScheduleError.INVALID_REQUEST,
            (result as LocalScheduleResult.Failed).error,
        )
    }

    // MARK: - Persistence round trip

    @Test
    fun `stored definitions round trip through json`() {
        val original = reminder(
            id = "full",
            schedule = LocalSchedule.Weekly(3, 7, 45),
            deepLink = "myapp://streak",
            customData = mapOf("source" to "test"),
            android = LocalNotificationAndroidOptions(
                channelId = "reminders",
                exact = true,
                allowWhileIdle = true,
                groupKey = "streaks",
            ),
        )

        val decoded = LocalNotificationStore.decode(
            LocalNotificationStore.encode(original).toString(),
        )

        assertEquals(original, decoded)
    }

    @Test
    fun `one unreadable entry does not lose every other reminder`() {
        LocalNotificationScheduler.schedule(application, reminder(id = "good"))
        application
            .getSharedPreferences(LocalNotificationStore.PREFERENCES, android.content.Context.MODE_PRIVATE)
            .edit().putString("corrupt", "{not json").commit()

        val all = LocalNotificationStore.all(application)

        assertEquals(listOf("good"), all.map { it.id })
    }
}
