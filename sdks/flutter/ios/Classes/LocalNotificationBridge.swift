import Flutter
import Foundation
import Notifie
import UserNotifications

/**
 Translates method-channel arguments into the native SDK's API.

 Deliberately a translator and nothing more. Trigger construction, the pending
 limit and identifier namespacing all live in the Notifie SDK this delegates to;
 reimplementing any of it here would create a second engine to diverge from the
 first, and the divergence would be silent.
 */
enum LocalNotificationBridge {

    static func schedule(_ arguments: [String: Any]) async -> [String: Any] {
        let notification: LocalNotification
        do {
            notification = try decode(arguments)
        } catch let error as DecodeError {
            return ["error": "invalid_request", "message": error.reason]
        } catch {
            return ["error": "invalid_request", "message": String(describing: error)]
        }

        switch await Notifie.schedule(notification) {
        case .success:
            // iOS has no separately granted precision: a scheduled request is
            // as exact as the platform offers.
            return ["precision": "exact"]
        case .failure(let error):
            return failure(for: error)
        }
    }

    static func cancel(_ arguments: [String: Any]) {
        guard let id = arguments["id"] as? String else { return }
        Notifie.cancelScheduled(id: id)
    }

    static func pending() async -> [[String: Any]] {
        await Notifie.pendingScheduled().map { entry in
            var result: [String: Any] = ["id": entry.id]
            if let next = entry.nextTriggerDate {
                result["nextTrigger"] = Int(next.timeIntervalSince1970 * 1000)
            }
            return result
        }
    }

    static func capabilities() async -> [String: Any] {
        [
            "permission": await permissionState(),
            // iOS does not gate scheduling precision behind a permission the
            // way Android does, so this is always available.
            "canScheduleExactAlarms": true,
            "supportedSchedules": ["at", "after", "daily", "weekly"],
            // iOS keeps only the 64 soonest pending notifications.
            "pendingCapacity": LocalNotificationLimits.maxPending,
        ]
    }

    static func requestPermission() async -> String {
        let centre = UNUserNotificationCenter.current()
        do {
            _ = try await centre.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return "denied"
        }
        return await permissionState()
    }

    private static func permissionState() async -> String {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .ephemeral: return "granted"
        case .provisional: return "provisional"
        case .denied: return "denied"
        default: return "notDetermined"
        }
    }

    private static func failure(for error: LocalScheduleError) -> [String: Any] {
        switch error {
        case .permissionDenied: return ["error": "permission_denied"]
        case .scheduleInPast: return ["error": "schedule_in_past"]
        case .capacityExceeded: return ["error": "capacity_exceeded"]
        case .invalidRequest(let reason):
            return ["error": "invalid_request", "message": reason]
        case .platformError(let reason):
            return ["error": "platform_error", "message": reason]
        }
    }

    // MARK: - Decoding

    struct DecodeError: Error {
        let reason: String
    }

    static func decode(_ arguments: [String: Any]) throws -> LocalNotification {
        guard let id = arguments["id"] as? String else {
            throw DecodeError(reason: "id is required")
        }
        guard let title = arguments["title"] as? String else {
            throw DecodeError(reason: "title is required")
        }
        guard let body = arguments["body"] as? String else {
            throw DecodeError(reason: "body is required")
        }
        guard let scheduleArguments = arguments["schedule"] as? [String: Any] else {
            throw DecodeError(reason: "schedule is required")
        }

        let customData = (arguments["customData"] as? [String: Any] ?? [:])
            .reduce(into: [String: String]()) { output, entry in
                output[entry.key] = String(describing: entry.value)
            }

        return LocalNotification(
            id: id,
            title: title,
            body: body,
            schedule: try decodeSchedule(scheduleArguments),
            deepLink: arguments["deepLink"] as? String,
            customData: customData,
            ios: decodeIosOptions(arguments["ios"] as? [String: Any])
        )
    }

    private static func decodeSchedule(_ arguments: [String: Any]) throws -> LocalSchedule {
        switch arguments["type"] as? String {
        case "at":
            guard let raw = arguments["timestamp"] as? String else {
                throw DecodeError(reason: "timestamp is required")
            }
            // Parsed with its explicit offset. A bare local timestamp would be
            // reinterpreted in the device's timezone.
            guard let date = iso8601.date(from: raw) ?? iso8601NoFraction.date(from: raw) else {
                throw DecodeError(reason: "timestamp must be ISO-8601 with an offset")
            }
            return .at(date)
        case "after":
            guard let seconds = arguments["seconds"] as? NSNumber else {
                throw DecodeError(reason: "seconds is required")
            }
            return .after(seconds: seconds.doubleValue)
        case "daily":
            return .daily(
                hour: try requireInt(arguments, "hour"),
                minute: try requireInt(arguments, "minute")
            )
        case "weekly":
            return .weekly(
                weekday: try requireInt(arguments, "weekday"),
                hour: try requireInt(arguments, "hour"),
                minute: try requireInt(arguments, "minute")
            )
        default:
            throw DecodeError(reason: "unknown schedule type")
        }
    }

    private static func decodeIosOptions(
        _ arguments: [String: Any]?
    ) -> LocalNotificationIOSOptions? {
        guard let arguments else { return nil }
        var sound: LocalNotificationSound?
        if let named = arguments["sound"] as? String {
            sound = .named(named)
        } else if let enabled = arguments["sound"] as? Bool {
            sound = enabled ? .default : .silent
        }
        return LocalNotificationIOSOptions(
            threadId: arguments["threadId"] as? String,
            categoryId: arguments["categoryId"] as? String,
            badge: (arguments["badge"] as? NSNumber)?.intValue,
            sound: sound
        )
    }

    private static func requireInt(_ arguments: [String: Any], _ key: String) throws -> Int {
        guard let value = arguments[key] as? NSNumber else {
            throw DecodeError(reason: "\(key) is required")
        }
        return value.intValue
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601NoFraction = ISO8601DateFormatter()
}
