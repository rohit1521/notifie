import XCTest
@testable import Notifie

/**
 The SDK must be useful before the developer writes any tracking code.

 `first_open` and `app_open` need no domain knowledge, and on their own they
 unlock the retention templates — so `Notifie.initialize` alone produces
 recommendations. These tests hold that promise in place.
 */
final class LifecycleTrackingTests: XCTestCase {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gk_life_\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeConfig() -> NotifieConfiguration {
        NotifieConfiguration(
            apiKey: "gk_live_testkey1234_secretsecretsecret",
            baseURL: URL(string: "http://127.0.0.1:3000")!,
            batchSize: 1,
            flushInterval: 3600,
            maxQueueSize: 1000
        )
    }

    /// Shared defaults + file, so a second Notifie instance looks like a relaunch
    /// of the same install rather than a fresh device.
    private func makeStorage(suite: String, dir: URL) -> Storage {
        Storage(
            defaults: UserDefaults(suiteName: suite)!,
            queueFileURL: dir.appendingPathComponent("q.json")
        )
    }

    private func sentEventNames(_ transport: MockTransport) throws -> [String] {
        var names: [String] = []
        for call in transport.calls where call.request.url?.path == "/api/v1/events" {
            let body = try JSONSerialization.jsonObject(
                with: XCTUnwrap(call.request.httpBody)
            ) as! [String: Any]
            for event in (body["events"] as? [[String: Any]]) ?? [] {
                if let name = event["event"] as? String { names.append(name) }
            }
        }
        return names
    }

    func testInitializeAloneProducesEvents() async throws {
        let transport = MockTransport()
        let suite = "gk_life_\(UUID().uuidString)"

        let notifie = Notifie()
        notifie.setup(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(suite: suite, dir: tempDir())
        )

        try await Task.sleep(nanoseconds: 600_000_000)
        await notifie.flushForTesting()

        let names = try sentEventNames(transport)
        XCTAssertTrue(names.contains("first_open"), "a fresh install should record first_open")
        XCTAssertTrue(names.contains("app_open"), "every launch should record app_open")
    }

    func testFirstOpenIsSentOnlyOncePerInstall() async throws {
        let suite = "gk_life_\(UUID().uuidString)"
        let dir = tempDir()

        let first = MockTransport()
        let a = Notifie()
        a.setup(config: makeConfig(), transport: first, storage: makeStorage(suite: suite, dir: dir))
        try await Task.sleep(nanoseconds: 500_000_000)
        await a.flushForTesting()

        // Same suite and file: a relaunch, not a new device.
        let second = MockTransport()
        let b = Notifie()
        b.setup(config: makeConfig(), transport: second, storage: makeStorage(suite: suite, dir: dir))
        try await Task.sleep(nanoseconds: 500_000_000)
        await b.flushForTesting()

        XCTAssertTrue(try sentEventNames(first).contains("first_open"))
        XCTAssertFalse(
            try sentEventNames(second).contains("first_open"),
            "first_open must not repeat on relaunch, or install counts become meaningless"
        )
        XCTAssertTrue(try sentEventNames(second).contains("app_open"))
    }

    /// Domain events are the developer's to define. Guessing at them would
    /// produce data they did not write and cannot trust, so the allowlist is
    /// explicit: adding an auto-event should require a deliberate change here.
    func testNothingBeyondLifecycleIsInvented() async throws {
        let transport = MockTransport()
        let notifie = Notifie()
        notifie.setup(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(suite: "gk_life_\(UUID().uuidString)", dir: tempDir())
        )

        try await Task.sleep(nanoseconds: 600_000_000)
        await notifie.flushForTesting()

        let allowed: Set<String> = ["install", "first_open", "app_open", "session_start"]
        let unexpected = Set(try sentEventNames(transport)).subtracting(allowed)
        XCTAssertTrue(unexpected.isEmpty, "SDK invented events: \(unexpected)")
    }

    /// Platform, version, locale and timezone are all derivable without knowing
    /// anything about the app, and audiences need them to target.
    func testDeviceContextIsAttachedAutomatically() async throws {
        let transport = MockTransport()
        let notifie = Notifie()
        notifie.setup(
            config: makeConfig(),
            transport: transport,
            storage: makeStorage(suite: "gk_life_\(UUID().uuidString)", dir: tempDir())
        )

        try await Task.sleep(nanoseconds: 600_000_000)
        await notifie.flushForTesting()

        var contextProperties: [String: Any] = [:]
        for call in transport.calls where call.request.url?.path == "/api/v1/events" {
            let body = try JSONSerialization.jsonObject(
                with: XCTUnwrap(call.request.httpBody)
            ) as! [String: Any]
            for event in (body["events"] as? [[String: Any]]) ?? [] {
                if event["event"] as? String == "app_open",
                   let properties = event["properties"] as? [String: Any] {
                    contextProperties = properties
                }
            }
        }

        for key in ["platform", "app_version", "locale", "timezone", "os_version"] {
            XCTAssertNotNil(contextProperties[key], "missing \(key)")
        }
        XCTAssertEqual(contextProperties["platform"] as? String, "macos")
    }
}
