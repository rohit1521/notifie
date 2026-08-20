import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/**
 Notification enrolment.

 Notifie owns the permission request, APNs registration request, token
 persistence, and server registration. Apple still delivers the registration
 result only through `UIApplicationDelegate`, so the host forwards those two
 callbacks to the small facade below.
 */
public extension Notifie {

    /// Why enrolment ended the way it did. Deliberately explicit rather than a
    /// bare `Bool`: "the user said no" and "this is a simulator" need very
    /// different responses from the host app, and collapsing them hides bugs.
    enum NotificationEnrolment: Sendable, Equatable {
        /// Permission granted and a device token was registered.
        case enrolled
        /// The user declined. Asking again will not re-prompt on iOS.
        case denied
        /// Permission granted but APNs did not return a token — normally a
        /// simulator, or a missing Push Notifications capability.
        case noToken(String)
        /// `initialize()` was never called.
        case notInitialised
    }

    /**
     Requests notification permission and registers for push.

     Deliberately not called from `initialize()`. iOS only ever shows the
     permission prompt once, so *when* it appears is a product decision the app
     owns — asking at launch, before the user understands the value, is the
     single most common way to lose the permission permanently.

     - Parameter options: authorisation options; defaults to alert, badge, sound.
     */
    @discardableResult
    static func enableNotifications(
        options: UNAuthorizationOptions = [.alert, .badge, .sound]
    ) async -> NotificationEnrolment {
        await shared.performEnableNotifications(options: options)
    }

    /**
     Forwards Apple's successful APNs registration callback.

     Call from
     `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
     The facade deliberately hides `PushTokenBridge`, which is an implementation
     detail rather than a host-app API.
     */
    static func didRegisterForRemoteNotifications(deviceToken: Data) {
        PushTokenBridge.shared.didRegister(deviceToken: deviceToken)
    }

    /**
     Forwards Apple's failed APNs registration callback.

     Call from
     `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
     This resumes an outstanding `enableNotifications()` call immediately
     instead of making it wait for the ten-second no-token timeout.
     */
    static func didFailToRegisterForRemoteNotifications(error: Error) {
        PushTokenBridge.shared.didFail(error: error)
    }
}

extension Notifie {

    func performEnableNotifications(
        options: UNAuthorizationOptions
    ) async -> NotificationEnrolment {
        guard isInitialised else {
            logWarning("enableNotifications() called before initialize() — ignoring")
            return .notInitialised
        }

#if canImport(UserNotifications) && canImport(UIKit)
        let granted: Bool
        do {
            granted = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
        } catch {
            // A throw here is an OS-level failure, not a refusal. Recording it
            // as `denied` would wrongly suggest the user was asked and said no.
            logWarning("notification authorisation failed: \(error)")
            return .noToken("authorisation error")
        }

        // Recorded either way: knowing how many users decline is the whole
        // reason a push product needs the permission state as a property.
        recordPermission(granted ? "granted" : "denied")

        guard granted else { return .denied }

        let token = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            PushTokenBridge.shared.awaitToken { data in
                continuation.resume(returning: data)
            }

            Task { @MainActor in
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        guard let token else {
            // Overwhelmingly a simulator (which has no APNs) or a project
            // missing the Push Notifications capability. Saying so is far more
            // useful than a silent failure.
            return .noToken("APNs returned no token — check the Push Notifications capability, and note that simulators cannot receive push")
        }

        Notifie.registerPushToken(token)
        return .enrolled
#else
        return .noToken("push is only available on iOS")
#endif
    }

    /// Stored as a user property so audiences can target, and exclude, users
    /// who cannot actually receive anything.
    private func recordPermission(_ state: String) {
        performTrack(eventName: "notification_permission", properties: ["state": .string(state)])
    }
}

/**
 Bridges the APNs delegate callback into async/await.

 `registerForRemoteNotifications()` reports its result through an
 `AppDelegate` method, which the SDK cannot implement on the host app's behalf.
 The app forwards it here and enrolment completes.
 */
public final class PushTokenBridge: @unchecked Sendable {
    public static let shared = PushTokenBridge()

    private let lock = NSLock()
    private var waiters: [(Data?) -> Void] = []
    private var timeoutTask: Task<Void, Never>?

    /// APNs normally answers in well under a second; a hung wait would leave
    /// the caller's `await` outstanding forever. Nanoseconds rather than
    /// `Duration`, which needs macOS 13 and would raise the deployment target.
    private let timeoutNanoseconds: UInt64 = 10_000_000_000

    private init() {}

    func awaitToken(_ completion: @escaping (Data?) -> Void) {
        lock.withLock { waiters.append(completion) }

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.deliver(nil)
        }
    }

    /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func didRegister(deviceToken: Data) {
        deliver(deviceToken)
    }

    /// Call from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    public func didFail(error: Error) {
        deliver(nil)
    }

    private func deliver(_ token: Data?) {
        let pending: [(Data?) -> Void] = lock.withLock {
            let current = waiters
            waiters = []
            return current
        }

        timeoutTask?.cancel()
        timeoutTask = nil

        for completion in pending { completion(token) }
    }
}
