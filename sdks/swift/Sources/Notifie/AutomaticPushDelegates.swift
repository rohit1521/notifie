#if canImport(ObjectiveC) && canImport(UIKit) && canImport(UserNotifications)
import Foundation
import ObjectiveC
import UIKit
import UserNotifications

enum AutomaticPushDelegates {
    private static let lock = NSLock()
    private static var installedMethods = Set<String>()
    private static var notificationCenterSetterInstalled = false
    private static let notificationDelegateProxy = NotificationDelegateProxy()

    @MainActor
    static func install() {
        installApplicationDelegate(UIApplication.shared.delegate)
        installNotificationCenterDelegateObservation()

        let center = UNUserNotificationCenter.current()
        if let delegate = center.delegate,
           delegate !== notificationDelegateProxy {
            notificationDelegateProxy.setHost(delegate)
        }
        center.delegate = notificationDelegateProxy
    }

    @MainActor
    static func installApplicationDelegateForTesting(_ delegate: UIApplicationDelegate) {
        installApplicationDelegate(delegate)
    }

    private static func installApplicationDelegate(_ delegate: UIApplicationDelegate?) {
        guard let delegate, let delegateClass = object_getClass(delegate) else { return }

        installMethod(
            on: delegateClass,
            selector: #selector(UIApplicationDelegate.application(
                _:didRegisterForRemoteNotificationsWithDeviceToken:
            )),
            protocol: UIApplicationDelegate.self
        ) { original in
            let block: @convention(block) (AnyObject, UIApplication, Data) -> Void = {
                object, application, token in
                PushTokenBridge.shared.didRegister(deviceToken: token)
                Notifie.registerPushToken(token)
                if let original {
                    typealias Implementation = @convention(c) (
                        AnyObject,
                        Selector,
                        UIApplication,
                        Data
                    ) -> Void
                    unsafeBitCast(original, to: Implementation.self)(
                        object,
                        #selector(UIApplicationDelegate.application(
                            _:didRegisterForRemoteNotificationsWithDeviceToken:
                        )),
                        application,
                        token
                    )
                }
            }
            return imp_implementationWithBlock(block)
        }

        installMethod(
            on: delegateClass,
            selector: #selector(UIApplicationDelegate.application(
                _:didFailToRegisterForRemoteNotificationsWithError:
            )),
            protocol: UIApplicationDelegate.self
        ) { original in
            let block: @convention(block) (AnyObject, UIApplication, NSError) -> Void = {
                object, application, error in
                PushTokenBridge.shared.didFail(error: error)
                if let original {
                    typealias Implementation = @convention(c) (
                        AnyObject,
                        Selector,
                        UIApplication,
                        NSError
                    ) -> Void
                    unsafeBitCast(original, to: Implementation.self)(
                        object,
                        #selector(UIApplicationDelegate.application(
                            _:didFailToRegisterForRemoteNotificationsWithError:
                        )),
                        application,
                        error
                    )
                }
            }
            return imp_implementationWithBlock(block)
        }
    }

    private static func installNotificationCenterDelegateObservation() {
        let shouldInstall = lock.withLock { () -> Bool in
            guard !notificationCenterSetterInstalled else { return false }
            notificationCenterSetterInstalled = true
            return true
        }
        guard shouldInstall,
              let method = class_getInstanceMethod(
                  UNUserNotificationCenter.self,
                  #selector(setter: UNUserNotificationCenter.delegate)
              ) else { return }

        let selector = #selector(setter: UNUserNotificationCenter.delegate)
        let original = method_getImplementation(method)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { object, delegate in
            let assigned: AnyObject?
            if delegate === notificationDelegateProxy {
                assigned = delegate
            } else {
                notificationDelegateProxy.setHost(delegate)
                assigned = notificationDelegateProxy
            }
            typealias Implementation = @convention(c) (
                AnyObject,
                Selector,
                AnyObject?
            ) -> Void
            unsafeBitCast(original, to: Implementation.self)(object, selector, assigned)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func installMethod(
        on targetClass: AnyClass,
        selector: Selector,
        protocol delegateProtocol: Protocol,
        replacement: (IMP?) -> IMP
    ) {
        let key = "\(ObjectIdentifier(targetClass)):\(NSStringFromSelector(selector))"
        let shouldInstall = lock.withLock { installedMethods.insert(key).inserted }
        guard shouldInstall else { return }

        let inherited = class_getInstanceMethod(targetClass, selector)
        let original = inherited.map(method_getImplementation)
        let description = protocol_getMethodDescription(
            delegateProtocol,
            selector,
            false,
            true
        )
        let protocolTypes = description.types.map { UnsafePointer($0) }
        let types = inherited.flatMap(method_getTypeEncoding) ?? protocolTypes
        guard let types else { return }

        let implementation = replacement(original)
        if !class_addMethod(targetClass, selector, implementation, types) {
            class_replaceMethod(targetClass, selector, implementation, types)
        }
    }
}

private final class NotificationDelegateProxy:
    NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private weak var host: AnyObject?

    func setHost(_ delegate: AnyObject?) {
        lock.withLock { host = delegate }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        let isNotifie = userInfo["gk_invocation_id"] is String
        if isNotifie {
            Notifie.notificationReceived(userInfo: userInfo)
        }

        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(
            _:willPresent:withCompletionHandler:
        ))
        guard let host = lock.withLock({ self.host }),
              host.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(host), selector) else {
            completion(isNotifie ? [.banner, .sound] : [])
            return
        }

        typealias Completion = @convention(block) (
            UNNotificationPresentationOptions
        ) -> Void
        typealias Implementation = @convention(c) (
            AnyObject,
            Selector,
            UNUserNotificationCenter,
            UNNotification,
            Completion
        ) -> Void
        let block: Completion = { completion($0) }
        unsafeBitCast(method_getImplementation(method), to: Implementation.self)(
            host,
            selector,
            center,
            notification,
            block
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        if response.notification.request.content.userInfo["gk_invocation_id"] is String {
            Notifie.notificationOpened(response: response)
        }

        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(
            _:didReceive:withCompletionHandler:
        ))
        guard let host = lock.withLock({ self.host }),
              host.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(host), selector) else {
            completion()
            return
        }

        typealias Completion = @convention(block) () -> Void
        typealias Implementation = @convention(c) (
            AnyObject,
            Selector,
            UNUserNotificationCenter,
            UNNotificationResponse,
            Completion
        ) -> Void
        let block: Completion = { completion() }
        unsafeBitCast(method_getImplementation(method), to: Implementation.self)(
            host,
            selector,
            center,
            response,
            block
        )
    }
}
#endif
