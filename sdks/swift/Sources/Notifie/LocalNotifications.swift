import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/**
 Local notifications.

 These are scheduled and presented by the operating system on this device. They
 need no API key, no network and no Notifie account — `Notifie.schedule` works
 in an application that has never called `initialize()`.

 That independence is deliberate. A reminder app should not need a backend, and
 a developer should be able to prove the SDK works before trusting it with
 anything.
 */

// MARK: - Model

/// When a local notification fires.
public enum LocalSchedule: Sendable, Equatable {
    /// Fires once at an absolute instant, regardless of later timezone changes.
    case at(Date)

    /// Fires once after an interval measured from scheduling.
    case after(seconds: TimeInterval)

    /// Fires every day at a wall-clock time.
    ///
    /// Wall clock rather than a 24-hour interval: a 9am reminder stays at 9am
    /// across a daylight-saving change instead of drifting an hour and staying
    /// there.
    case daily(hour: Int, minute: Int)

    /// Fires every week at a wall-clock time. Monday is 1 and Sunday is 7,
    /// matching ISO-8601 rather than Foundation's Sunday-first numbering.
    case weekly(weekday: Int, hour: Int, minute: Int)
}

/// iOS-specific presentation options, isolated from the portable fields.
public struct LocalNotificationIOSOptions: Sendable, Equatable {
    public var threadId: String?
    public var categoryId: String?
    public var badge: Int?
    /// `nil` uses the default sound; `false` is silent; a name plays a bundled file.
    public var sound: LocalNotificationSound?

    public init(
        threadId: String? = nil,
        categoryId: String? = nil,
        badge: Int? = nil,
        sound: LocalNotificationSound? = nil
    ) {
        self.threadId = threadId
        self.categoryId = categoryId
        self.badge = badge
        self.sound = sound
    }
}

/// How a local notification sounds.
///
/// The silent case is named `silent` rather than `none` deliberately: as
/// `LocalNotificationSound?` a case named `none` is ambiguous with
/// `Optional.none`, and the compiler cannot tell "no sound" from "unspecified".
public enum LocalNotificationSound: Sendable, Equatable {
    case silent
    case `default`
    case named(String)
}

/// A local notification to schedule.
public struct LocalNotification: Sendable, Equatable {
    /// Caller-owned, stable identity. Scheduling the same id replaces the
    /// pending notification rather than adding a second one.
    public let id: String
    public let title: String
    public let body: String
    public let schedule: LocalSchedule
    /// Passed to the open handler. The SDK never opens it.
    public let deepLink: String?
    public let customData: [String: String]
    public let ios: LocalNotificationIOSOptions?

    public init(
        id: String,
        title: String,
        body: String,
        schedule: LocalSchedule,
        deepLink: String? = nil,
        customData: [String: String] = [:],
        ios: LocalNotificationIOSOptions? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.schedule = schedule
        self.deepLink = deepLink
        self.customData = customData
        self.ios = ios
    }
}

/// Why scheduling failed. Cases are distinguished because they need different
/// responses: a denied permission is a product problem, a full queue is a
/// scheduling-strategy problem, and invalid content is a programming error.
public enum LocalScheduleError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case permissionDenied
    case scheduleInPast
    /// iOS keeps only the 64 soonest pending notifications and silently discards
    /// the rest. Surfacing that is the difference between a developer learning
    /// it now and learning it from a user.
    case capacityExceeded
    case platformError(String)
}

/// A scheduled notification awaiting delivery.
public struct PendingLocalNotification: Sendable, Equatable {
    public let id: String
    /// Absent for recurring schedules, whose next date the platform owns.
    public let nextTriggerDate: Date?
}

// MARK: - Validation

public enum LocalNotificationLimits {
    /// iOS keeps at most this many pending notifications per application.
    public static let maxPending = 64
    public static let maxIdLength = 64
    public static let maxTitleLength = 100
    public static let maxBodyLength = 250
    public static let maxCustomDataKeys = 20
    public static let maxCustomDataBytes = 4096
    /// Reserved so a local schedule can never collide with a Cloud invocation.
    public static let idNamespace = "notifie.local."
}

extension LocalNotification {
    /// Mirrors `packages/contracts` so all Device SDKs reject the same input.
    func validate() -> LocalScheduleError? {
        if id.isEmpty || id.count > LocalNotificationLimits.maxIdLength {
            return .invalidRequest("id must be 1-\(LocalNotificationLimits.maxIdLength) characters")
        }
        if id.hasPrefix(LocalNotificationLimits.idNamespace) {
            return .invalidRequest(
                "id must not start with the reserved \"\(LocalNotificationLimits.idNamespace)\" namespace"
            )
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        if id.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return .invalidRequest("id may contain only letters, digits, dot, underscore, colon or hyphen")
        }
        if title.isEmpty || title.count > LocalNotificationLimits.maxTitleLength {
            return .invalidRequest("title must be 1-\(LocalNotificationLimits.maxTitleLength) characters")
        }
        if body.isEmpty || body.count > LocalNotificationLimits.maxBodyLength {
            return .invalidRequest("body must be 1-\(LocalNotificationLimits.maxBodyLength) characters")
        }
        if customData.count > LocalNotificationLimits.maxCustomDataKeys {
            return .invalidRequest("at most \(LocalNotificationLimits.maxCustomDataKeys) custom data fields")
        }
        if customData.keys.contains(where: { $0.hasPrefix("gk_") }) {
            return .invalidRequest("custom data must not use the reserved gk_ prefix")
        }
        // Measured in UTF-8 because the platform payload budget is bytes, and
        // character counts pass for text that then fails to deliver.
        let dataBytes = customData.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        if dataBytes > LocalNotificationLimits.maxCustomDataBytes {
            return .invalidRequest("custom data must be at most 4 KB")
        }

        switch schedule {
        case .after(let seconds):
            if seconds < 1 { return .invalidRequest("interval must be at least 1 second") }
        case .daily(let hour, let minute), .weekly(_, let hour, let minute):
            if !(0...23).contains(hour) { return .invalidRequest("hour must be 0-23") }
            if !(0...59).contains(minute) { return .invalidRequest("minute must be 0-59") }
            if case .weekly(let weekday, _, _) = schedule, !(1...7).contains(weekday) {
                return .invalidRequest("weekday must be 1-7 with Monday as 1")
            }
        case .at:
            break
        }

        return nil
    }

    /// The next firing instant, or nil for a one-shot schedule already past.
    ///
    /// Shared with the Android implementation and the contract package so all
    /// three agree on the boundaries rather than each re-deriving them.
    func nextOccurrence(from now: Date, calendar: Calendar = .current) -> Date? {
        switch schedule {
        case .at(let date):
            return date > now ? date : nil
        case .after(let seconds):
            return now.addingTimeInterval(seconds)
        case .daily(let hour, let minute):
            guard var next = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: now
            ) else { return nil }
            if next <= now {
                next = calendar.date(byAdding: .day, value: 1, to: next) ?? next
            }
            return next
        case .weekly(let weekday, let hour, let minute):
            guard let base = calendar.date(
                bySettingHour: hour, minute: minute, second: 0, of: now
            ) else { return nil }
            let target = Self.foundationWeekday(fromISO: weekday)
            var components = DateComponents()
            components.weekday = target
            components.hour = hour
            components.minute = minute
            components.second = 0
            // Searching forward from just before the candidate keeps a slot
            // occurring later today on today instead of skipping a week.
            let searchStart = base > now ? now.addingTimeInterval(-1) : now
            return calendar.nextDate(
                after: searchStart,
                matching: components,
                matchingPolicy: .nextTime
            )
        }
    }

    /// Converts ISO-8601 weekdays (Monday 1 ... Sunday 7) to Foundation's
    /// Sunday-first numbering (Sunday 1 ... Saturday 7).
    static func foundationWeekday(fromISO weekday: Int) -> Int {
        (weekday % 7) + 1
    }
}

// MARK: - Platform seam

#if canImport(UserNotifications)

/// The subset of `UNUserNotificationCenter` the SDK uses.
///
/// Exists so tests never call `UNUserNotificationCenter.current()`, which
/// requires an application bundle and traps in a plain test process. Injecting
/// this makes scheduling behavior testable on its own terms.
protocol UserNotificationCentring: Sendable {
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequests() async -> [UNNotificationRequest]
    func removePendingRequests(withIdentifiers identifiers: [String])
    func authorizationStatus() async -> UNAuthorizationStatus
}

struct LiveUserNotificationCentre: UserNotificationCentring {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: - Scheduler

/// Schedules local notifications through an injectable notification centre.
final class LocalNotificationScheduler: @unchecked Sendable {
    private let centre: UserNotificationCentring
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    init(
        centre: UserNotificationCentring,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.centre = centre
        self.calendar = calendar
        self.now = now
    }

    func schedule(_ notification: LocalNotification) async -> Result<Void, LocalScheduleError> {
        if let error = notification.validate() {
            return .failure(error)
        }

        let status = await centre.authorizationStatus()
        // .notDetermined is allowed through: iOS accepts the schedule and the
        // application may request permission before it fires. Only an explicit
        // denial makes delivery impossible.
        if status == .denied {
            return .failure(.permissionDenied)
        }

        let currentTime = now()
        guard let fireDate = notification.nextOccurrence(from: currentTime, calendar: calendar) else {
            return .failure(.scheduleInPast)
        }

        let platformId = LocalNotificationLimits.idNamespace + notification.id
        let pending = await centre.pendingRequests()
        let replacesExisting = pending.contains { $0.identifier == platformId }
        if !replacesExisting && pending.count >= LocalNotificationLimits.maxPending {
            return .failure(.capacityExceeded)
        }

        let request = UNNotificationRequest(
            identifier: platformId,
            content: content(for: notification),
            trigger: trigger(for: notification, fireDate: fireDate, from: currentTime)
        )

        do {
            try await centre.add(request)
            return .success(())
        } catch {
            return .failure(.platformError(String(describing: error)))
        }
    }

    func cancel(ids: [String]) {
        guard !ids.isEmpty else { return }
        centre.removePendingRequests(
            withIdentifiers: ids.map { LocalNotificationLimits.idNamespace + $0 }
        )
    }

    func pending() async -> [PendingLocalNotification] {
        await centre.pendingRequests().compactMap { request in
            guard request.identifier.hasPrefix(LocalNotificationLimits.idNamespace) else {
                // A Cloud notification or one the host application scheduled
                // itself. Reporting it would imply ownership the SDK does not
                // have, and cancelling it later would be wrong.
                return nil
            }
            let id = String(request.identifier.dropFirst(LocalNotificationLimits.idNamespace.count))
            let next = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return PendingLocalNotification(id: id, nextTriggerDate: next)
        }
    }

    private func content(for notification: LocalNotification) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body

        var userInfo: [String: Any] = [:]
        for (key, value) in notification.customData {
            userInfo[key] = value
        }
        if let deepLink = notification.deepLink {
            // Reuses the remote deep-link key so host applications keep one
            // open handler for local and Cloud notifications alike.
            userInfo["gk_deep_link"] = deepLink
        }
        userInfo["notifie_local_id"] = notification.id
        content.userInfo = userInfo

        if let ios = notification.ios {
            if let threadId = ios.threadId { content.threadIdentifier = threadId }
            if let categoryId = ios.categoryId { content.categoryIdentifier = categoryId }
            if let badge = ios.badge { content.badge = NSNumber(value: badge) }
            switch ios.sound {
            case .silent: break
            case .default, nil: content.sound = .default
            case .named(let name):
                content.sound = UNNotificationSound(named: UNNotificationSoundName(name))
            }
        } else {
            content.sound = .default
        }

        return content
    }

    private func trigger(
        for notification: LocalNotification,
        fireDate: Date,
        from currentTime: Date
    ) -> UNNotificationTrigger {
        switch notification.schedule {
        case .at, .after:
            // Interval rather than calendar: these are instants, and a calendar
            // trigger would re-interpret them if the device changed timezone.
            let interval = max(fireDate.timeIntervalSince(currentTime), 1)
            return UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        case .daily(let hour, let minute):
            var components = DateComponents()
            components.hour = hour
            components.minute = minute
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        case .weekly(let weekday, let hour, let minute):
            var components = DateComponents()
            components.weekday = LocalNotification.foundationWeekday(fromISO: weekday)
            components.hour = hour
            components.minute = minute
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        }
    }
}

// MARK: - Public API

public extension Notifie {

    /**
     Schedules a local notification.

     Requires no API key, no network and no `initialize()` call.

     Scheduling an id that is already pending replaces it, so this is safe to
     call repeatedly — for example on every launch to re-assert a reminder.
     */
    @discardableResult
    static func schedule(_ notification: LocalNotification) async -> Result<Void, LocalScheduleError> {
        await localScheduler.schedule(notification)
    }

    /// Cancels pending local notifications. Unknown ids are ignored, so
    /// cancellation is idempotent and safe to call defensively.
    static func cancelScheduled(ids: [String]) {
        localScheduler.cancel(ids: ids)
    }

    /// Cancels a single pending local notification.
    static func cancelScheduled(id: String) {
        localScheduler.cancel(ids: [id])
    }

    /// Local notifications this SDK scheduled and that have not yet fired.
    ///
    /// Excludes Cloud and host-application notifications: reporting those would
    /// imply an ownership the SDK does not have.
    static func pendingScheduled() async -> [PendingLocalNotification] {
        await localScheduler.pending()
    }
}

private let liveLocalScheduler = LocalNotificationScheduler(centre: LiveUserNotificationCentre())

extension Notifie {
    /// Overridden by tests so no case reaches `UNUserNotificationCenter.current()`.
    nonisolated(unsafe) static var localSchedulerOverride: LocalNotificationScheduler?

    static var localScheduler: LocalNotificationScheduler {
        localSchedulerOverride ?? liveLocalScheduler
    }
}

#endif
