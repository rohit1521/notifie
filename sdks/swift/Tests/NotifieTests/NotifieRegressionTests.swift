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
}
