package dev.notifie.flutter

import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The tap path, which is where a Flutter host differs from a native one.
 *
 * This plugin removes the native SDK's open activity from the merged manifest
 * and substitutes this one, so the deep link is handed to Dart rather than
 * navigated natively. That substitution is exactly what silently broke every
 * locally scheduled notification once, and nothing executed it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NotifieNotificationOpenActivityTest {

    private val application = RuntimeEnvironment.getApplication()

    /** Robolectric ships no launcher activity, so the host app needs one. */
    private fun installLauncherActivity() {
        val launcher = ComponentName(application, "dev.notifie.flutter.HostLauncherActivity")
        val packageManager = shadowOf(application.packageManager)
        packageManager.addActivityIfNotPresent(launcher)
        packageManager.addIntentFilterForActivity(
            launcher,
            IntentFilter(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) },
        )
    }

    private fun tap(extras: Map<String, String>): android.app.Activity {
        val intent = Intent(application, NotifieNotificationOpenActivity::class.java)
        extras.forEach { (key, value) -> intent.putExtra(key, value) }
        return Robolectric.buildActivity(NotifieNotificationOpenActivity::class.java, intent)
            .create()
            .get()
    }

    @Test
    fun `a tap launches the host app and forwards the payload to Dart`() {
        installLauncherActivity()

        val activity = tap(
            mapOf(
                "gk_deep_link" to "myapp://streak",
                "notifie_local_id" to "streak",
            ),
        )
        val launched = shadowOf(activity).nextStartedActivity

        assertNotNull("the tap must launch the host app", launched)
        // Dart resolves the route, so the payload has to survive the hop.
        assertEquals("myapp://streak", launched.getStringExtra("gk_deep_link"))
        assertEquals("streak", launched.getStringExtra("notifie_local_id"))
    }

    @Test
    fun `the launch reuses the running task rather than stacking a second copy`() {
        installLauncherActivity()

        val launched = shadowOf(tap(mapOf("notifie_local_id" to "streak"))).nextStartedActivity

        // Without CLEAR_TOP and SINGLE_TOP a tap builds a second copy of the
        // app on top of the running one.
        assertTrue(launched.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
        assertTrue(launched.flags and Intent.FLAG_ACTIVITY_CLEAR_TOP != 0)
        assertTrue(launched.flags and Intent.FLAG_ACTIVITY_SINGLE_TOP != 0)
    }

    @Test
    fun `the trampoline never lingers on screen`() {
        installLauncherActivity()

        // It is translucent and has no UI; leaving it running would swallow the
        // back gesture and show the user an empty screen.
        assertTrue(tap(mapOf("notifie_local_id" to "streak")).isFinishing)
    }

    @Test
    fun `a host with no launcher activity is left alone rather than crashed`() {
        // Deliberately no launcher installed. An unresolvable launch must not
        // take the app down from a notification tap.
        val activity = tap(mapOf("notifie_local_id" to "streak"))

        assertNull(shadowOf(activity).nextStartedActivity)
        assertTrue(activity.isFinishing)
    }
}
