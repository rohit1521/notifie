package dev.notifie

import android.app.Application
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

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
 * exact environment rather than simulating it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class NotifieRemotePushWithoutFirebaseTest {
    private lateinit var application: Application

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
        Notifie.initialize(application, "gk_test_android", "https://notifie.dev")
    }

    @Test
    fun enablingNotificationsWithoutFirebaseReportsTokenErrorInsteadOfCrashing() {
        val results = mutableListOf<NotificationEnrollment>()

        Notifie.enableNotifications { results.add(it) }

        assertEquals(listOf(NotificationEnrollment.TOKEN_ERROR), results)
    }

    @Test
    fun enablingNotificationsWithoutFirebaseDoesNotStrandLaterAttempts() {
        val first = mutableListOf<NotificationEnrollment>()
        val second = mutableListOf<NotificationEnrollment>()

        Notifie.enableNotifications { first.add(it) }
        Notifie.enableNotifications { second.add(it) }

        assertEquals(listOf(NotificationEnrollment.TOKEN_ERROR), first)
        assertEquals(listOf(NotificationEnrollment.TOKEN_ERROR), second)
    }
}
