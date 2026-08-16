# Notifie Swift SDK

Push notifications for indie developers. Four methods. That's it.

## Requirements

- iOS 15+ / macOS 12+
- Swift 5.9+

## Installation

Clone the Notifie repository and add `sdks/swift` through Xcode's **Add Local
Package** flow. A tagged public package release is not available yet.

## Local notifications, without an account

Local notifications are scheduled and presented by iOS on the device. They need
no API key, no network and no `initialize()` call — everything below works in
airplane mode.

```swift
import Notifie

let result = await Notifie.schedule(
    LocalNotification(
        id: "daily-practice",
        title: "Time to practise",
        body: "Your streak is waiting.",
        schedule: .daily(hour: 9, minute: 0),
        deepLink: "myapp://practice"
    )
)

Notifie.cancelScheduled(id: "daily-practice")
let pending = await Notifie.pendingScheduled()
```

Schedules are `.at(Date)`, `.after(seconds:)`, `.daily(hour:minute:)` and
`.weekly(weekday:hour:minute:)`, where Monday is 1 and Sunday is 7.

Scheduling an id that is already pending **replaces** it, so calling this on
every launch is safe rather than duplicating reminders.

Recurring schedules repeat on wall-clock components, so a 9am reminder stays at
9am across a daylight-saving change rather than drifting an hour.

Failures are distinguished because each needs a different response:

| Error | Meaning |
| --- | --- |
| `.permissionDenied` | The user denied notifications in Settings |
| `.capacityExceeded` | iOS holds only 64 pending notifications per app |
| `.scheduleInPast` | The requested time has already passed |
| `.invalidRequest` | Content or schedule failed validation |
| `.platformError` | iOS rejected the request for another reason |

Request permission in product context rather than at launch. iOS shows the
prompt once per install, so a denial is effectively permanent.

Request it **before** scheduling. Until permission is granted iOS accepts a
request and then keeps nothing: `pendingScheduled()` returns empty and the
notification never fires. The platform reports success either way, so the SDK
cannot detect it on your behalf. Verified on an iPhone.

## Quickstart

```swift
import Notifie

// 1. Initialize once at app launch (AppDelegate / @main)
Notifie.initialize(apiKey: "gk_live_xxxxxxxxxxxx_yoursecret")

// 2. Identify a user after sign-in
Notifie.identify("user-123", properties: [
    "plan": .string("pro"),
    "age":  .int(28)
])

// 3. Track events anywhere
Notifie.track("purchase_completed", properties: [
    "amount": .double(9.99),
    "currency": .string("USD")
])

// 4. Ask for notification permission and register for push, in one call.
//    Deliberately not automatic: iOS only prompts once, so *when* you ask is
//    a product decision your app owns.
let result = await Notifie.enableNotifications()
```

## Additional helpers

```swift
// Force-flush the queue (e.g. before app termination in tests)
await Notifie.flush()

// Revoke the device token, clear identity, and generate a new anonymous ID.
// Offline revocations persist and replay on the next launch.
Notifie.reset()
```

## Configuration

```swift
Notifie.initialize(
    apiKey: "gk_live_...",
    baseURL: URL(string: "https://api.yourhost.com")!,
    batchSize: 20,          // flush after N events (max 100)
    flushInterval: 30,      // flush every N seconds
    maxQueueSize: 1000,     // drop oldest when exceeded
    logLevel: .debug        // .silent (default) | .error | .debug
)
```

## Property types

`NotifieProperty` is a typed enum for flat scalar values the server accepts:

```swift
.string("hello")
.double(9.99)
.int(42)
.bool(true)
.null
```

Nested objects are rejected server-side and are not representable in the SDK.

## What the SDK tracks for you

You do not instrument any of these:

| Event | When |
| --- | --- |
| `install` | first launch after install, once ever |
| `app_open` | every launch and return from foreground |
| `session_start` | alongside `app_open` |
| `notification_received` | a push arrives while the app is open |
| `notification_opened` | the user taps a notification |
| `notification_clicked` | the user taps a notification action button |

Every event also carries `platform`, `os_version`, `app_version`, `app_build`,
`locale`, `timezone` and `device_model`, so audiences can target them.

**Nothing beyond this is invented.** No SDK can know what a "purchase" means in an
arbitrary app, and guessing would produce data you did not write and cannot trust. Domain
events stay yours:

```swift
Notifie.track("purchase_completed", properties: ["amount": .double(9.99)])
```

## Wiring up push

Forward two AppDelegate callbacks. That is the entire native integration:

```swift
func application(_ app: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    PushTokenBridge.shared.didRegister(deviceToken: token)
}

func application(_ app: UIApplication,
                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
    PushTokenBridge.shared.didFail(error: error)
}
```

Then report engagement from your notification delegate:

```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
                            didReceive response: UNNotificationResponse) async {
    Notifie.notificationOpened(response: response)

    // Notifie never navigates for you — routing is your decision.
    if let url = Notifie.deepLink(from: response.notification.request.content.userInfo) {
        router.open(url)
    }
}
```

For rich images, add a Notification Service Extension and use the SDK helper:

```swift
override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
) {
    Task {
        let content = request.content.mutableCopy() as! UNMutableNotificationContent
        if let attachment = await Notifie.notificationAttachment(from: content.userInfo) {
            content.attachments = [attachment]
        }
        contentHandler(content)
    }
}
```

## Behaviour worth knowing

**Anonymous activity carries over.** An anonymous ID is generated on first launch and
attached to every event. When you later call `identify`, the server claims that anonymous
record, so events from before sign-up belong to the user:

```swift
Notifie.track("app_open")            // anonymous
Notifie.track("onboarding_completed")
Notifie.identify("user-123")         // both events now belong to user-123
```

**Properties are carried by `identify`.** There is no separate property setter: one less
method to learn, and no ambiguity about what happens when you set a property before anyone
has been identified.

**Events survive a cold kill.** The pending queue is written to disk on every enqueue and
reloaded at launch, so force-quitting the app does not lose unsent events.

**Retries cannot duplicate.** Each event gets a `messageId` at `track()` time that is reused
across retries; the server stores each exactly once. Failures back off exponentially with
jitter, capped at five minutes. `400`/`401`/`403`/`413` are treated as permanent and dropped
rather than retried forever, which would block every later event behind them.

**Ordering is preserved.** Rapid `identify` calls are delivered in the
order they were made, so last-write-wins on the server applies the value you set last.

**`track()` never blocks and never throws.** It is synchronous and fire-and-forget from the
caller's perspective. Calling it before `initialize()` logs a warning and no-ops instead of
trapping.

## Tests

```bash
xcrun swift test
```

Use `xcrun swift` rather than a bare `swift` if you have a standalone toolchain installed —
older toolchains cannot build against the current macOS SDK.

The package also ships a `notifie-example` executable that drives the real SDK against a
running API, used by the repository's end-to-end check:

```bash
xcrun swift build
./.build/debug/notifie-example "gk_live_…" "http://localhost:3000"
```

