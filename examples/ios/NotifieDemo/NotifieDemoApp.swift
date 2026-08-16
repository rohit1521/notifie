import SwiftUI
import UIKit
import UserNotifications
import Notifie

@main
struct NotifieDemoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(state: appDelegate.state)
                .onOpenURL { url in appDelegate.state.handle(url: url) }
        }
    }
}

/**
 The only Notifie integration code a host app has to write.

 Two APNs callbacks are forwarded to `PushTokenBridge`, and foreground/opened
 notifications are reported so open rates are attributable. Everything else —
 token upload, retries, batching, session events — is the SDK's problem.
 */
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let state = DemoState()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        state.initializeIfConfigured()
        state.runLocalNotificationCheckIfRequested()
        return true
    }

    // MARK: - APNs registration

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushTokenBridge.shared.didRegister(deviceToken: deviceToken)
        state.log("APNs returned a device token (\(deviceToken.count) bytes)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushTokenBridge.shared.didFail(error: error)
        state.log("APNs registration failed: \(error.localizedDescription)")
    }

    // MARK: - Receiving notifications

    /// Without this, a notification arriving while the app is open is silently
    /// swallowed by iOS, which makes testing look like a delivery failure.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Notifie.notificationReceived(userInfo: notification.request.content.userInfo)
        state.log("Notification received in foreground: \(notification.request.content.title)")
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Notifie.notificationOpened(response: response)
        state.log("Notification opened: \(response.notification.request.content.title)")

        if let link = Notifie.deepLink(from: response.notification.request.content.userInfo) {
            state.log("Deep link: \(link.absoluteString)")
        }
        completionHandler()
    }
}
