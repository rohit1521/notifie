import XCTest
@testable import Notifie

// MARK: - Helpers (private to this file; parallel private copies exist in NotifieTests.swift)

private func pushTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gk_push_test_\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func pushMakeStorage(dir: URL) -> Storage {
    let defaults = UserDefaults(suiteName: "gk_push_test_\(UUID().uuidString)")!
    return Storage(defaults: defaults, queueFileURL: dir.appendingPathComponent("queue.json"))
}

private func pushMakeConfig() -> NotifieConfiguration {
    NotifieConfiguration(
        apiKey: "gk_live_pushtest_secret",
        baseURL: URL(string: "http://127.0.0.1:3000")!,
        batchSize: 20,
        maxQueueSize: 1000
    )
}

// MARK: - Tests

final class PushTokenTests: XCTestCase {

    // MARK: - Hex conversion

    func testHexConversionLeadingZeroBytes() {
        // 0x00 must produce "00", not "0"; 0x0f must produce "0f".
        let data = Data([0x00, 0x0f, 0xff, 0xab])
        let hex = data.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "000fffab")
    }

    func testHexConversionFullAPNsToken() {
        // Typical APNs token is 32 bytes → exactly 64 lowercase hex chars.
        let data = Data(repeating: 0x5a, count: 32)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex.count, 64)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(hex, String(repeating: "5a", count: 32))
    }

    func testHexOutputIsLowercase() {
        let data = Data([0xAB, 0xCD, 0xEF])
        let hex = data.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "abcdef")
    }

    // MARK: - Token persists across "restarts"

    func testTokenPersistenceViaStorage() {
        let dir = pushTempDir()
        let storage = pushMakeStorage(dir: dir)

        storage.savePushToken("deadbeef001122", platform: "ios", provider: "apns")

        XCTAssertEqual(storage.pushToken(), "deadbeef001122")
        XCTAssertEqual(storage.pushPlatform(), "ios")
        XCTAssertEqual(storage.pushProvider(), "apns")
    }

    func testTokenOverwrittenOnSecondSave() {
        let dir = pushTempDir()
        let storage = pushMakeStorage(dir: dir)

        storage.savePushToken("firsttoken", platform: "ios", provider: "apns")
        storage.savePushToken("secondtoken", platform: "android", provider: "fcm")

        XCTAssertEqual(storage.pushToken(), "secondtoken")
        XCTAssertEqual(storage.pushPlatform(), "android")
        XCTAssertEqual(storage.pushProvider(), "fcm")
    }

    func testClearPushToken() {
        let dir = pushTempDir()
        let storage = pushMakeStorage(dir: dir)

        storage.savePushToken("cafebabe", platform: "ios", provider: "apns")
        storage.clearPushToken()

        XCTAssertNil(storage.pushToken())
        XCTAssertNil(storage.pushPlatform())
        XCTAssertNil(storage.pushProvider())
    }

    func testPendingRevocationPersistsAndDeduplicates() {
        let dir = pushTempDir()
        let storage = pushMakeStorage(dir: dir)

        storage.enqueuePushTokenRevocation("cafebabe")
        storage.enqueuePushTokenRevocation("cafebabe")

        XCTAssertEqual(storage.pendingPushTokenRevocations(), ["cafebabe"])
        storage.completePushTokenRevocation("cafebabe")
        XCTAssertEqual(storage.pendingPushTokenRevocations(), [])
    }

    func testConcurrentRevocationUpdatesDoNotLoseTokens() {
        let dir = pushTempDir()
        let storage = pushMakeStorage(dir: dir)

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            storage.enqueuePushTokenRevocation("token-\(index)")
        }

        XCTAssertEqual(Set(storage.pendingPushTokenRevocations()).count, 100)
    }

    func testResetDeactivatesTokenBeforeForgettingIt() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        let storage = pushMakeStorage(dir: dir)
        let g = Notifie()
        g.setup(config: pushMakeConfig(), transport: transport, storage: storage)
        storage.savePushToken("logout-token", platform: "ios", provider: "apns")

        g.resetForTesting()
        try await Task.sleep(nanoseconds: 200_000_000)

        let revocation = transport.calls.first {
            $0.request.httpMethod == "DELETE" &&
                $0.request.url?.absoluteString.contains("push-tokens") == true
        }
        XCTAssertNotNil(revocation)
        XCTAssertNil(storage.pushToken())
        XCTAssertEqual(storage.pendingPushTokenRevocations(), [])
        if let body = revocation?.request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(json["token"] as? String, "logout-token")
        }
    }

    func testFailedResetRevocationReplaysOnNextSetup() async throws {
        let dir = pushTempDir()
        let storage = pushMakeStorage(dir: dir)
        storage.savePushToken("offline-token", platform: "ios", provider: "apns")
        let failingTransport = MockTransport()
        failingTransport.errorToThrow = URLError(.notConnectedToInternet)
        let first = Notifie()
        first.setup(config: pushMakeConfig(), transport: failingTransport, storage: storage)

        first.resetForTesting()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(storage.pendingPushTokenRevocations(), ["offline-token"])

        let recoveredTransport = MockTransport()
        let second = Notifie()
        second.setup(config: pushMakeConfig(), transport: recoveredTransport, storage: storage)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(storage.pendingPushTokenRevocations(), [])
        XCTAssertTrue(recoveredTransport.calls.contains {
            $0.request.httpMethod == "DELETE" &&
                $0.request.url?.absoluteString.contains("push-tokens") == true
        })
    }

    func testResetDoesNotDeleteEventsTrackedDuringRevocation() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        transport.delayNanoseconds = 150_000_000
        let storage = pushMakeStorage(dir: dir)
        let notifie = Notifie()
        notifie.setup(config: pushMakeConfig(), transport: transport, storage: storage)
        storage.savePushToken("logout-token", platform: "ios", provider: "apns")

        notifie.resetForTesting()
        notifie.performTrack(eventName: "next_user_event", properties: [:])
        try await Task.sleep(nanoseconds: 400_000_000)
        await notifie.flushForTesting()

        let eventNames = transport.calls.compactMap { call -> [String]? in
            guard call.request.url?.path.hasSuffix("/events") == true,
                  let body = call.request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let events = json["events"] as? [[String: Any]] else { return nil }
            return events.compactMap { $0["event"] as? String }
        }.flatMap { $0 }
        XCTAssertTrue(eventNames.contains("next_user_event"))
    }

    func testResetRevocationFinishesBeforeSameTokenRegistersAgain() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        transport.delayNanoseconds = 100_000_000
        let storage = pushMakeStorage(dir: dir)
        let notifie = Notifie()
        notifie.setup(config: pushMakeConfig(), transport: transport, storage: storage)
        storage.savePushToken("reused-token", platform: "ios", provider: "apns")

        notifie.resetForTesting()
        notifie.performRegisterPushToken("reused-token", platform: "ios", provider: "apns")
        try await Task.sleep(nanoseconds: 500_000_000)

        let methods = transport.calls.compactMap { call in
            call.request.url?.path.hasSuffix("/push-tokens") == true
                ? call.request.httpMethod
                : nil
        }
        XCTAssertEqual(Array(methods.suffix(2)), ["DELETE", "POST"])
        XCTAssertEqual(storage.pendingPushTokenRevocations(), [])
    }

    func testRegistrationReplaysAfterTransientRevocationFailure() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        let storage = pushMakeStorage(dir: dir)
        let notifie = Notifie()
        notifie.setup(config: pushMakeConfig(), transport: transport, storage: storage)
        storage.savePushToken("retry-token", platform: "ios", provider: "apns")
        transport.statusCodeToReturn = 500

        notifie.resetForTesting()
        notifie.performRegisterPushToken("retry-token", platform: "ios", provider: "apns")
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(storage.pendingPushTokenRevocations(), ["retry-token"])
        XCTAssertNotNil(storage.pendingPushTokenRegistration())

        transport.statusCodeToReturn = 200
        await notifie.flushPushLifecycleForTesting()

        let methods = transport.calls.compactMap { call in
            call.request.url?.path.hasSuffix("/push-tokens") == true
                ? call.request.httpMethod
                : nil
        }
        XCTAssertEqual(Array(methods.suffix(2)), ["DELETE", "POST"])
        XCTAssertEqual(storage.pendingPushTokenRevocations(), [])
        XCTAssertNil(storage.pendingPushTokenRegistration())
    }

    func testRevocationQueuedDuringDeleteRunsBeforeRegistration() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        transport.delayNanoseconds = 150_000_000
        let storage = pushMakeStorage(dir: dir)
        storage.enqueuePushTokenRevocation("older-token")
        let registration = PushTokenBody(
            userId: nil,
            anonymousId: "next-anonymous-id",
            token: "next-token",
            platform: "ios",
            provider: "apns"
        )
        storage.savePendingPushTokenRegistration(registration)
        let queue = EventQueue(
            config: pushMakeConfig(),
            transport: transport,
            storage: storage,
            logger: NotifieLogger(level: .silent)
        )

        let firstPass = Task { await queue.flushPushTokenLifecycle() }
        try await Task.sleep(nanoseconds: 30_000_000)
        storage.enqueuePushTokenRevocation("next-token")
        let firstResult = await firstPass.value
        XCTAssertFalse(firstResult)
        XCTAssertFalse(transport.calls.contains {
            $0.request.httpMethod == "POST"
                && $0.request.url?.path.hasSuffix("/push-tokens") == true
        })

        transport.delayNanoseconds = 0
        let secondResult = await queue.flushPushTokenLifecycle()
        XCTAssertTrue(secondResult)
        let methods = transport.calls.compactMap { call in
            call.request.url?.path.hasSuffix("/push-tokens") == true
                ? call.request.httpMethod
                : nil
        }
        XCTAssertEqual(methods, ["DELETE", "DELETE", "POST"])
    }

    func testInvalidTokenDoesNotPoisonLifecycleQueue() {
        let dir = pushTempDir()
        let transport = MockTransport()
        let storage = pushMakeStorage(dir: dir)
        let notifie = Notifie()
        notifie.setup(config: pushMakeConfig(), transport: transport, storage: storage)

        notifie.performRegisterPushToken("", platform: "ios", provider: "apns")
        notifie.performRegisterPushToken(
            String(repeating: "x", count: 513),
            platform: "ios",
            provider: "apns"
        )

        XCTAssertNil(storage.pushToken())
        XCTAssertNil(storage.pendingPushTokenRegistration())
    }

    func testCancelledIdentifyCannotRegisterTokenForLoggedOutUser() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        transport.delayNanoseconds = 150_000_000
        let storage = pushMakeStorage(dir: dir)
        let notifie = Notifie()
        notifie.setup(config: pushMakeConfig(), transport: transport, storage: storage)
        storage.savePushToken("identity-token", platform: "ios", provider: "apns")

        notifie.performIdentify(userId: "logged-out-user", properties: [:])
        try await Task.sleep(nanoseconds: 30_000_000)
        notifie.resetForTesting()
        notifie.performRegisterPushToken("identity-token", platform: "ios", provider: "apns")
        try await Task.sleep(nanoseconds: 700_000_000)

        let registeredUserIds = transport.calls.compactMap { call -> String? in
            guard call.request.httpMethod == "POST",
                  call.request.url?.path.hasSuffix("/push-tokens") == true,
                  let body = call.request.httpBody,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["userId"] as? String
        }
        XCTAssertFalse(registeredUserIds.contains("logged-out-user"))
    }

    // MARK: - Re-registration on identify

    func testTokenSentToServerOnRegistration() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        let config = pushMakeConfig()
        let storage = pushMakeStorage(dir: dir)

        let g = Notifie()
        g.setup(config: config, transport: transport, storage: storage)

        // Register a token — should fire a push-tokens request.
        g.performRegisterPushToken("aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
                                   platform: "ios",
                                   provider: "apns")

        // Give the fire-and-forget Task time to run.
        try await Task.sleep(nanoseconds: 200_000_000)

        let pushCalls = transport.calls.filter {
            $0.request.url?.absoluteString.contains("push-tokens") == true
        }
        XCTAssertFalse(pushCalls.isEmpty, "Expected at least one push-tokens request")

        if let body = pushCalls.first?.request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(json["platform"] as? String, "ios")
            XCTAssertEqual(json["provider"] as? String, "apns")
        }
    }

    func testTokenResentWithUserIdOnIdentify() async throws {
        let dir = pushTempDir()
        let transport = MockTransport()
        let config = pushMakeConfig()
        let storage = pushMakeStorage(dir: dir)

        let g = Notifie()
        g.setup(config: config, transport: transport, storage: storage)

        // Register token while anonymous.
        g.performRegisterPushToken("aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233",
                                   platform: "ios",
                                   provider: "apns")

        let countBeforeIdentify = transport.callCount

        // Now identify — the stored token should be re-sent with the new userId.
        g.performIdentify(userId: "user-xyz-123", properties: [:])

        // Wait for the identify task chain to complete (same pattern as regression tests).
        // The mock transport is instant, so 400ms is a very conservative bound.
        try await Task.sleep(nanoseconds: 400_000_000)

        let newCalls = transport.calls.dropFirst(countBeforeIdentify)
        let pushCalls = newCalls.filter {
            $0.request.url?.absoluteString.contains("push-tokens") == true
        }
        XCTAssertFalse(pushCalls.isEmpty,
                       "Expected a push-token re-registration after identify")

        if let body = pushCalls.last?.request.httpBody,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(json["userId"] as? String, "user-xyz-123",
                           "Re-sent token should carry the new userId")
            XCTAssertEqual(json["token"] as? String,
                           "aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233")
        }
    }

    // MARK: - No crash before initialize()

    func testRegisterPushTokenBeforeInitializeDoesNotCrash() {
        // Fresh isolated instance (not Notifie.shared) so no initialize() has run.
        let g = Notifie()
        g.performRegisterPushToken("sometoken", platform: "ios", provider: "apns")
        // Reaching here means no crash occurred.
    }

    func testRegisterPushTokenDataBeforeInitializeDoesNotCrash() {
        // Public static path — routes to Notifie.shared.performRegisterPushToken.
        // shared may or may not be initialised depending on test ordering;
        // either state must not crash.
        let data = Data([0x01, 0x02, 0x03])
        Notifie.registerPushToken(data)
    }

    func testNotificationImageURLExtraction() {
        let url = Notifie.notificationImageURL(from: [
            "gk_image_url": "https://cdn.example.com/notification.png"
        ])
        XCTAssertEqual(url?.absoluteString, "https://cdn.example.com/notification.png")
        XCTAssertNil(Notifie.notificationImageURL(from: [:]))
    }
}
