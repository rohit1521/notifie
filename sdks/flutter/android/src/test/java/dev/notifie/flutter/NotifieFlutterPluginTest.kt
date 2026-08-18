package dev.notifie.flutter

import android.app.Application
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.mockito.Mockito.mock
import org.mockito.Mockito.`when`
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The method channel is a contract between two languages that no compiler
 * checks. A name Dart invokes but Android never implements, or a reply that
 * never arrives, fails only at runtime on a device — which is how a broken
 * notification tap reached a published release.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NotifieFlutterPluginTest {

    private lateinit var application: Application

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
    }

    /**
     * Mirrors the calls in `sdks/flutter/lib/src/local_notification_channel.dart`.
     * `markOpenHandlerReady` is deliberately absent: the Dart side guards it to
     * iOS, so Android answering `notImplemented` for it is correct.
     */
    private val dartMethods = listOf(
        "scheduleLocalNotification",
        "cancelLocalNotification",
        "pendingLocalNotifications",
        "localNotificationCapabilities",
        "requestNotificationPermission",
    )

    @Test
    fun `every method the Dart side invokes is implemented natively`() {
        val plugin = attachedPlugin()

        for (method in dartMethods) {
            val result = RecordingResult()
            plugin.onMethodCall(MethodCall(method, argumentsFor(method)), result)

            assertFalse("$method has no native handler", result.notImplemented)
            assertEquals("$method must reply exactly once", 1, result.replies)
        }
    }

    @Test
    fun `an unknown method is reported rather than silently succeeding`() {
        val result = RecordingResult()

        attachedPlugin().onMethodCall(MethodCall("somethingElse", null), result)

        assertTrue(result.notImplemented)
        assertEquals(1, result.replies)
    }

    @Test
    fun `a call before the engine attaches is refused instead of crashing`() {
        val result = RecordingResult()

        // Reachable in practice: a channel call can race plugin registration.
        NotifieFlutterPlugin().onMethodCall(
            MethodCall("pendingLocalNotifications", null),
            result,
        )

        assertEquals("platform_error", result.errorCode)
        assertEquals(1, result.replies)
    }

    @Test
    fun `a call after the engine detaches is refused instead of crashing`() {
        val plugin = NotifieFlutterPlugin()
        val binding = binding()
        plugin.onAttachedToEngine(binding)
        plugin.onDetachedFromEngine(binding)

        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("pendingLocalNotifications", null), result)

        assertEquals("platform_error", result.errorCode)
        assertEquals(1, result.replies)
    }

    @Test
    fun `scheduling without arguments is refused as an invalid request`() {
        val result = RecordingResult()

        attachedPlugin().onMethodCall(MethodCall("scheduleLocalNotification", null), result)

        assertEquals("invalid_request", result.errorCode)
        assertEquals(1, result.replies)
    }

    @Test
    fun `an invalid schedule is reported in the reply, not thrown`() {
        val result = RecordingResult()

        // Dart reads the failure out of the reply map, so a rejected schedule
        // must still be a successful channel call.
        attachedPlugin().onMethodCall(
            MethodCall(
                "scheduleLocalNotification",
                argumentsFor("scheduleLocalNotification").toMutableMap().apply {
                    this["schedule"] = mapOf("type" to "never")
                },
            ),
            result,
        )

        val reply = result.success as Map<*, *>
        assertEquals("invalid_request", reply["error"])
        assertEquals(1, result.replies)
    }

    @Test
    fun `cancelling replies even when the id is missing`() {
        val result = RecordingResult()

        attachedPlugin().onMethodCall(MethodCall("cancelLocalNotification", null), result)

        // A reply that never arrives leaves the Dart future hanging forever.
        assertEquals(1, result.replies)
        assertFalse(result.notImplemented)
    }

    @Test
    fun `capabilities describe the Android platform as Dart expects`() {
        val result = RecordingResult()

        attachedPlugin().onMethodCall(MethodCall("localNotificationCapabilities", null), result)

        val capabilities = result.success as Map<*, *>
        assertNotNull(capabilities["permission"])
        assertNotNull(capabilities["canScheduleExactAlarms"])
        assertEquals(
            listOf("at", "after", "daily", "weekly"),
            capabilities["supportedSchedules"],
        )
        // Android publishes no fixed pending limit; null is the honest answer
        // and Dart decodes it as "unknown" rather than as zero.
        assertTrue(capabilities.containsKey("pendingCapacity"))
        assertEquals(null, capabilities["pendingCapacity"])
    }

    private fun argumentsFor(method: String): Map<String, Any?> = when (method) {
        "scheduleLocalNotification" -> mapOf(
            "id" to "streak",
            "title" to "Keep it up",
            "body" to "Practise today",
            "schedule" to mapOf("type" to "after", "seconds" to 600),
        )
        "cancelLocalNotification" -> mapOf("id" to "streak")
        else -> emptyMap()
    }

    private fun attachedPlugin(): NotifieFlutterPlugin =
        NotifieFlutterPlugin().apply { onAttachedToEngine(binding()) }

    private fun binding(): FlutterPlugin.FlutterPluginBinding {
        val binding = mock(FlutterPlugin.FlutterPluginBinding::class.java)
        `when`(binding.applicationContext).thenReturn(application)
        `when`(binding.binaryMessenger).thenReturn(mock(BinaryMessenger::class.java))
        return binding
    }
}

/** Records the reply so a test can assert it arrived exactly once. */
private class RecordingResult : MethodChannel.Result {
    var success: Any? = null
    var errorCode: String? = null
    var notImplemented = false
    var replies = 0

    override fun success(result: Any?) {
        replies += 1
        success = result
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        replies += 1
        this.errorCode = errorCode
    }

    override fun notImplemented() {
        replies += 1
        notImplemented = true
    }
}
