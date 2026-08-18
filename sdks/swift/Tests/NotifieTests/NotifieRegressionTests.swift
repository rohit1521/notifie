import XCTest
@testable import Notifie

/// Regression tests for defects found in review.
///
/// Each case here previously failed: identify bypassed the injected transport,
/// properties set before any identify produced an empty userId, and concurrent
/// flushes could deliver the same batch twice.
final class NotifieRegressionTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gk_reg_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStorage() -> Storage {
        let defaults = UserDefaults(suiteName: "gk_reg_\(UUID().uuidString)")!
        return Storage(defaults: defaults, queueFileURL: tempDir().appendingPathComponent("q.json"))
    }

    private func makeConfig(batchSize: Int = 20) -> NotifieConfiguration {
        NotifieConfiguration(
            apiKey: "gk_live_testkey1234_secretsecretsecret",
            baseURL: URL(string: "http://127.0.0.1:3000")!,
            batchSize: batchSize,
            flushInterval: 3600,
            maxQueueSize: 1000
        )
    }

    private func requests(_ transport: MockTransport) -> [URLRequest] {
        transport.calls.map(\.request)
    }

    // MARK: - identify must use the injected transport

    func testIdentifyGoesThroughInjectedTransport() async throws {
        let transport = MockTransport()
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(),
            logger: NotifieLogger(level: .silent)
        )

        await queue.sendIdentify(
            IdentifyBody(
                userId: "user-1",
                anonymousId: "device-1",
                properties: ["premium": .bool(true)],
                timestamp: Date()
            )
        )

        XCTAssertEqual(transport.callCount, 1, "identify must not bypass the injected transport")

        let request = try XCTUnwrap(requests(transport).last)
        XCTAssertEqual(request.url?.path, "/api/v1/identify")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer gk_live_testkey1234_secretsecretsecret"
        )

        let body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(request.httpBody)
        ) as! [String: Any]
        XCTAssertEqual(body["userId"] as? String, "user-1")
        XCTAssertEqual(body["anonymousId"] as? String, "device-1")
        XCTAssertEqual((body["properties"] as? [String: Any])?["premium"] as? Bool, true)
    }

    // MARK: - properties before identify

    func testSetUserPropertyBeforeIdentifyDoesNotSendEmptyUserId() async throws {
        let transport = MockTransport()
        let notifie = Notifie()
        notifie.setup(config: makeConfig(), transport: transport, storage: makeStorage())

        notifie.performSetUserProperty("premium", value: .bool(true))  // internal seam
        try await Task.sleep(nanoseconds: 250_000_000)

        // An empty userId would be rejected by the server with a 400.
        for request in requests(transport) where request.url?.path == "/api/v1/identify" {
            let body = try JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)
            ) as! [String: Any]
            XCTAssertNotEqual(body["userId"] as? String, "", "must never send an empty userId")
        }
    }

    func testBufferedPropertyIsFlushedOnFirstIdentify() async throws {
        let transport = MockTransport()
        let notifie = Notifie()
        notifie.setup(config: makeConfig(), transport: transport, storage: makeStorage())

        notifie.performSetUserProperty("premium", value: .bool(true))  // internal seam
        notifie.performIdentify(userId: "user-42", properties: ["plan": .string("monthly")])
        try await Task.sleep(nanoseconds: 400_000_000)

        let identifyRequest = try XCTUnwrap(
            requests(transport).last { $0.url?.path == "/api/v1/identify" },
            "identify should have been sent"
        )
        let body = try JSONSerialization.jsonObject(
            with: XCTUnwrap(identifyRequest.httpBody)
        ) as! [String: Any]
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])

        XCTAssertEqual(body["userId"] as? String, "user-42")
        XCTAssertEqual(properties["premium"] as? Bool, true, "property set while anonymous is kept")
        XCTAssertEqual(properties["plan"] as? String, "monthly")
    }

    // MARK: - Concurrency

    func testConcurrentFlushesDoNotDoubleSend() async throws {
        let transport = MockTransport()
        transport.delayNanoseconds = 120_000_000

        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(),
            logger: NotifieLogger(level: .silent)
        )

        for index in 0..<5 {
            await queue.enqueue(
                NotifieEvent(
                    messageId: UUID().uuidString.lowercased(),
                    event: "app_open",
                    timestamp: Date(),
                    userId: "u",
                    anonymousId: "a",
                    properties: ["i": .int(index)]
                )
            )
        }

        // Three racing flushes; the in-flight guard should collapse them to one.
        async let first: Void = queue.flush()
        async let second: Void = queue.flush()
        async let third: Void = queue.flush()
        _ = await (first, second, third)

        XCTAssertEqual(transport.callCount, 1, "overlapping flushes must not resend a batch")
        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)
    }

    func testBacklogDrainsInASinglePass() async throws {
        let transport = MockTransport()
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(),
            logger: NotifieLogger(level: .silent)
        )

        // 250 queued events exceed the 100-per-batch server cap.
        for index in 0..<250 {
            await queue.enqueue(
                NotifieEvent(
                    messageId: UUID().uuidString.lowercased(),
                    event: "app_open",
                    timestamp: Date(),
                    userId: "u",
                    anonymousId: "a",
                    properties: ["i": .int(index)]
                )
            )
        }

        await queue.flush()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 0, "an offline backlog should clear without waiting for the timer")

        var deliveredIds: [String] = []
        for request in requests(transport) {
            let body = try JSONSerialization.jsonObject(
                with: XCTUnwrap(request.httpBody)
            ) as! [String: Any]
            let events = try XCTUnwrap(body["events"] as? [[String: Any]])
            XCTAssertLessThanOrEqual(events.count, 100, "a batch must never exceed the server cap")
            deliveredIds.append(contentsOf: events.compactMap { $0["messageId"] as? String })
        }

        XCTAssertEqual(Set(deliveredIds).count, 250, "every event should be delivered exactly once")
        XCTAssertEqual(deliveredIds.count, 250, "no event should be sent twice")
    }

    // MARK: - Ordering

    /// Regression: two rapid identify calls were independent fire-and-forget
    /// tasks, so the server could apply the older property value last.
    func testRapidIdentifyCallsPreserveOrder() async throws {
        let transport = MockTransport()
        transport.delayNanoseconds = 40_000_000

        let notifie = Notifie()
        notifie.setup(config: makeConfig(), transport: transport, storage: makeStorage())

        notifie.performIdentify(userId: "user-1", properties: ["premium": .bool(false)])
        notifie.performIdentify(userId: "user-1", properties: ["premium": .bool(true)])
        notifie.performIdentify(userId: "user-1", properties: ["premium": .bool(false)])
        notifie.performIdentify(userId: "user-1", properties: ["premium": .bool(true)])

        try await Task.sleep(nanoseconds: 1_500_000_000)

        let sent = try requests(transport)
            .filter { $0.url?.path == "/api/v1/identify" }
            .map { request -> Bool? in
                let body = try JSONSerialization.jsonObject(
                    with: XCTUnwrap(request.httpBody)
                ) as! [String: Any]
                return (body["properties"] as? [String: Any])?["premium"] as? Bool
            }

        XCTAssertEqual(sent.count, 4, "every identify should be delivered")
        XCTAssertEqual(
            sent,
            [false, true, false, true],
            "identify deliveries must preserve call order, otherwise last-write-wins applies the wrong value"
        )
    }

    // MARK: - Retry gating

    func testRetryableFailureLeavesEventsQueuedAndGatesFlush() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 503

        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(),
            logger: NotifieLogger(level: .silent)
        )

        await queue.enqueue(
            NotifieEvent(
                messageId: UUID().uuidString.lowercased(),
                event: "app_open",
                timestamp: Date(),
                userId: "u",
                anonymousId: "a",
                properties: [:]
            )
        )

        await queue.flush()
        let afterFirst = await queue.count
        XCTAssertEqual(afterFirst, 1, "a 5xx must not discard events")

        // Backoff is active, so an immediate flush must be a no-op rather than
        // hammering a server that is already failing.
        await queue.flush()
        XCTAssertEqual(transport.callCount, 1, "backoff should suppress an immediate retry")

        let retries = await queue.currentRetryCount
        XCTAssertEqual(retries, 1)
    }

    func testPermanentRejectionDoesNotBlockLaterEvents() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 400

        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(),
            logger: NotifieLogger(level: .silent)
        )

        await queue.enqueue(
            NotifieEvent(
                messageId: UUID().uuidString.lowercased(),
                event: "app_open",
                timestamp: Date(),
                userId: "u",
                anonymousId: "a",
                properties: [:]
            )
        )

        await queue.flush()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 0, "an unfixable batch must be dropped, not retried forever")
    }

    // MARK: - A revocation the server rejects must not strand push forever

    /// Logout enqueues a revocation. When the server answered anything other
    /// than 2xx/400/413 — a 404 for an already-deleted token being the common
    /// case — the revocation was kept and retried forever, and because the
    /// lifecycle runs revocations before registrations the device could never
    /// register for push again.
    func testPermanentRevocationFailureDoesNotBlockPushRegistration() async {
        let storage = makeStorage()
        storage.enqueuePushTokenRevocation("already-deleted-token")
        storage.savePendingPushTokenRegistration(
            PushTokenBody(
                userId: "user-1",
                anonymousId: "anon-1",
                token: "fresh-token",
                platform: "ios",
                provider: "apns"
            )
        )

        let transport = RoutingTransport { route in
            route == "DELETE /api/v1/push-tokens" ? 404 : 200
        }
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        _ = await queue.flushPushTokenLifecycle()

        XCTAssertTrue(
            transport.calls.contains("POST /api/v1/push-tokens"),
            "a revocation the server will never accept must not block registration"
        )
        XCTAssertTrue(
            storage.pendingPushTokenRevocations().isEmpty,
            "an unacceptable revocation must be discarded rather than retried forever"
        )
        XCTAssertNil(storage.pendingPushTokenRegistration())
    }

    /// The opposite guarantee, which the fix must not trade away: a *transient*
    /// failure still defers registration, so a token is never re-registered
    /// while its revocation is outstanding.
    func testRetryableRevocationFailureStillDefersRegistration() async {
        let storage = makeStorage()
        storage.enqueuePushTokenRevocation("live-token")
        storage.savePendingPushTokenRegistration(
            PushTokenBody(
                userId: "user-1",
                anonymousId: "anon-1",
                token: "fresh-token",
                platform: "ios",
                provider: "apns"
            )
        )

        let transport = RoutingTransport { route in
            route == "DELETE /api/v1/push-tokens" ? 503 : 200
        }
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        _ = await queue.flushPushTokenLifecycle()

        XCTAssertFalse(
            transport.calls.contains("POST /api/v1/push-tokens"),
            "a transient revocation failure must still be resolved before re-registering"
        )
        XCTAssertEqual(storage.pendingPushTokenRevocations(), ["live-token"])
    }

    /// Confirmed against the live API: a rotated key answers a revocation with
    /// 401. That is the server declining to look at the request, not confirming
    /// the token is gone, so discarding it would leave a signed-out user's
    /// device subscribed to their own notifications.
    func testAuthFailureDoesNotDiscardARevocation() async {
        let storage = makeStorage()
        storage.enqueuePushTokenRevocation("signed-out-token")

        let transport = RoutingTransport { _ in 401 }
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        _ = await queue.flushPushTokenLifecycle()

        XCTAssertEqual(
            storage.pendingPushTokenRevocations(),
            ["signed-out-token"],
            "an unevaluated revocation must be kept, or a signed-out user stays subscribed"
        )
    }

    /// Also confirmed live: an empty token is a 400. The server will never
    /// accept it, so it must be dropped rather than retried forever.
    func testUnusableRevocationIsDiscardedRatherThanRetriedForever() async {
        let storage = makeStorage()
        storage.enqueuePushTokenRevocation("malformed-token")

        let transport = RoutingTransport { _ in 400 }
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        _ = await queue.flushPushTokenLifecycle()

        XCTAssertTrue(storage.pendingPushTokenRevocations().isEmpty)
    }

    // MARK: - identify must survive being made offline

    /// identify was a single fire-and-forget attempt, so calling it without a
    /// network lost the identity and its properties permanently.
    func testIdentifyIsReplayedAfterAnOfflineFailure() async {
        let storage = makeStorage()
        let offline = RoutingTransport { _ in 503 }
        let queue = EventQueue(
            config: makeConfig(),
            transport: offline,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )
        let body = IdentifyBody(
            userId: "user-1",
            anonymousId: "anon-1",
            properties: ["plan": .string("pro")],
            timestamp: Date()
        )

        await queue.sendIdentify(body)
        XCTAssertNotNil(
            storage.pendingIdentify(),
            "an identify that could not be delivered must be retained for replay"
        )

        let online = RoutingTransport { _ in 200 }
        let recovered = EventQueue(
            config: makeConfig(),
            transport: online,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )
        await recovered.flushPendingIdentify()

        XCTAssertTrue(online.calls.contains("POST /api/v1/identify"))
        XCTAssertNil(
            storage.pendingIdentify(),
            "a delivered identify must not be replayed again"
        )
    }

    /// Replay must stop when the server has actually rejected the payload,
    /// otherwise the same rejection repeats on every flush forever.
    func testPermanentlyRejectedIdentifyIsNotReplayed() async {
        let storage = makeStorage()
        let transport = RoutingTransport { _ in 400 }
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        await queue.sendIdentify(
            IdentifyBody(
                userId: "user-1",
                anonymousId: "anon-1",
                properties: [:],
                timestamp: Date()
            )
        )

        XCTAssertNil(storage.pendingIdentify())
    }

    func testResetDoesNotLeaveThePreviousUsersIdentifyToReplay() async throws {
        let storage = makeStorage()
        let transport = RoutingTransport { _ in 503 }
        let notifie = Notifie()
        notifie.setup(config: makeConfig(), transport: transport, storage: storage)

        notifie.performIdentify(userId: "user-1", properties: ["plan": .string("pro")])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(
            storage.pendingIdentify(),
            "precondition: the identify failed and was retained"
        )

        notifie.resetForTesting()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertNil(
            storage.pendingIdentify(),
            "logout must not leave the previous user's identify to be replayed"
        )
    }

    // MARK: - Transient status codes must not be treated as fatal

    /// 408 and 425 fell into the "unexpected" branch and were dropped as
    /// permanent, discarding events the server SDK would have retried.
    func testRequestTimeoutIsRetriedRatherThanDropped() async {
        let storage = makeStorage()
        let transport = RoutingTransport { _ in 408 }
        let queue = EventQueue(
            config: makeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        await queue.enqueue(
            NotifieEvent(
                messageId: UUID().uuidString.lowercased(),
                event: "app_open",
                timestamp: Date(),
                userId: "u",
                anonymousId: "a",
                properties: [:]
            )
        )
        await queue.flush()

        let remaining = await queue.count
        XCTAssertEqual(remaining, 1, "408 means ask again, so the batch must be kept")
    }
}

/// Answers per route, which the shared `MockTransport` cannot do: these cases
/// turn on one endpoint failing while another succeeds.
private final class RoutingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private let responder: @Sendable (String) -> Int

    init(responder: @escaping @Sendable (String) -> Int) {
        self.responder = responder
    }

    var calls: [String] { lock.withLock { _calls } }

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let route = "\(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
        lock.withLock { _calls.append(route) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: responder(route),
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}
