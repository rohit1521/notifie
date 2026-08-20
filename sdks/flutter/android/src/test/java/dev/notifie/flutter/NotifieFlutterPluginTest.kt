package dev.notifie.flutter

import android.app.Activity
import android.app.Application
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
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
import org.robolectric.Robolectric
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

    /** Mirrors every method the Dart side invokes on this channel. */
    private val dartMethods = listOf(
        "scheduleLocalNotification",
        "cancelLocalNotification",
        "pendingLocalNotifications",
        "localNotificationCapabilities",
        "requestNotificationPermission",
        "markOpenHandlerReady",
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

    /**
     * A tap on a locally scheduled notification reaches Dart.
     *
     * This is the defect a real device found: the tap opened the app, so it
     * looked fixed, but the payload never crossed the bridge and the host could
     * not tell which notification had been tapped or where to navigate.
     */
    @Test
    fun `a local notification tap is delivered to Dart`() {
        val plugin = attachedPlugin()
        plugin.onAttachedToActivity(activityBinding(localOpenIntent()))

        val opens = markReady(plugin)

        assertEquals(1, opens.size)
        val open = opens.first() as Map<*, *>
        assertEquals("myapp://review", open["gk_deep_link"])
        assertEquals("daily-review", open["notifie_local_id"])
    }

    /**
     * Android already delivers remote opens through
     * FirebaseMessaging.onMessageOpenedApp. Forwarding them here as well would
     * report one tap twice, which double-counts the open rate.
     */
    @Test
    fun `a remote push tap is left to Firebase rather than reported twice`() {
        val plugin = attachedPlugin()
        val remote = Intent().apply {
            putExtra("gk_invocation_id", "inv-1")
            putExtra("gk_deep_link", "myapp://remote")
        }
        plugin.onAttachedToActivity(activityBinding(remote))

        assertEquals(0, markReady(plugin).size)
    }

    /**
     * getIntent() keeps returning the launch intent, so a rotation or a later
     * re-attach would otherwise replay an old tap as a new one.
     */
    @Test
    fun `the same tap is never delivered twice`() {
        val plugin = attachedPlugin()
        val intent = localOpenIntent()
        val binding = activityBinding(intent)

        plugin.onAttachedToActivity(binding)
        plugin.onReattachedToActivityForConfigChanges(binding)
        plugin.onNewIntent(intent)

        assertEquals(1, markReady(plugin).size)
    }

    /**
     * A cold start from a tap delivers the intent long before the Dart isolate
     * registers its handler. Dropping it would lose the only signal of why the
     * app was launched.
     */
    @Test
    fun `a tap that arrives before Dart is listening is kept, then handed over once`() {
        val plugin = attachedPlugin()
        plugin.onAttachedToActivity(activityBinding(localOpenIntent()))

        assertEquals(1, markReady(plugin).size)
        // Already drained: a second attach must not replay it.
        assertEquals(0, markReady(plugin).size)
    }

    @Suppress("UNCHECKED_CAST")
    private fun markReady(plugin: NotifieFlutterPlugin): List<Any?> {
        val result = RecordingResult()
        plugin.onMethodCall(MethodCall("markOpenHandlerReady", null), result)
        val reply = result.success as Map<*, *>
        return reply["opens"] as List<Any?>
    }

    private fun localOpenIntent(): Intent = Intent().apply {
        putExtra("notifie_local_id", "daily-review")
        putExtra("gk_deep_link", "myapp://review")
    }

    private fun activityBinding(intent: Intent): ActivityPluginBinding {
        val activity = Robolectric.buildActivity(Activity::class.java).get()
        activity.intent = intent
        val binding = mock(ActivityPluginBinding::class.java)
        `when`(binding.activity).thenReturn(activity)
        return binding
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
