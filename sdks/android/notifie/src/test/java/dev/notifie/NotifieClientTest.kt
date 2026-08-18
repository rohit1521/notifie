package dev.notifie

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import org.json.JSONObject
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NotifieClientTest {
    private lateinit var application: Application
    private val clients = mutableListOf<NotifieClient>()

    @Before
    fun setUp() {
        application = RuntimeEnvironment.getApplication()
        application.getSharedPreferences("notifie", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @After
    fun tearDown() {
        clients.forEach(NotifieClient::close)
    }

    @Test
    fun offlineEventRetainsStableMessageIdAcrossRestart() {
        val offline = FakeTransport(default = HttpResult(503))
        val first = client(offline, batchSize = 1)

        first.track("purchase_completed", mapOf("amount" to 9.99))
        eventually { offline.calls.any { it.url.endsWith("/events") } }
        val firstMessageId = offline.eventMessageIds().single()
        assertEquals(1, first.pendingEventCount())
        first.close()

        val recovered = FakeTransport(default = HttpResult(200))
        val second = client(recovered, batchSize = 1)
        eventually { second.pendingEventCount() == 0 }

        assertEquals(firstMessageId, recovered.eventMessageIds().single())
    }

    @Test
    fun logoutRevocationSurvivesOfflineRestart() {
        val preferences = application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        preferences.edit().putString("push_token", "token-123").commit()
        val offline = FakeTransport(default = HttpResult(503))
        val first = client(offline)

        first.reset()
        eventually { offline.calls.any { it.method == "DELETE" } }
        assertEquals(listOf("token-123"), first.pendingRevocations())
        first.close()

        val recovered = FakeTransport(default = HttpResult(200))
        val second = client(recovered)
        eventually { second.pendingRevocations().isEmpty() }

        assertTrue(recovered.calls.any {
            it.method == "DELETE" && JSONObject(it.body).getString("token") == "token-123"
        })
    }

    @Test
    fun identifyReregistersTokenUnderTheKnownUser() {
        val transport = FakeTransport(default = HttpResult(200))
        val client = client(transport)
        client.awaitIdle()
        client.registerPushToken("token-abc")
        client.awaitIdle()
        assertEquals(1, transport.pushRegistrations().size)

        client.identify("user-42", mapOf("plan" to "pro"))
        client.awaitIdle()

        val body = transport.pushRegistrations().last {
            it.optString("userId") == "user-42"
        }
        assertEquals("user-42", body.getString("userId"))
        assertEquals("token-abc", body.getString("token"))
    }

    @Test
    fun resetThenIdentifyReregistersTheRevokedToken() {
        val transport = FakeTransport(default = HttpResult(200))
        val client = client(transport)
        client.awaitIdle()
        client.registerPushToken("token-login")
        client.awaitIdle()

        client.reset()
        client.awaitIdle()
        client.identify("user-after-login", mapOf("plan" to "pro"))
        client.awaitIdle()

        val body = transport.pushRegistrations().last {
            it.optString("userId") == "user-after-login"
        }
        assertEquals("user-after-login", body.getString("userId"))
        assertEquals("token-login", body.getString("token"))
        assertTrue(client.pendingRevocations().isEmpty())
    }

    @Test
    fun failedRevocationCompletesBeforeAReidentifiedTokenIsRegistered() {
        val transport = FakeTransport(
            results = ArrayDeque(
                listOf(
                    HttpResult(200),
                    HttpResult(503),
                    HttpResult(200),
                    HttpResult(200),
                    HttpResult(200),
                ),
            ),
            default = HttpResult(200),
        )
        val client = client(transport)
        client.awaitIdle()
        client.registerPushToken("token-retry")
        client.awaitIdle()

        client.reset()
        client.awaitIdle()
        assertEquals(listOf("token-retry"), client.pendingRevocations())
        client.identify("user-after-retry", emptyMap())
        client.awaitIdle()

        val tokenCalls = transport.pushTokenCalls()
        assertEquals(listOf("POST", "DELETE", "DELETE", "POST"), tokenCalls.map { it.method })
        assertTrue(client.pendingRevocations().isEmpty())
    }

    @Test
    fun newerIdentifySurvivesAnOlderInFlightRequest() {
        val transport = BlockingIdentifyTransport()
        val client = client(transport)
        client.awaitIdle()

        client.identify("first-user", emptyMap())
        assertTrue(transport.started.await(3, TimeUnit.SECONDS))
        client.identify("second-user", emptyMap())
        transport.release.countDown()
        client.awaitIdle()

        assertEquals(listOf("first-user", "second-user"), transport.userIds())
        assertEquals("second-user", client.currentUserId())
    }

    @Test
    fun concurrentAnonymousIdentityReadsReturnOneStableId() {
        val client = client(FakeTransport(default = HttpResult(200)))
        client.awaitIdle()
        val ready = CountDownLatch(16)
        val start = CountDownLatch(1)
        val ids = CopyOnWriteArrayList<String>()
        val threads = List(16) {
            Thread {
                ready.countDown()
                start.await()
                ids += client.anonymousId()
            }.also(Thread::start)
        }

        assertTrue(ready.await(3, TimeUnit.SECONDS))
        start.countDown()
        threads.forEach { it.join() }

        assertEquals(1, ids.distinct().size)
    }

    @Test
    fun permanentEventFailureDoesNotBlockLaterEvents() {
        val transport = FakeTransport(
            results = ArrayDeque(listOf(HttpResult(400), HttpResult(200))),
            default = HttpResult(200),
        )
        val client = client(transport, batchSize = 1)

        client.track("bad_payload")
        eventually { client.pendingEventCount() == 0 }
        client.track("valid_event")
        eventually { transport.calls.count { it.url.endsWith("/events") } >= 2 }

        assertEquals(0, client.pendingEventCount())
    }

    @Test
    fun completedFlushDoesNotDeleteAnEventQueuedAfterReset() {
        val transport = BlockingEventTransport()
        val client = client(transport, batchSize = 1)
        client.awaitIdle()

        client.track("before_reset")
        assertTrue(transport.started.await(3, TimeUnit.SECONDS))
        client.reset()
        client.track("after_reset")
        transport.release.countDown()
        client.awaitIdle()

        assertEquals(listOf("before_reset", "after_reset"), transport.eventNames())
        assertEquals(0, client.pendingEventCount())
    }

    @Test
    fun nestedPropertiesAreRejectedBeforeQueueing() {
        val client = client(FakeTransport(default = HttpResult(200)))

        val error = runCatching {
            client.track("invalid", mapOf("nested" to mapOf("value" to true)))
        }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertEquals(0, client.pendingEventCount())
    }

    @Test
    fun httpClassificationMatchesRetryContract() {
        assertTrue(HttpResult(429).retryable)
        assertTrue(HttpResult(503).retryable)
        assertTrue(HttpResult(401).permanent)
        assertTrue(HttpResult(404).permanent)
        assertFalse(HttpResult(401).retryable)
        assertTrue(HttpResult(200).delivered)
    }

    @Test
    fun notificationUsesSdkIconWhenHostAppHasNoIcon() {
        val applicationInfo = ApplicationInfo().apply {
            icon = 0
            metaData = Bundle()
        }

        assertEquals(
            R.drawable.notifie_notification,
            NotifieNotifications.resolveSmallIcon(applicationInfo),
        )
    }

    @Test
    fun notificationHonorsFirebaseDefaultIcon() {
        val configuredIcon = android.R.drawable.ic_dialog_info
        val applicationInfo = ApplicationInfo().apply {
            icon = android.R.drawable.ic_menu_info_details
            metaData = Bundle().apply {
                putInt("com.google.firebase.messaging.default_notification_icon", configuredIcon)
            }
        }

        assertEquals(configuredIcon, NotifieNotifications.resolveSmallIcon(applicationInfo))
    }

    @Test
    fun foregroundNotificationPostsThroughNotificationManager() {
        val manager = application.getSystemService(NotificationManager::class.java)
        manager.cancelAll()

        NotifieNotifications.show(
            context = application,
            title = "Notifie test",
            body = "Foreground delivery",
            imageUrl = null,
            data = mapOf("gk_invocation_id" to "foreground-test"),
        )

        assertEquals(1, shadowOf(manager).allNotifications.size)
    }

    @Test
    fun notificationOpenBeforeInitializationIsPersistedAndDeduplicated() {
        val data = mapOf("gk_invocation_id" to "cold-open-1")

        Notifie.recordNotificationOpen(application, data)
        Notifie.recordNotificationOpen(
            application,
            mapOf("gk_invocation_id" to "cold-open-2"),
        )
        Notifie.recordNotificationOpen(application, data)

        val pending = JSONArray(
            application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
                .getString("pending_notification_opens", "[]"),
        )
        assertEquals(2, pending.length())
        assertEquals("cold-open-1", pending.getJSONObject(0).getString("invocationId"))
        assertEquals("cold-open-2", pending.getJSONObject(1).getString("invocationId"))
    }

    @Test
    fun notificationReceiptBeforeInitializationIsPersistedAndDeduplicated() {
        val data = mapOf("gk_invocation_id" to "cold-receipt-1")

        Notifie.recordNotificationReceived(application, data)
        Notifie.recordNotificationReceived(
            application,
            mapOf("gk_invocation_id" to "cold-receipt-2"),
        )
        Notifie.recordNotificationReceived(application, data)

        val pending = JSONArray(
            application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
                .getString("pending_notification_receipts", "[]"),
        )
        assertEquals(2, pending.length())
        assertEquals("cold-receipt-1", pending.getJSONObject(0).getString("invocationId"))
        assertEquals("cold-receipt-2", pending.getJSONObject(1).getString("invocationId"))
    }

    @Test
    fun backgroundMessageBeforeHandlerIsPersistedAndDeduplicated() {
        val data = mapOf(
            "gk_invocation_id" to "cold-background-1",
            "sync" to "inventory",
        )

        Notifie.recordBackgroundMessage(application, data)
        Notifie.recordBackgroundMessage(
            application,
            mapOf(
                "gk_invocation_id" to "cold-background-2",
                "sync" to "profile",
            ),
        )
        Notifie.recordBackgroundMessage(application, data)

        val pending = JSONArray(
            application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
                .getString("pending_background_messages", "[]"),
        )
        assertEquals(2, pending.length())
        assertEquals(
            "inventory",
            pending.getJSONObject(0).getJSONObject("data").getString("sync"),
        )
        assertEquals(
            "profile",
            pending.getJSONObject(1).getJSONObject("data").getString("sync"),
        )
    }

    @Test
    fun onlyMarkedFirebaseMessagesBelongToNotifie() {
        assertFalse(Notifie.isNotifieMessage(mapOf("source" to "host-app")))
        assertFalse(Notifie.isNotifieMessage(mapOf("gk_invocation_id" to "")))
        assertTrue(Notifie.isNotifieMessage(mapOf("gk_invocation_id" to "inv-1")))
    }

    @Test
    fun contextTokenForwardingPersistsBeforeInitialization() {
        Notifie.registerPushToken(application, "token-before-init")

        assertEquals(
            "token-before-init",
            application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
                .getString("push_token", null),
        )
    }

    @Test
    fun aDelayedRevocationNeverDeletesTheTokenTheDeviceIsUsing() {
        // FCM hands back the same token after a logout, so re-registering it
        // while a DELETE is still queued used to revoke the live registration.
        val transport = RevocationTransport(pendingDeleteStatuses = listOf(503))
        val preferences = application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        preferences.edit().putString("push_token", "fcm-token-T").commit()
        val client = client(transport)
        client.awaitIdle()

        client.reset()
        client.awaitIdle()
        assertEquals(listOf("fcm-token-T"), client.pendingRevocations())

        client.registerPushToken("fcm-token-T")
        client.awaitIdle()

        val forToken = transport.pushTokenCalls()
            .filter { JSONObject(it.body).optString("token") == "fcm-token-T" }
        assertEquals(
            "the live token must end registered, not revoked",
            "POST",
            forToken.last().method,
        )
        assertTrue(client.pendingRevocations().isEmpty())
    }

    @Test
    fun aTokenTheServerNoLongerKnowsSettlesTheRevocation() {
        // 404 and 410 mean the token is already gone, which is the state the
        // revocation wanted. Retrying them stalled every later registration.
        for (status in listOf(404, 410)) {
            application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
                .edit().clear().commit()

            val transport = RevocationTransport(pendingDeleteStatuses = listOf(status))
            val client = client(transport)
            client.awaitIdle()
            client.registerPushToken("gone-$status")
            client.awaitIdle()

            client.reset()
            client.awaitIdle()
            assertTrue(
                "HTTP $status must settle the revocation",
                client.pendingRevocations().isEmpty(),
            )

            client.registerPushToken("replacement-$status")
            client.awaitIdle()
            assertTrue(
                "registration must not stall behind a settled revocation",
                transport.pushTokenCalls().any {
                    it.method == "POST" &&
                        JSONObject(it.body).optString("token") == "replacement-$status"
                },
            )
        }
    }

    @Test
    fun anUnevaluatedRevocationIsKeptRatherThanDiscarded() {
        // A rotated key answers 401. Discarding on it would leave a signed-out
        // user's device subscribed to their own notifications.
        val preferences = application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        preferences.edit().putString("push_token", "still-live").commit()
        val transport = RevocationTransport(pendingDeleteStatuses = listOf(401))
        val client = client(transport)
        client.awaitIdle()

        client.reset()
        client.awaitIdle()

        assertEquals(listOf("still-live"), client.pendingRevocations())
    }

    @Test
    fun anUnacceptableRevocationIsDiscardedRatherThanRetriedForever() {
        val preferences = application.getSharedPreferences("notifie", Context.MODE_PRIVATE)
        preferences.edit().putString("push_token", "malformed").commit()
        val transport = RevocationTransport(pendingDeleteStatuses = listOf(400))
        val client = client(transport)
        client.awaitIdle()

        client.reset()
        client.awaitIdle()

        assertTrue(client.pendingRevocations().isEmpty())
    }

    private fun client(
        transport: NotifieTransport,
        batchSize: Int = 20,
    ): NotifieClient {
        return NotifieClient(
            context = application,
            apiKey = "gk_test_android",
            baseUrl = "https://notifie.dev",
            batchSize = batchSize,
            flushIntervalSeconds = 3600,
            transport = transport,
        ).also(clients::add)
    }

    private fun eventually(timeoutMillis: Long = 3000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!condition() && System.currentTimeMillis() < deadline) {
            Thread.sleep(10)
        }
        assertTrue("Condition was not met within ${timeoutMillis}ms", condition())
    }
}

private data class TransportCall(
    val method: String,
    val url: String,
    val body: String,
)

private class FakeTransport(
    private val results: ArrayDeque<HttpResult> = ArrayDeque(),
    private val default: HttpResult,
) : NotifieTransport {
    val calls = CopyOnWriteArrayList<TransportCall>()

    override fun send(method: String, url: String, apiKey: String, body: String): HttpResult {
        calls += TransportCall(method, url, body)
        return synchronized(results) {
            if (results.isEmpty()) default else results.removeFirst()
        }
    }

    fun eventMessageIds(): List<String> = calls
        .filter { it.url.endsWith("/events") }
        .map { JSONObject(it.body).getJSONArray("events").getJSONObject(0).getString("messageId") }

    fun pushRegistrations(): List<JSONObject> = synchronized(calls) {
        calls
            .filter { it.method == "POST" && it.url.endsWith("/push-tokens") }
            .map { JSONObject(it.body) }
    }

    fun pushTokenCalls(): List<TransportCall> = synchronized(calls) {
        calls.filter { it.url.endsWith("/push-tokens") }
    }
}

/**
 * Answers DELETE from a scripted list and everything else with 200.
 *
 * Routing on the method rather than on call order keeps a revocation test
 * independent of how many registrations or flushes happen around it.
 */
private class RevocationTransport(
    pendingDeleteStatuses: List<Int> = emptyList(),
    private val settledDeleteStatus: Int = 200,
) : NotifieTransport {
    val calls = CopyOnWriteArrayList<TransportCall>()
    private val scripted = ArrayDeque(pendingDeleteStatuses)

    override fun send(method: String, url: String, apiKey: String, body: String): HttpResult {
        calls += TransportCall(method, url, body)
        if (method != "DELETE") return HttpResult(200)
        val status = synchronized(scripted) {
            if (scripted.isEmpty()) settledDeleteStatus else scripted.removeFirst()
        }
        return HttpResult(status)
    }

    fun pushTokenCalls(): List<TransportCall> = synchronized(calls) {
        calls.filter { it.url.endsWith("/push-tokens") }
    }
}

private class BlockingEventTransport : NotifieTransport {
    val started = CountDownLatch(1)
    val release = CountDownLatch(1)
    private val calls = CopyOnWriteArrayList<TransportCall>()

    override fun send(method: String, url: String, apiKey: String, body: String): HttpResult {
        calls += TransportCall(method, url, body)
        if (url.endsWith("/events") && calls.count { it.url.endsWith("/events") } == 1) {
            started.countDown()
            release.await(3, TimeUnit.SECONDS)
        }

        return HttpResult(200)
    }

    fun eventNames(): List<String> = calls
        .filter { it.url.endsWith("/events") }
        .flatMap { call ->
            val events = JSONObject(call.body).getJSONArray("events")
            List(events.length()) { index -> events.getJSONObject(index).getString("event") }
        }
}

private class BlockingIdentifyTransport : NotifieTransport {
    val started = CountDownLatch(1)
    val release = CountDownLatch(1)
    private val calls = CopyOnWriteArrayList<TransportCall>()

    override fun send(method: String, url: String, apiKey: String, body: String): HttpResult {
        calls += TransportCall(method, url, body)
        if (url.endsWith("/identify") && calls.count { it.url.endsWith("/identify") } == 1) {
            started.countDown()
            release.await(3, TimeUnit.SECONDS)
        }
        return HttpResult(200)
    }

    fun userIds(): List<String> = calls
        .filter { it.url.endsWith("/identify") }
        .map { JSONObject(it.body).getString("userId") }
}