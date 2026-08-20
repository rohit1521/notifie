import XCTest
@testable import Notifie
#if canImport(UIKit) && canImport(UserNotifications)
import ObjectiveC
import UIKit
import UserNotifications
#endif

final class NotificationEventTests: XCTestCase {
    func testNotificationEventMessageIdIsStableAndValid() {
        let first = deterministicNotificationEventId(
            invocationId: "invocation-42",
            event: "notification_opened",
            extra: [:]
        )
        let second = deterministicNotificationEventId(
            invocationId: "invocation-42",
            event: "notification_opened",
            extra: [:]
        )

        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    func testNotificationEventMessageIdDistinguishesEventAndAction() {
        let opened = deterministicNotificationEventId(
            invocationId: "invocation-42",
            event: "notification_opened",
            extra: [:]
        )
        let received = deterministicNotificationEventId(
            invocationId: "invocation-42",
            event: "notification_received",
            extra: [:]
        )
        let action = deterministicNotificationEventId(
            invocationId: "invocation-42",
            event: "notification_clicked",
            extra: ["action": .string("accept")]
        )

        XCTAssertNotEqual(opened, received)
        XCTAssertNotEqual(opened, action)
    }
}

#if canImport(UIKit) && canImport(UserNotifications)
@MainActor
final class AutomaticPushDelegateTests: XCTestCase {
    func testAutomaticApplicationDelegateInterceptsAndForwardsToken() async {
        PushTokenBridge.shared.resetForTesting()
        let delegate = RegistrationDelegate()
        let expected = Data([0x01, 0x02, 0x03])

        AutomaticPushDelegates.installApplicationDelegateForTesting(delegate)
        let token = await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            PushTokenBridge.shared.awaitToken { continuation.resume(returning: $0) }
            let selector = #selector(UIApplicationDelegate.application(
                _:didRegisterForRemoteNotificationsWithDeviceToken:
            ))
            let method = class_getInstanceMethod(RegistrationDelegate.self, selector)!
            typealias Implementation = @convention(c) (
                AnyObject,
                Selector,
                UIApplication,
                Data
            ) -> Void
            unsafeBitCast(method_getImplementation(method), to: Implementation.self)(
                delegate,
                selector,
                UIApplication.shared,
                expected
            )
        }

        XCTAssertEqual(token, expected)
        XCTAssertEqual(delegate.forwardedToken, expected)
    }

}

private final class RegistrationDelegate: NSObject, UIApplicationDelegate {
    var forwardedToken: Data?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        forwardedToken = deviceToken
    }
}

#endif
