package dev.notifie

import android.app.Application
import android.app.Notification
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * How a displayed notification routes a tap.
 *
 * This exists because of a defect that produced no crash, no log line and no
 * visible symptom at all. The SDK built the tap's PendingIntent by naming its
 * own open activity as an explicit component. That is fine in a native app and
 * silently fatal in a Flutter one, because the Flutter plugin removes this
 * activity from the merged manifest so it can route deep links through Dart.
 * Every locally scheduled notification in a Flutter app therefore pointed at a
 * class the app did not declare, and tapping it failed with
 * START_CLASS_NOT_FOUND and did nothing whatsoever.
 *
 * Asserting on the action rather than the component is the whole point: the
 * component is exactly what must be allowed to differ between hosts.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NotificationTapIntentTest {
    private lateinit var application: Application

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
        // Deliberately not calling Notifie.initialize. Displaying a
        // notification needs only constants, and Robolectric shares one
        // classloader per configured SDK level — so initializing here would
        // leave Notifie initialized for every other sdk=35 class in the run and
        // break NotifieClientTest's "before initialization" cases. That
        // isolation is accidental elsewhere in this suite: the neighbouring
        // deep-link test gets away with initializing only because it runs at
        // sdk=32 and lands in a different classloader.
    }

    private fun displayedIntent(): Intent {
        NotifieNotifications.show(
            application,
            title = "Time to practise",
            body = "Your streak is waiting.",
            imageUrl = null,
            data = mapOf(Notifie.deepLinkKey to "demo://orders/42"),
        )

        val manager = shadowOf(
            application.getSystemService(android.app.NotificationManager::class.java),
        )
        val posted: Notification = manager.allNotifications.single()
        return shadowOf(posted.contentIntent).savedIntent
    }

    @Test
    fun aTapIsRoutedByActionSoAHostAppCanReplaceTheActivity() {
        val intent = displayedIntent()

        assertEquals(Notifie.notificationOpenAction, intent.action)
        // Naming a component here is the defect. A Flutter app removes this
        // SDK's activity, so an explicit component cannot resolve.
        assertNull(intent.component)
    }

    @Test
    fun aTapCanNeverLeaveTheApp() {
        // An action-only intent would be resolvable by any installed app that
        // declared the same action, which would leak the payload.
        assertEquals(application.packageName, displayedIntent().`package`)
    }

    @Test
    fun theTapCarriesThePayloadItNeedsToAttributeTheOpen() {
        val intent = displayedIntent()

        assertEquals("demo://orders/42", intent.getStringExtra(Notifie.deepLinkKey))
    }
}
