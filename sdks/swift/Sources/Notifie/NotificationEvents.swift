import Foundation
import CryptoKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/**
 Notification engagement reporting.

 These events are what make delivery and open rates real. A push product that
 cannot say whether anyone opened the notification is guessing, so the SDK
 reports engagement rather than asking the developer to instrument it.

 Each event carries `gk_invocation_id`, which the server put in the payload when
 it sent. That is what attributes an open back to a specific send rather than
 just "some notification".
 */
public extension Notifie {

    /// Compatibility hook for bridges that already own notification callbacks.
    /// Native apps are recorded automatically after `enableNotifications()`.
    static func notificationReceived(userInfo: [AnyHashable: Any]) {
        shared.recordNotificationEvent("notification_received", userInfo: userInfo)
    }

    /// Compatibility hook for bridges that already own notification callbacks.
    /// Native apps are recorded automatically after `enableNotifications()`.
    ///
    /// Reports both `notification_opened` and `notification_clicked`: a tap on
    /// the body opens the app, while a tap on an action button is a click on
    /// something specific, and reporting only one of the two would make either
    /// open rate or CTR unmeasurable.
    static func notificationOpened(response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        shared.recordNotificationEvent("notification_opened", userInfo: userInfo)

        if response.actionIdentifier != UNNotificationDefaultActionIdentifier {
            shared.recordNotificationEvent(
                "notification_clicked",
                userInfo: userInfo,
                extra: ["action": .string(response.actionIdentifier)]
            )
        }
    }

    /// Overload for bridges that cannot hand over a `UNNotificationResponse`.
    static func notificationOpened(userInfo: [AnyHashable: Any]) {
        shared.recordNotificationEvent("notification_opened", userInfo: userInfo)
    }

    /// The deep link Notifie attached to a notification, if any. The SDK does
    /// not navigate on the app's behalf — routing is the app's decision.
    static func deepLink(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["gk_deep_link"] as? String else { return nil }
        return URL(string: raw)
    }

    /// The remote image attached to a Notifie notification, if any.
    static func notificationImageURL(from userInfo: [AnyHashable: Any]) -> URL? {
        guard let raw = userInfo["gk_image_url"] as? String else { return nil }
        return URL(string: raw)
    }

#if canImport(UserNotifications)
    /**
     Downloads a rich-notification image into a temporary file suitable for a
     Notification Service Extension. Returns nil when no image exists or the
     download cannot be attached; the original notification should still show.
     */
    static func notificationAttachment(
        from userInfo: [AnyHashable: Any]
    ) async -> UNNotificationAttachment? {
        guard let remoteURL = notificationImageURL(from: userInfo) else { return nil }

        do {
            let (downloaded, _) = try await URLSession.shared.download(from: remoteURL)
            let ext = remoteURL.pathExtension.isEmpty ? "jpg" : remoteURL.pathExtension
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NotifieAttachments", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            removeStaleNotifieAttachments(in: directory)
            let localURL = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.moveItem(at: downloaded, to: localURL)
            return try UNNotificationAttachment(
                identifier: "notifie-image",
                url: localURL,
                options: nil
            )
        } catch {
            return nil
        }
    }
#endif
}

private func removeStaleNotifieAttachments(in directory: URL) {
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    for file in files {
        let modified = try? file.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        if modified.map({ $0 < cutoff }) ?? true {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

extension Notifie {

    func recordNotificationEvent(
        _ name: String,
        userInfo: [AnyHashable: Any],
        extra: Properties = [:]
    ) {
        var properties = extra

        // Present only on Notifie-sent notifications. Its absence means the
        // push came from somewhere else, which is worth being able to see.
        if let invocationId = userInfo["gk_invocation_id"] as? String {
            properties["invocation_id"] = .string(invocationId)
        }

        let messageId = (userInfo["gk_invocation_id"] as? String).map {
            deterministicNotificationEventId(invocationId: $0, event: name, extra: extra)
        }
        performTrack(eventName: name, properties: properties, messageId: messageId)
    }
}

func deterministicNotificationEventId(
    invocationId: String,
    event: String,
    extra: Properties
) -> String {
    let action: String
    if case .string(let value) = extra["action"] {
        action = value
    } else {
        action = ""
    }
    let digest = SHA256.hash(data: Data("\(invocationId):\(event):\(action)".utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return String(
        format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}
