import Foundation
import OSLog
import SwiftUI
import Notifie
import UserNotifications

/// One line in the on-screen activity log.
struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let message: String
}

/**
 Holds the demo's configuration and a visible record of what the SDK did.

 The log exists because the interesting failures here are silent ones — an
 event that never left the device, a token that was never issued. Printing to
 the Xcode console would hide them from anyone running the app without Xcode
 attached.
 */
@MainActor
final class DemoState: ObservableObject {
    private static let apiKeyDefault = "notifie.demo.apiKey"
    private static let baseURLDefault = "notifie.demo.baseURL"

    @Published var apiKey: String = UserDefaults.standard.string(forKey: apiKeyDefault) ?? ""
    @Published var baseURL: String =
        UserDefaults.standard.string(forKey: baseURLDefault) ?? "http://127.0.0.1:3000"

    @Published private(set) var isInitialised = false
    @Published private(set) var identifiedAs: String?
    @Published private(set) var enrolment: String?
    @Published private(set) var deviceToken: String?
    @Published private(set) var entries: [LogEntry] = []
    /// Local reminders currently scheduled, refreshed after every change.
    @Published private(set) var pendingLocal: [String] = []

    /// Stable across launches so repeated runs act as the same person, which is
    /// what makes inactivity and audience behaviour observable.
    let userId: String = {
        let key = "notifie.demo.userId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let generated = "demo-\(UUID().uuidString.prefix(8).lowercased())"
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    nonisolated func log(_ message: String) {
        Task { @MainActor in
            entries.insert(LogEntry(time: Date(), message: message), at: 0)
            if entries.count > 200 { entries.removeLast() }
        }
    }

    // MARK: - Lifecycle

    func initializeIfConfigured() {
        guard !apiKey.isEmpty, let url = URL(string: baseURL) else {
            log("Not initialised — enter an API key, then tap Initialize.")
            return
        }
        start(apiKey: apiKey, url: url)
    }

    func initializeNow() {
        guard !apiKey.isEmpty else {
            log("Enter an API key first.")
            return
        }
        guard let url = URL(string: baseURL) else {
            log("That base URL is not valid.")
            return
        }

        UserDefaults.standard.set(apiKey, forKey: Self.apiKeyDefault)
        UserDefaults.standard.set(baseURL, forKey: Self.baseURLDefault)
        start(apiKey: apiKey, url: url)
    }

    /**
     Fires a comma-separated event list passed at launch:

       xcrun simctl launch <device> dev.notifie.demo \
         -notifie.demo.trackOnLaunch "purchase_completed,onboarding_completed"

     Launch arguments rather than the URL scheme because iOS 17 shows an
     "Open in…?" confirmation for cross-app URL opens, which a script cannot
     dismiss. These run through `track()`, the same path the buttons use.
    */
    private func runLaunchScript() {
        guard let list = UserDefaults.standard.string(forKey: "notifie.demo.trackOnLaunch"),
              !list.isEmpty else { return }

        let events = list.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        for event in events {
            track(event, properties: ["source": .string("launch_script")])
        }
        log("Launch script fired \(events.count) event(s).")
        flush()
    }

    /// `-notifie.demo.enableNotificationsOnLaunch YES` asks for permission at
    /// startup. Granting it is still a manual tap — simctl cannot grant the
    /// notification permission, unlike camera or location.
    private func enableNotificationsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "notifie.demo.enableNotificationsOnLaunch") else {
            return
        }
        enableNotifications()
    }

    private func start(apiKey: String, url: URL) {
        Notifie.initialize(
            apiKey: apiKey,
            baseURL: url,
            // Small batch and short interval so events appear in the dashboard
            // while you are still looking at it. Production defaults are larger.
            batchSize: 1,
            flushInterval: 5,
            logLevel: .debug
        )
        isInitialised = true
        log("Initialised against \(url.absoluteString)")

        Notifie.identify(userId, properties: ["platform": .string("ios"), "demo": .bool(true)])
        identifiedAs = userId
        log("Identified as \(userId)")

        runLaunchScript()
        enableNotificationsIfRequested()
    }

    // MARK: - Actions

    func track(_ event: String, properties: Properties = [:]) {
        guard isInitialised else {
            log("Initialize first — \(event) was not sent.")
            return
        }
        Notifie.track(event, properties: properties)
        log("track(\"\(event)\")")
    }

    func flush() {
        guard isInitialised else { return }
        Task {
            await Notifie.flush()
            log("Flushed the queue.")
        }
    }

    func setPremium(_ value: Bool) {
        guard isInitialised else {
            log("Initialize first.")
            return
        }
        Notifie.identify(userId, properties: ["premium": .bool(value)])
        log("identify(premium: \(value))")
    }

    func enableNotifications() {
        guard isInitialised else {
            log("Initialize first.")
            return
        }
        Task {
            let result = await Notifie.enableNotifications()
            switch result {
            case .enrolled:
                enrolment = "enrolled"
                log("Enrolled — a device token was registered with Notifie.")
                await recordNotificationSettings()
                if UserDefaults.standard.bool(
                    forKey: "notifie.demo.localNotificationOnLaunch"
                ) {
                    await scheduleLocalNotification()
                }
            case .denied:
                enrolment = "denied"
                log("Denied. iOS will not prompt again; reset the simulator to retry.")
            case .noToken(let reason):
                enrolment = "no token"
                log("Permission granted but no APNs token: \(reason)")
            case .notInitialised:
                enrolment = "not initialised"
                log("enableNotifications() before initialize().")
            }
        }
    }

    /**
     Records the device-side settings that APNs cannot report.

     HTTP 200 from Apple means "accepted for delivery", not "displayed". A user
     can still have banners, Lock Screen, Notification Center or sounds disabled.
     Without these values the server and the phone disagree and there is no way
     to tell which side is responsible.
     */
    private func recordNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        let properties: Properties = [
            "authorization": .string(settings.authorizationStatus.notifieName),
            "alert": .string(settings.alertSetting.notifieName),
            "lock_screen": .string(settings.lockScreenSetting.notifieName),
            "notification_center": .string(settings.notificationCenterSetting.notifieName),
            "sound": .string(settings.soundSetting.notifieName),
        ]

        Notifie.track("demo_notification_settings", properties: properties)
        log(
            "Notification settings: auth=\(settings.authorizationStatus.notifieName), "
                + "alert=\(settings.alertSetting.notifieName), "
                + "lock=\(settings.lockScreenSetting.notifieName)"
        )
        await Notifie.flush()
    }

    /**
     Schedules a local banner through iOS itself.

     This is the control experiment for a remote push: if this does not display,
     APNs and Notifie are irrelevant — the phone is suppressing presentation.
     It also exercises the exact same UNUserNotificationCenterDelegate path as
     a remote notification received while the app is foregrounded.
     */
    private func scheduleLocalNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Notifie local test"
        content.body = "If you see this, iOS notification presentation works."
        content.sound = .default
        content.userInfo = ["gk_invocation_id": "local-device-test"]

        let request = UNNotificationRequest(
            identifier: "notifie-local-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            log("Local notification scheduled for 3 seconds from now.")
        } catch {
            log("Local notification could not be scheduled: \(error.localizedDescription)")
        }
    }

    func recordToken(_ token: Data) {
        deviceToken = token.map { String(format: "%02x", $0) }.joined()
    }

    func reset() {
        Notifie.reset()
        isInitialised = false
        identifiedAs = nil
        enrolment = nil
        deviceToken = nil
        log("Reset. Queued events and the stored identity are gone.")
    }

}

// MARK: - Scripted control

extension DemoState {
    /**
     Handles `notifiedemo://` URLs so the app can be driven from a script.

     Deliberately routes through the same methods the buttons call — a scripted
     run and a tapped run must not be able to diverge, or the automation would
     be testing something nobody actually does.

     Supported:
       notifiedemo://track?event=purchase_completed&amount=9.99
       notifiedemo://premium?value=true
       notifiedemo://enable-notifications
       notifiedemo://flush
    */
    func handle(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            log("Could not parse \(url.absoluteString)")
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch components.host {
        case "track":
            guard let event = value("event") else {
                log("track needs ?event=")
                return
            }
            var properties: Properties = [:]
            for item in items where item.name != "event" {
                guard let raw = item.value else { continue }
                // Typed rather than all-strings: property filters and the event
                // explorer both key off the inferred type.
                if let number = Double(raw), raw.contains(".") {
                    properties[item.name] = .double(number)
                } else if let integer = Int(raw) {
                    properties[item.name] = .int(integer)
                } else if raw == "true" || raw == "false" {
                    properties[item.name] = .bool(raw == "true")
                } else {
                    properties[item.name] = .string(raw)
                }
            }

            track(event, properties: properties)

        case "premium":
            setPremium(value("value") != "false")

        case "enable-notifications":
            enableNotifications()

        case "flush":
            flush()

        default:
            log("Unknown command: \(components.host ?? "none")")
        }
    }
}

private extension UNAuthorizationStatus {
    var notifieName: String {
        switch self {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }
}

private extension UNNotificationSetting {
    var notifieName: String {
        switch self {
        case .notSupported: "not_supported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown"
        }
    }
}

/**
 Local notifications, with no Notifie account.

 Everything in this extension runs before `initialize()` and without an API
 key, a base URL or a network. Run it in airplane mode: that is the point.
 */
extension DemoState {

    /// Asks for permission in product context rather than at launch.
    ///
    /// iOS shows this prompt once per install, so a denial is effectively
    /// permanent. Asking when the user has just chosen a reminder — rather
    /// than on first launch, before they know what the app does — is the
    /// difference between a granted permission and a lost one.
    func requestLocalPermission() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        do {
            let granted = try await centre.requestAuthorization(options: [.alert, .sound, .badge])
            log(granted ? "Notification permission granted." : "Notification permission denied.")
            return granted
        } catch {
            log("Permission request failed: \(error.localizedDescription)")
            return false
        }
    }

    /// A one-shot reminder soon enough to observe while the app is backgrounded.
    func scheduleInTenSeconds() {
        Task {
            guard await requestLocalPermission() else { return }
            let result = await Notifie.schedule(
                LocalNotification(
                    id: "demo-soon",
                    title: "Ten seconds later",
                    body: "Scheduled locally with no account and no network.",
                    schedule: .after(seconds: 10),
                    deepLink: "notifiedemo://local?id=demo-soon"
                )
            )
            await report(result, action: "one-shot reminder in 10s")
        }
    }

    /// A recurring reminder on wall-clock components.
    func scheduleDailyReminder() {
        Task {
            guard await requestLocalPermission() else { return }
            let result = await Notifie.schedule(
                LocalNotification(
                    id: "demo-daily",
                    title: "Daily practice",
                    body: "This repeats at 09:00 local time, including across DST.",
                    schedule: .daily(hour: 9, minute: 0),
                    deepLink: "notifiedemo://local?id=demo-daily"
                )
            )
            await report(result, action: "daily reminder at 09:00")
        }
    }

    /// Scheduling the same id again replaces it rather than adding a duplicate.
    func rescheduleDailyReminder(hour: Int) {
        Task {
            let result = await Notifie.schedule(
                LocalNotification(
                    id: "demo-daily",
                    title: "Daily practice",
                    body: "Rescheduled to \(String(format: "%02d", hour)):00 — same id, so it replaced the old one.",
                    schedule: .daily(hour: hour, minute: 0)
                )
            )
            await report(result, action: "daily reminder moved to \(hour):00")
        }
    }

    func cancelLocal(id: String) {
        Notifie.cancelScheduled(id: id)
        log("Cancelled \"\(id)\" (cancelling again is harmless).")
        Task { await refreshPendingLocal() }
    }

    func refreshPendingLocal() async {
        let pending = await Notifie.pendingScheduled()
        pendingLocal = pending.map(\.id).sorted()
    }

    private func report(_ result: Result<Void, LocalScheduleError>, action: String) async {
        switch result {
        case .success:
            log("Scheduled \(action).")
        case .failure(let error):
            // Each case needs a different response, which is why the SDK
            // distinguishes them rather than returning a bare failure.
            switch error {
            case .permissionDenied:
                log("Not scheduled: notifications are denied in Settings.")
            case .capacityExceeded:
                log("Not scheduled: iOS holds only 64 pending notifications.")
            case .scheduleInPast:
                log("Not scheduled: that time has already passed.")
            case .invalidRequest(let reason):
                log("Not scheduled: \(reason)")
            case .platformError(let reason):
                log("Not scheduled: \(reason)")
            }
        }
        await refreshPendingLocal()
    }
}

/**
 Scriptable local notification checks.

 Physical iOS devices cannot be driven from the command line the way `adb`
 drives Android, so device verification runs through launch arguments and
 reports results to the system log. That makes the run repeatable rather than
 dependent on someone tapping in the right order.

 ```bash
 xcrun devicectl device process launch --device <id> dev.notifie.localdemo \
   -- -notifie.demo.localCheck schedule
 ```
 */
extension DemoState {

    private static let checkLog = Logger(
        subsystem: "dev.notifie.demo",
        category: "local-check"
    )

    func runLocalNotificationCheckIfRequested() {
        guard let mode = UserDefaults.standard.string(forKey: "notifie.demo.localCheck"),
              !mode.isEmpty else { return }

        Task {
            let granted = await requestLocalPermission()
            Self.report("permission granted=\(granted)")

            switch mode {
            case "schedule":
                await runScheduleCheck()
            case "capacity":
                await runCapacityCheck()
            case "cancel":
                await runCancelCheck()
            default:
                Self.report("unknown mode \(mode)")
            }
        }
    }

    /// Schedules, replaces by id, and reports the pending set.
    private func runScheduleCheck() async {
        let soon = await Notifie.schedule(
            LocalNotification(
                id: "device-check",
                title: "Device check",
                body: "Scheduled locally with no account and no network.",
                schedule: .after(seconds: 10),
                deepLink: "notifiedemo://local?id=device-check"
            )
        )
        Self.report("schedule after(10s): \(Self.describe(soon))")

        // Same id again: this must replace rather than add a second one.
        let replaced = await Notifie.schedule(
            LocalNotification(
                id: "device-check",
                title: "Device check (replaced)",
                body: "Replacement kept the pending count at one.",
                schedule: .after(seconds: 12)
            )
        )
        Self.report("reschedule same id: \(Self.describe(replaced))")

        let pending = await Notifie.pendingScheduled()
        Self.report("pending after replace: \(pending.count) \(pending.map(\.id))")
    }

    /// Fills the iOS pending queue past its limit.
    ///
    /// This is the check no mock can make: iOS silently keeps only the 64
    /// soonest requests, so a real device is the only place the boundary is
    /// observable.
    private func runCapacityCheck() async {
        var scheduled = 0
        var firstFailure: String?

        for index in 0..<70 {
            let result = await Notifie.schedule(
                LocalNotification(
                    id: "capacity-\(index)",
                    title: "Capacity \(index)",
                    body: "Filling the pending queue.",
                    // Spread far out so none fire during the check.
                    schedule: .after(seconds: TimeInterval(3600 + index * 60))
                )
            )
            switch result {
            case .success:
                scheduled += 1
            case .failure(let error):
                if firstFailure == nil {
                    firstFailure = "at \(index): \(error)"
                }
            }
        }

        let pending = await Notifie.pendingScheduled()
        Self.report("capacity: scheduled=\(scheduled) pending=\(pending.count)")
        Self.report("capacity: firstFailure=\(firstFailure ?? "none")")

        Notifie.cancelScheduled(ids: (0..<70).map { "capacity-\($0)" })
        let remaining = await Notifie.pendingScheduled()
        Self.report("capacity: pending after cleanup=\(remaining.count)")
    }

    private func runCancelCheck() async {
        _ = await Notifie.schedule(
            LocalNotification(
                id: "cancel-check",
                title: "Cancel check",
                body: "Should never appear.",
                schedule: .after(seconds: 30)
            )
        )
        Notifie.cancelScheduled(id: "cancel-check")
        // Cancelling twice must be harmless.
        Notifie.cancelScheduled(id: "cancel-check")
        Notifie.cancelScheduled(id: "never-scheduled")

        let pending = await Notifie.pendingScheduled()
        Self.report("cancel: pending=\(pending.count)")
    }

    private static func describe(_ result: Result<Void, LocalScheduleError>) -> String {
        switch result {
        case .success: return "ok"
        case .failure(let error): return "failed \(error)"
        }
    }

    /// Reported to stdout and the system log so a device run is readable
    /// without the UI. `devicectl --console` streams stdout but not the
    /// unified log, so printing is what makes the run observable.
    private static func report(_ message: String) {
        print("NOTIFIE_CHECK \(message)")
        fflush(stdout)
        checkLog.notice("NOTIFIE_CHECK \(message, privacy: .public)")
    }
}
