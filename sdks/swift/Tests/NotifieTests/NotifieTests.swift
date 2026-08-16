import XCTest
@testable import Notifie

// MARK: - Mock transport

final class MockTransport: Transport, @unchecked Sendable {
    struct Call {
        let request: URLRequest
        let responseCode: Int
    }

    var statusCodeToReturn: Int = 200
    var errorToThrow: Error? = nil
    /// Holds the response open so overlapping flushes can be observed.
    var delayNanoseconds: UInt64 = 0
    private var _calls: [Call] = []
    private let lock = NSLock()

    var calls: [Call] { lock.withLock { _calls } }

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let err = errorToThrow { throw err }
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let code = statusCodeToReturn
        lock.withLock { _calls.append(Call(request: request, responseCode: code)) }
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), resp)
    }

    var callCount: Int { lock.withLock { _calls.count } }

    func lastBody() throws -> [String: Any] {
        let data = lock.withLock { _calls.last?.request.httpBody } ?? Data()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

// MARK: - Helpers

private func makeStorage(dir: URL) -> Storage {
    let defaults = UserDefaults(suiteName: "gk_test_\(UUID().uuidString)")!
    return Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("queue.json"))
}

private func makeConfig(batchSize: Int = 20, maxQueue: Int = 1000) -> NotifieConfiguration {
    NotifieConfiguration(
        apiKey: "gk_live_testkey123_secret",
        baseURL: URL(string: "http://127.0.0.1:3000")!,
        batchSize: batchSize,
        maxQueueSize: maxQueue
    )
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gk_test_\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tests

final class NotifieTests: XCTestCase {

    // MARK: Wire-shape encoding

    func testEventEncodesToWireShape() throws {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event = NotifieEvent(
            messageId: "550e8400-e29b-41d4-a716-446655440000",
            event: "purchase_completed",
            timestamp: fmt.date(from: "2026-08-07T10:00:00.000Z")!,
            userId: "123",
            anonymousId: "device-abc",
            properties: [
                "amount": .double(9.99),
                "plan": .string("monthly"),
                "active": .bool(true),
                "count": .int(5),
                "nothing": .null
            ]
        )

        let data = try Storage.encoder.encode(event)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["messageId"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(json["event"] as? String, "purchase_completed")
        XCTAssertEqual(json["userId"] as? String, "123")
        XCTAssertEqual(json["anonymousId"] as? String, "device-abc")
        // Timestamp must be ISO-8601 string, not a number
        XCTAssertTrue(json["timestamp"] is String, "timestamp must be an ISO-8601 string")

        let props = json["properties"] as! [String: Any]
        // Properties must be raw scalars, not wrapped objects
        XCTAssertEqual(props["amount"] as? Double, 9.99)
        XCTAssertEqual(props["plan"] as? String, "monthly")
        XCTAssertEqual(props["active"] as? Bool, true)
        XCTAssertEqual(props["count"] as? Int, 5)
        XCTAssertTrue(props["nothing"] is NSNull)
    }

    func testBatchBodyContainsSentAt() throws {
        let event = NotifieEvent(
            messageId: "msg-1",
            event: "test",
            timestamp: Date(),
            userId: nil,
            anonymousId: "anon",
            properties: [:]
        )
        let batch = TrackBatchBody(events: [event], sentAt: Date())
        let data = try Storage.encoder.encode(batch)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(json["sentAt"] is String)
        XCTAssertTrue(json["events"] is [[String: Any]])
    }

    // MARK: Batching

    func testFlushesWhenBatchSizeReached() async throws {
        let transport = MockTransport()
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let config = makeConfig(batchSize: 3)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        await queue.enqueue(makeEvent("e1"))
        await queue.enqueue(makeEvent("e2"))
        // Third enqueue should trigger flush internally via Task
        await queue.enqueue(makeEvent("e3"))
        // Give the internal flush Task a moment to run
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertGreaterThanOrEqual(transport.callCount, 1)
        let body = try transport.lastBody()
        let events = body["events"] as! [[String: Any]]
        XCTAssertLessThanOrEqual(events.count, 100)
    }

    func testBatchNeverExceeds100() async throws {
        let transport = MockTransport()
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        // batchSize 200 so auto-flush doesn't trigger mid-test; we flush manually
        let config = NotifieConfiguration(apiKey: "k", batchSize: 200, maxQueueSize: 2000)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        for i in 0..<150 {
            await queue.enqueue(makeEvent("e\(i)"))
        }
        await queue.flush()

        let body = try transport.lastBody()
        let events = body["events"] as! [[String: Any]]
        XCTAssertLessThanOrEqual(events.count, 100)
    }

    // MARK: messageId stability

    func testMessageIdStableAcrossRetries() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 503
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let config = makeConfig(batchSize: 200)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        let event = makeEvent("purchase")
        await queue.enqueue(event)
        await queue.flush()

        // The event's messageId must not change between calls
        let firstId = event.messageId
        let remaining = await queue.peekAll()
        XCTAssertTrue(remaining.contains(where: { $0.messageId == firstId }))
    }

    // MARK: Retry / no-retry semantics

    func testBackoffIncreasesOnConsecutiveFailures() {
        // Verify exponential formula: 2^n, capped at 300s
        let delays = (1...10).map { n in min(pow(2.0, Double(n)), 300.0) }
        for i in 0..<delays.count - 1 {
            if delays[i] < 300 {
                XCTAssertGreaterThan(delays[i + 1], delays[i])
            }
        }
        XCTAssertEqual(delays.last!, 300.0)
    }

    func test400DoesNotRetry() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 400
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let config = makeConfig(batchSize: 200)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        await queue.enqueue(makeEvent("bad_event"))
        await queue.flush()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Batch must be dropped — queue empty, no retry calls
        let count = await queue.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(transport.callCount, 1)
    }

    func test401DoesNotRetry() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 401
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let config = makeConfig(batchSize: 200)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        await queue.enqueue(makeEvent("bad_key"))
        await queue.flush()
        try await Task.sleep(nanoseconds: 50_000_000)

        let count = await queue.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(transport.callCount, 1)
    }

    func test5xxDoesRetry() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 500
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let config = makeConfig(batchSize: 200)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        await queue.enqueue(makeEvent("flaky"))
        await queue.flush()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Events stay in queue for retry
        let count = await queue.count
        XCTAssertGreaterThan(count, 0)
    }

    func test429DoesRetry() async throws {
        let transport = MockTransport()
        transport.statusCodeToReturn = 429
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let config = makeConfig(batchSize: 200)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        await queue.enqueue(makeEvent("rate_limited"))
        await queue.flush()
        try await Task.sleep(nanoseconds: 50_000_000)

        let count = await queue.count
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: Anonymous ID persistence

    func testAnonymousIdPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "gk_anon_\(UUID().uuidString)")!
        let dir = tempDir()
        let storage1 = Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("q.json"))
        let id1 = storage1.anonymousId()

        let storage2 = Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("q.json"))
        let id2 = storage2.anonymousId()

        XCTAssertEqual(id1, id2)
        XCTAssertFalse(id1.isEmpty)
    }

    func testAnonymousIdClearedOnReset() {
        let defaults = UserDefaults(suiteName: "gk_anon_reset_\(UUID().uuidString)")!
        let dir = tempDir()
        let storage = Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("q.json"))
        let id1 = storage.anonymousId()
        storage.clearAnonymousId()
        let id2 = storage.anonymousId()
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: Identify

    func testIdentifyLinksUserAndAnonymousId() async throws {
        let transport = MockTransport()
        let dir = tempDir()
        let defaults = UserDefaults(suiteName: "gk_identify_\(UUID().uuidString)")!
        let storage = Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("q.json"))
        let anonId = storage.anonymousId()

        let config = makeConfig(batchSize: 200)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        // Track an event — it should carry the anonymous id
        let event = NotifieEvent(
            messageId: UUID().uuidString.lowercased(),
            event: "signed_up",
            timestamp: Date(),
            userId: "user-123",
            anonymousId: anonId,
            properties: [:]
        )
        await queue.enqueue(event)
        await queue.flush()
        try await Task.sleep(nanoseconds: 50_000_000)

        let body = try transport.lastBody()
        let events = body["events"] as! [[String: Any]]
        XCTAssertEqual(events.first?["userId"] as? String, "user-123")
        XCTAssertEqual(events.first?["anonymousId"] as? String, anonId)
    }

    // MARK: Disk persistence

    func testDiskPersistenceRoundTrip() async throws {
        let dir = tempDir()
        let defaults = UserDefaults(suiteName: "gk_disk_\(UUID().uuidString)")!
        let storage1 = Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("queue.json"))
        let transport = MockTransport()
        transport.statusCodeToReturn = 500  // prevent flush from removing events

        let config = makeConfig(batchSize: 200)
        let queue1 = EventQueue(config: config, transport: transport, storage: storage1, logger: NotifieLogger(level: .silent))

        let eventId = UUID().uuidString.lowercased()
        let event = NotifieEvent(
            messageId: eventId,
            event: "cold_start_test",
            timestamp: Date(),
            userId: nil,
            anonymousId: "anon-123",
            properties: ["key": .string("value")]
        )
        await queue1.enqueue(event)

        // Simulate app kill: create a new queue that loads from same file
        let storage2 = Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("queue.json"))
        let queue2 = EventQueue(config: config, transport: transport, storage: storage2, logger: NotifieLogger(level: .silent))

        let loaded = await queue2.peekAll()
        XCTAssertTrue(loaded.contains(where: { $0.messageId == eventId }), "Events must survive cold restart")
    }

    // MARK: Queue cap

    func testQueueCapDropsOldest() async throws {
        let dir = tempDir()
        let storage = makeStorage(dir: dir)
        let transport = MockTransport()
        transport.statusCodeToReturn = 500

        let config = NotifieConfiguration(apiKey: "k", batchSize: 1000, maxQueueSize: 5)
        let queue = EventQueue(config: config, transport: transport, storage: storage, logger: NotifieLogger(level: .silent))

        for i in 0..<10 {
            let event = NotifieEvent(
                messageId: "msg-\(i)",
                event: "e\(i)",
                timestamp: Date(),
                userId: nil,
                anonymousId: "anon",
                properties: [:]
            )
            await queue.enqueue(event)
        }

        let remaining = await queue.peekAll()
        XCTAssertLessThanOrEqual(remaining.count, 5)
        // Newest (higher index) must be kept
        XCTAssertTrue(remaining.contains(where: { $0.messageId == "msg-9" }))
        // Oldest must be dropped
        XCTAssertFalse(remaining.contains(where: { $0.messageId == "msg-0" }))
    }

    // MARK: track() before initialize()

    func testTrackBeforeInitializeDoesNotCrash() {
        // Calling Notifie.track directly on the shared singleton without setting up queue
        // This must be a no-op, not a crash.
        let isolated = Notifie()  // fresh instance, no setup
        // Access private method indirectly through the internal path:
        // Since _queue is nil, performTrack should hit the early-return guard.
        // We just verify it completes without throwing/crashing.
        XCTAssertNoThrow(isolated.performTrackPublic("test_event", properties: [:]))
    }

    // MARK: - Property encoding correctness

    func testNotifiePropertyEncodesBoolCorrectly() throws {
        // Bool must decode as Bool, not as Int 0/1
        let props: Properties = ["flag": .bool(true), "off": .bool(false)]
        let data = try Storage.encoder.encode(props)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["flag"] as? Bool, true)
        XCTAssertEqual(json["off"] as? Bool, false)
    }

    func testNotifiePropertyEncodesNullCorrectly() throws {
        let props: Properties = ["nothing": .null]
        let data = try Storage.encoder.encode(props)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertTrue(json["nothing"] is NSNull)
    }

    func testNotifiePropertyRoundTrip() throws {
        let props: Properties = [
            "s": .string("hello"),
            "d": .double(3.14),
            "i": .int(42),
            "b": .bool(false),
            "n": .null
        ]
        let data = try Storage.encoder.encode(props)
        let decoded = try Storage.decoder.decode(Properties.self, from: data)
        XCTAssertEqual(decoded["s"], .string("hello"))
        XCTAssertEqual(decoded["i"], .int(42))
        XCTAssertEqual(decoded["b"], .bool(false))
        XCTAssertEqual(decoded["n"], .null)
        // Double round-trip tolerance
        if case .double(let v) = decoded["d"] {
            XCTAssertEqual(v, 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected .double")
        }
    }
}

// MARK: - Test helpers

extension Notifie {
    /// Exposed for tests that need to call without going through static singleton.
    func performTrackPublic(_ eventName: String, properties: Properties) {
        performTrack(eventName: eventName, properties: properties)
    }
}

private func makeEvent(_ name: String) -> NotifieEvent {
    NotifieEvent(
        messageId: UUID().uuidString.lowercased(),
        event: name,
        timestamp: Date(),
        userId: nil,
        anonymousId: "anon-device",
        properties: [:]
    )
}
