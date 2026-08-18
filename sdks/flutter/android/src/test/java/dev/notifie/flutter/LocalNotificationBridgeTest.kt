package dev.notifie.flutter

import dev.notifie.LocalSchedule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Decoding is where Dart's dynamic map meets Kotlin's types.
 *
 * Every value arrives as `Any?` through the standard message codec, so a wrong
 * type or a missing key is caught here or not at all. The numeric cases matter
 * most: Dart sends a plain `int`, which the codec delivers as an `Integer` for
 * small values and a `Long` for large ones, so anything that accepts only one
 * of the two breaks on a value the developer never thinks about.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalNotificationBridgeTest {

    private fun arguments(
        id: Any? = "streak",
        title: Any? = "Keep it up",
        body: Any? = "Practise today",
        schedule: Any? = mapOf("type" to "after", "seconds" to 600),
        extra: Map<String, Any?> = emptyMap(),
    ): Map<String, Any?> = buildMap {
        put("id", id)
        put("title", title)
        put("body", body)
        put("schedule", schedule)
        putAll(extra)
    }

    private fun decodeFailure(arguments: Map<*, *>): String {
        try {
            LocalNotificationBridge.decode(arguments)
        } catch (error: IllegalArgumentException) {
            return error.message.orEmpty()
        }
        fail("decoding should have been rejected")
        return ""
    }

    @Test
    fun `a complete payload decodes into the native model`() {
        val notification = LocalNotificationBridge.decode(
            arguments(
                extra = mapOf(
                    "deepLink" to "myapp://streak",
                    "customData" to mapOf("kind" to "reminder"),
                ),
            ),
        )

        assertEquals("streak", notification.id)
        assertEquals("Keep it up", notification.title)
        assertEquals("Practise today", notification.body)
        assertEquals("myapp://streak", notification.deepLink)
        assertEquals(mapOf("kind" to "reminder"), notification.customData)
        assertEquals(LocalSchedule.After(600), notification.schedule)
    }

    @Test
    fun `a missing required field names the field that is missing`() {
        assertTrue(decodeFailure(arguments(id = null)).contains("id"))
        assertTrue(decodeFailure(arguments(title = null)).contains("title"))
        assertTrue(decodeFailure(arguments(body = null)).contains("body"))
        assertTrue(decodeFailure(arguments(schedule = null)).contains("schedule"))
    }

    @Test
    fun `a field of the wrong type is rejected rather than coerced`() {
        // A ClassCastException here would surface in Dart as an opaque
        // PlatformException with no indication of which field was wrong.
        assertTrue(decodeFailure(arguments(id = 42)).contains("id"))
        assertTrue(decodeFailure(arguments(title = listOf("nope"))).contains("title"))
    }

    @Test
    fun `an unknown schedule type is named in the failure`() {
        val message = decodeFailure(arguments(schedule = mapOf("type" to "monthly")))

        assertTrue(message.contains("monthly"))
    }

    @Test
    fun `an interval accepts both widths the codec can deliver`() {
        // Small ints arrive as Integer, large ones as Long. Both are the same
        // `int` in Dart, so both have to decode.
        val asInteger = LocalNotificationBridge.decode(
            arguments(schedule = mapOf("type" to "after", "seconds" to 600)),
        )
        val asLong = LocalNotificationBridge.decode(
            arguments(schedule = mapOf("type" to "after", "seconds" to 600L)),
        )

        assertEquals(LocalSchedule.After(600), asInteger.schedule)
        assertEquals(LocalSchedule.After(600), asLong.schedule)
    }

    @Test
    fun `calendar schedules decode their components`() {
        val daily = LocalNotificationBridge.decode(
            arguments(schedule = mapOf("type" to "daily", "hour" to 9, "minute" to 30)),
        )
        val weekly = LocalNotificationBridge.decode(
            arguments(
                schedule = mapOf("type" to "weekly", "weekday" to 7, "hour" to 9, "minute" to 0),
            ),
        )

        assertEquals(LocalSchedule.Daily(9, 30), daily.schedule)
        // ISO weekdays: Sunday is 7, not 0. Converting to Calendar's
        // Sunday-first numbering is the native SDK's job, not the bridge's.
        assertEquals(LocalSchedule.Weekly(7, 9, 0), weekly.schedule)
    }

    @Test
    fun `an absolute schedule is read as an instant, not a local time`() {
        val notification = LocalNotificationBridge.decode(
            arguments(
                schedule = mapOf("type" to "at", "timestamp" to "2030-01-01T09:00:00Z"),
            ),
        )

        assertEquals(LocalSchedule.At(1_893_488_400_000), notification.schedule)
    }

    @Test
    fun `a timestamp without an offset is refused rather than guessed at`() {
        // Reinterpreting a bare local time in the device's timezone would fire
        // the notification at the wrong moment for most of the world.
        val message = decodeFailure(
            arguments(schedule = mapOf("type" to "at", "timestamp" to "2030-01-01 09:00")),
        )

        assertTrue(message.contains("ISO-8601"))
    }

    @Test
    fun `custom data values are stringified to match the platform payload`() {
        val notification = LocalNotificationBridge.decode(
            arguments(extra = mapOf("customData" to mapOf("count" to 3, "flag" to true))),
        )

        assertEquals(mapOf("count" to "3", "flag" to "true"), notification.customData)
    }
}
