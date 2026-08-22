package dev.notifie

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Remote push needs a Firebase configuration, but an app without one must stay
 * usable instead of crashing.
 *
 * `FirebaseMessaging.getInstance()` throws synchronously when the host app has
 * no `google-services.json`, so the `addOnFailureListener` chain never observes
 * it. Uncaught, it propagates out of [Notifie.enableNotifications] — and out of
 * the runtime permission result callback — and takes the host app down.
 *
 * Robolectric registers no default `FirebaseApp`, so this suite reproduces that
 * exact environment rather than simulating it. With no local Firebase the SDK
 * now asks the server for a configuration before giving up, which makes the
 * result asynchronous; the guarantees under test are that it still arrives and
 * that a failed attempt does not poison the next one.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class NotifieRemotePushWithoutFirebaseTest {
    private lateinit var application: Application

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
        // Unroutable on purpose: the configuration lookup must fail so this
        // exercises the give-up path rather than depending on the network.
        Notifie.initialize(application, "gk_test_android", "http://127.0.0.1:1")
    }

    private fun enrolAndAwait(): List<NotificationEnrollment> {
        val results = mutableListOf<NotificationEnrollment>()
        val latch = CountDownLatch(1)

        Notifie.enableNotifications {
            synchronized(results) { results.add(it) }
            latch.countDown()
        }

        assertTrue("enrolment result must arrive", latch.await(20, TimeUnit.SECONDS))
        return synchronized(results) { results.toList() }
    }

    @Test
    fun enablingNotificationsWithoutFirebaseReportsTokenErrorInsteadOfCrashing() {
        assertEquals(listOf(NotificationEnrollment.TOKEN_ERROR), enrolAndAwait())
    }

    @Test
    fun enablingNotificationsWithoutFirebaseDoesNotStrandLaterAttempts() {
        assertEquals(listOf(NotificationEnrollment.TOKEN_ERROR), enrolAndAwait())
        assertEquals(listOf(NotificationEnrollment.TOKEN_ERROR), enrolAndAwait())
    }
}
