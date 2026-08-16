import XCTest
import UserNotifications
@testable import Notifie

/// A notification centre that records rather than schedules.
///
/// Tests must never reach `UNUserNotificationCenter.current()`: it requires an
/// application bundle and traps in a plain test process.
private final class MockCentre: UserNotificationCentring, @unchecked Sendable {
    var requests: [UNNotificationRequest] = []
    var status: UNAuthorizationStatus = .authorized
    var addError: Error?
    private(set) var removedIdentifiers: [String] = []

    func add(_ request: UNNotificationRequest) async throws {
        if let addError { throw addError }
        requests.removeAll { $0.identifier == request.identifier }
        requests.append(request)
    }

    func pendingRequests() async -> [UNNotificationRequest] { requests }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        requests.removeAll { identifiers.contains($0.identifier) }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func seedPending(count: Int) {
        for index in 0..<count {
            requests.append(
                UNNotificationRequest(
                    identifier: "notifie.local.seed-\(index)",
                    content: UNMutableNotificationContent(),
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
                )
            )
        }
    }
}

private func reminder(
    id: String = "daily-reminder",
    title: String = "Time to practise",
    body: String = "Your streak is waiting.",
    schedule: LocalSchedule = .daily(hour: 9, minute: 0),
    deepLink: String? = nil,
    customData: [String: String] = [:],
    ios: LocalNotificationIOSOptions? = nil
) -> LocalNotification {
    LocalNotification(
        id: id,
        title: title,
        body: body,
        schedule: schedule,
        deepLink: deepLink,
        customData: customData,
        ios: ios
    )
}

/// A fixed clock in a timezone that observes daylight saving.
///
/// Without pinning, the schedule assertions would only be as meaningful as the
/// machine's timezone: in a non-DST zone the transition case passes trivially.
private func newYorkCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}

private func newYorkDate(_ iso: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/New_York")!
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: iso)!
}

final class LocalNotificationTests: XCTestCase {

    private func makeScheduler(
        centre: MockCentre,
        now: Date = newYorkDate("2026-03-10 12:00:00")
    ) -> LocalNotificationScheduler {
        LocalNotificationScheduler(
            centre: centre,
            calendar: newYorkCalendar(),
            now: { now }
        )
    }

    // MARK: - Account-free operation

    func testSchedulingRequiresNoInitialisation() async {
        // No Notifie.initialize() anywhere in this test: local notifications
        // must work without an API key, a base URL or a network.
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)

        let result = await scheduler.schedule(reminder())

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(centre.requests.count, 1)
    }

    // MARK: - Identity and replacement

    func testSchedulingNamespacesTheIdentifier() async {
        let centre = MockCentre()
        _ = await makeScheduler(centre: centre).schedule(reminder(id: "streak"))

        XCTAssertEqual(centre.requests.first?.identifier, "notifie.local.streak")
    }

    func testReschedulingSameIdReplacesRatherThanDuplicates() async {
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)

        _ = await scheduler.schedule(reminder(title: "First"))
        _ = await scheduler.schedule(reminder(title: "Second"))

        XCTAssertEqual(centre.requests.count, 1)
        XCTAssertEqual(centre.requests.first?.content.title, "Second")
    }

    func testPendingExcludesNotificationsTheSdkDoesNotOwn() async {
        let centre = MockCentre()
        centre.requests.append(
            UNNotificationRequest(
                identifier: "cloud-invocation-123",
                content: UNMutableNotificationContent(),
                trigger: nil
            )
        )
        let scheduler = makeScheduler(centre: centre)
        _ = await scheduler.schedule(reminder(id: "mine"))

        let pending = await scheduler.pending()

        XCTAssertEqual(pending.map(\.id), ["mine"])
    }

    func testCancelIsIdempotentAndNamespaced() async {
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)
        _ = await scheduler.schedule(reminder(id: "streak"))

        scheduler.cancel(ids: ["streak"])
        scheduler.cancel(ids: ["streak"])
        scheduler.cancel(ids: ["never-scheduled"])

        XCTAssertTrue(centre.requests.isEmpty)
        XCTAssertEqual(
            centre.removedIdentifiers,
            ["notifie.local.streak", "notifie.local.streak", "notifie.local.never-scheduled"]
        )
    }

    // MARK: - Capacity

    func testCapacityExceededIsReportedRatherThanSilentlyDropped() async {
        let centre = MockCentre()
        centre.seedPending(count: 64)
        let scheduler = makeScheduler(centre: centre)

        let result = await scheduler.schedule(reminder(id: "one-too-many"))

        XCTAssertEqual(result.failure, .capacityExceeded)
    }

    func testReplacingAnExistingScheduleSucceedsAtCapacity() async {
        // Replacement does not grow the pending list, so a full queue must not
        // stop an application re-asserting a reminder it already owns.
        let centre = MockCentre()
        centre.seedPending(count: 63)
        let scheduler = makeScheduler(centre: centre)
        _ = await scheduler.schedule(reminder(id: "mine"))

        let result = await scheduler.schedule(reminder(id: "mine", title: "Updated"))

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(centre.requests.count, 64)
    }

    // MARK: - Permission

    func testDeniedPermissionIsDistinctFromSchedulingFailure() async {
        let centre = MockCentre()
        centre.status = .denied
        let scheduler = makeScheduler(centre: centre)

        let result = await scheduler.schedule(reminder())

        XCTAssertEqual(result.failure, .permissionDenied)
        XCTAssertTrue(centre.requests.isEmpty)
    }

    func testUndeterminedPermissionStillSchedules() async {
        // iOS accepts schedules before the prompt; the application may ask
        // later and before the notification fires.
        let centre = MockCentre()
        centre.status = .notDetermined
        let scheduler = makeScheduler(centre: centre)

        let result = await scheduler.schedule(reminder())

        XCTAssertNoThrow(try result.get())
    }

    // MARK: - Schedules

    func testPastAbsoluteTimeFailsValidation() async {
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)

        let result = await scheduler.schedule(
            reminder(schedule: .at(newYorkDate("2020-01-01 09:00:00")))
        )

        XCTAssertEqual(result.failure, .scheduleInPast)
        XCTAssertTrue(centre.requests.isEmpty)
    }

    func testAbsoluteScheduleUsesAnIntervalTrigger() async {
        // An instant must not be reinterpreted if the device changes timezone,
        // which a calendar trigger would do.
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)

        _ = await scheduler.schedule(
            reminder(schedule: .at(newYorkDate("2026-03-10 18:00:00")))
        )

        let trigger = centre.requests.first?.trigger as? UNTimeIntervalNotificationTrigger
        XCTAssertNotNil(trigger)
        XCTAssertEqual(trigger?.timeInterval ?? 0, 6 * 3600, accuracy: 1)
        XCTAssertEqual(trigger?.repeats, false)
    }

    func testDailyScheduleRepeatsOnWallClockComponents() async {
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)

        _ = await scheduler.schedule(reminder(schedule: .daily(hour: 7, minute: 30)))

        let trigger = centre.requests.first?.trigger as? UNCalendarNotificationTrigger
        XCTAssertEqual(trigger?.dateComponents.hour, 7)
        XCTAssertEqual(trigger?.dateComponents.minute, 30)
        XCTAssertEqual(trigger?.repeats, true)
        XCTAssertNil(trigger?.dateComponents.day, "a daily trigger must not pin a calendar day")
    }

    func testWeeklyScheduleMapsIsoWeekdayToFoundation() async {
        // ISO Monday is 1; Foundation counts Sunday as 1, so Monday is 2.
        let centre = MockCentre()
        let scheduler = makeScheduler(centre: centre)

        _ = await scheduler.schedule(
            reminder(schedule: .weekly(weekday: 1, hour: 9, minute: 0))
        )

        let trigger = centre.requests.first?.trigger as? UNCalendarNotificationTrigger
        XCTAssertEqual(trigger?.dateComponents.weekday, 2)
    }

    func testIsoSundayMapsToFoundationSunday() {
        XCTAssertEqual(LocalNotification.foundationWeekday(fromISO: 7), 1)
        XCTAssertEqual(LocalNotification.foundationWeekday(fromISO: 1), 2)
    }

    func testDailyTimeAlreadyPassedMovesToTomorrow() {
        let notification = reminder(schedule: .daily(hour: 9, minute: 0))
        let next = notification.nextOccurrence(
            from: newYorkDate("2026-03-10 12:00:00"),
            calendar: newYorkCalendar()
        )

        XCTAssertEqual(next, newYorkDate("2026-03-11 09:00:00"))
    }

    func testDailyScheduleHoldsWallClockAcrossDaylightSaving() {
        // US daylight saving begins on 8 March 2026. A fixed 24-hour interval
        // would drift the reminder to 10am and leave it there.
        let notification = reminder(schedule: .daily(hour: 9, minute: 0))
        let next = notification.nextOccurrence(
            from: newYorkDate("2026-03-07 20:00:00"),
            calendar: newYorkCalendar()
        )

        var components = newYorkCalendar().dateComponents([.hour, .minute, .day], from: next!)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.day, 8)
    }

    func testWeeklySlotLaterTodayDoesNotSkipAWeek() {
        // 10 March 2026 is a Tuesday; 18:00 is still ahead of noon.
        let notification = reminder(schedule: .weekly(weekday: 2, hour: 18, minute: 0))
        let next = notification.nextOccurrence(
            from: newYorkDate("2026-03-10 12:00:00"),
            calendar: newYorkCalendar()
        )

        XCTAssertEqual(next, newYorkDate("2026-03-10 18:00:00"))
    }

    func testWeeklySlotAlreadyPassedTodayRollsToNextWeek() {
        let notification = reminder(schedule: .weekly(weekday: 2, hour: 9, minute: 0))
        let next = notification.nextOccurrence(
            from: newYorkDate("2026-03-10 12:00:00"),
            calendar: newYorkCalendar()
        )

        XCTAssertEqual(next, newYorkDate("2026-03-17 09:00:00"))
    }

    // MARK: - Validation

    func testReservedNamespaceIsRejected() async {
        let centre = MockCentre()
        let result = await makeScheduler(centre: centre)
            .schedule(reminder(id: "notifie.local.spoofed"))

        guard case .invalidRequest = result.failure else {
            return XCTFail("expected invalidRequest, got \(String(describing: result.failure))")
        }
    }

    func testIdentifierCharsetIsRejected() async {
        let centre = MockCentre()
        for id in ["has space", "has/slash", ""] {
            let result = await makeScheduler(centre: centre).schedule(reminder(id: id))
            guard case .invalidRequest = result.failure else {
                return XCTFail("expected invalidRequest for \"\(id)\"")
            }
        }
    }

    func testReservedCustomDataPrefixIsRejected() async {
        let centre = MockCentre()
        let result = await makeScheduler(centre: centre)
            .schedule(reminder(customData: ["gk_invocation_id": "stolen"]))

        guard case .invalidRequest = result.failure else {
            return XCTFail("expected invalidRequest")
        }
    }

    func testCustomDataBudgetIsMeasuredInUtf8Bytes() async {
        let centre = MockCentre()
        // 1400 three-byte characters passes any character-count limit but
        // exceeds the 4 KB byte budget.
        let wide = String(repeating: "한", count: 1400)
        let result = await makeScheduler(centre: centre)
            .schedule(reminder(customData: ["note": wide]))

        guard case .invalidRequest = result.failure else {
            return XCTFail("expected invalidRequest")
        }
    }

    // MARK: - Content

    func testDeepLinkUsesTheSharedOpenHandlerKey() async {
        let centre = MockCentre()
        _ = await makeScheduler(centre: centre)
            .schedule(reminder(deepLink: "myapp://streak"))

        let userInfo = centre.requests.first?.content.userInfo
        XCTAssertEqual(userInfo?["gk_deep_link"] as? String, "myapp://streak")
        XCTAssertEqual(userInfo?["notifie_local_id"] as? String, "daily-reminder")
    }

    func testPlatformOptionsAreApplied() async {
        let centre = MockCentre()
        _ = await makeScheduler(centre: centre).schedule(
            reminder(ios: LocalNotificationIOSOptions(
                threadId: "streaks",
                categoryId: "REMINDER",
                badge: 3,
                sound: .silent
            ))
        )

        let content = centre.requests.first?.content
        XCTAssertEqual(content?.threadIdentifier, "streaks")
        XCTAssertEqual(content?.categoryIdentifier, "REMINDER")
        XCTAssertEqual(content?.badge, 3)
        XCTAssertNil(content?.sound, "silent must mean no sound, not the default sound")
    }

    func testPlatformFailureIsReportedNotSwallowed() async {
        let centre = MockCentre()
        centre.addError = NSError(domain: "UNErrorDomain", code: 1, userInfo: nil)
        let result = await makeScheduler(centre: centre).schedule(reminder())

        guard case .platformError = result.failure else {
            return XCTFail("expected platformError")
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
