package dev.notifie

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * Tapping a notification must never take the host app down.
 *
 * A notification carries whatever deep link the sender typed, and the app that
 * receives it may be an older build that does not declare that scheme yet. An
 * unguarded `startActivity` throws `ActivityNotFoundException` on the main
 * thread from inside `onCreate`, which is a fatal crash rather than a no-op.
 *
 * `checkActivities(true)` makes Robolectric enforce intent resolution the way a
 * real device does, so this reproduces the device failure rather than
 * simulating it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class NotificationOpenDeepLinkTest {
    private lateinit var application: Application
    private lateinit var launcher: ComponentName

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
        shadowOf(application).checkActivities(true)
        launcher = registerLauncherActivity()
        Notifie.initialize(application, "gk_test_android", "https://notifie.dev")
    }

    @Test
    fun openingAnUnhandledDeepLinkDoesNotCrashTheHostApp() {
        Robolectric.buildActivity(
            NotifieNotificationOpenActivity::class.java,
            openIntent("blackbox://orders/42"),
        ).create()
    }

    @Test
    fun openingAnUnhandledDeepLinkStillOpensTheApp() {
        val controller = Robolectric.buildActivity(
            NotifieNotificationOpenActivity::class.java,
            openIntent("blackbox://orders/42"),
        )

        controller.create()

        val fallback = startedActivities(controller.get()).lastOrNull()
        assertNotNull("the tap must not be silently lost", fallback)
        assertEquals(launcher.packageName, fallback!!.component?.packageName)
    }

    @Test
    fun openingAHandledDeepLinkUsesThatDeepLink() {
        val deepLink = "https://example.com/orders/42"
        registerActivity(
            ComponentName("com.example.browser", "com.example.browser.BrowserActivity"),
            IntentFilter(Intent.ACTION_VIEW).apply {
                addCategory(Intent.CATEGORY_DEFAULT)
                addDataScheme("https")
            },
        )

        val controller = Robolectric.buildActivity(
            NotifieNotificationOpenActivity::class.java,
            openIntent(deepLink),
        )

        controller.create()

        val started = startedActivities(controller.get())
        assertEquals(1, started.size)
        assertEquals(deepLink, started.first().data.toString())
    }

    /**
     * The payload is what makes the tap actionable. Without it the host is started
     * with a bare intent and cannot tell which notification produced it, which is
     * exactly what `Notifie.deepLink(...)` and `Notifie.notificationOpened(...)`
     * are documented to consume.
     */
    @Test
    fun theNotificationPayloadTravelsToADestinationInsideThisApp() {
        val deepLink = "myapp://orders/42"
        registerActivity(
            ComponentName(application.packageName, "dev.notifie.TestOrdersActivity"),
            IntentFilter(Intent.ACTION_VIEW).apply {
                addCategory(Intent.CATEGORY_DEFAULT)
                addDataScheme("myapp")
            },
        )

        val controller = Robolectric.buildActivity(
            NotifieNotificationOpenActivity::class.java,
            openIntent(deepLink).putExtra("orderId", "A-1183"),
        )

        controller.create()

        val started = startedActivities(controller.get()).first()
        assertEquals(deepLink, started.data.toString())
        assertEquals("A-1183", started.getStringExtra("orderId"))
        assertEquals(deepLink, started.getStringExtra(Notifie.deepLinkKey))
    }

    @Test
    fun thePayloadAlsoTravelsWhenTheTapFallsBackToTheLauncher() {
        val controller = Robolectric.buildActivity(
            NotifieNotificationOpenActivity::class.java,
            Intent(application, NotifieNotificationOpenActivity::class.java)
                .putExtra("orderId", "A-1183"),
        )

        controller.create()

        val started = startedActivities(controller.get()).first()
        assertEquals("A-1183", started.getStringExtra("orderId"))
    }

    /**
     * An https deep link legitimately resolves to a browser. Custom data belongs to
     * the host app, so handing it to whichever third-party app claims the scheme
     * would leak application data off the app entirely.
     */
    @Test
    fun thePayloadIsWithheldFromAnExternalApp() {
        val deepLink = "https://example.com/orders/42"
        registerActivity(
            ComponentName("com.example.browser", "com.example.browser.BrowserActivity"),
            IntentFilter(Intent.ACTION_VIEW).apply {
                addCategory(Intent.CATEGORY_DEFAULT)
                addDataScheme("https")
            },
        )

        val controller = Robolectric.buildActivity(
            NotifieNotificationOpenActivity::class.java,
            openIntent(deepLink).putExtra("orderId", "A-1183"),
        )

        controller.create()

        val started = startedActivities(controller.get()).first()
        assertEquals(deepLink, started.data.toString())
        assertEquals(null, started.getStringExtra("orderId"))
    }

    private fun openIntent(deepLink: String): Intent =
        Intent(application, NotifieNotificationOpenActivity::class.java)
            .putExtra(Notifie.deepLinkKey, deepLink)

    private fun registerLauncherActivity(): ComponentName {
        val component = ComponentName(application.packageName, "dev.notifie.TestLauncherActivity")
        registerActivity(
            component,
            IntentFilter(Intent.ACTION_MAIN).apply { addCategory(Intent.CATEGORY_LAUNCHER) },
        )
        return component
    }

    private fun registerActivity(component: ComponentName, filter: IntentFilter) {
        shadowOf(application.packageManager).addActivityIfNotPresent(component)
        shadowOf(application.packageManager).addIntentFilterForActivity(component, filter)
    }

    private fun startedActivities(activity: Activity): List<Intent> {
        val intents = mutableListOf<Intent>()
        while (true) {
            val next = shadowOf(activity).nextStartedActivity ?: break
            intents.add(next)
        }
        return intents
    }
}
