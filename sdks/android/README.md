# Notifie for Android

The Android SDK owns anonymous and identified users, Firebase token rotation,
notification permission, lifecycle events, foreground presentation, durable
event batching, retries, and logout-safe token revocation.

## Local notifications, without an account

Local notifications need no API key, no network and no `initialize()` call.
Kotlin imports packages rather than modules, so one wildcard import exposes the
complete Notifie API:

```kotlin
import dev.notifie.*

val result = Notifie.schedule(
    context,
    LocalNotification(
        id = "daily-practice",
        title = "Time to practise",
        body = "Your streak is waiting.",
        schedule = LocalSchedule.Daily(hour = 9, minute = 0),
        deepLink = "myapp://practice",
    ),
)

Notifie.cancelScheduled(context, "daily-practice")
val pending = Notifie.pendingScheduled(context)
```

Schedules are `At(epochMillis)`, `After(seconds)`, `Daily(hour, minute)` and
`Weekly(weekday, hour, minute)`, where Monday is 1 and Sunday is 7.

Scheduling an id that is already pending **replaces** it. Recurring schedules
repeat on wall-clock components, so a 9am reminder stays at 9am across a
daylight-saving change.

Definitions are persisted and re-armed after a reboot or an application upgrade,
because `AlarmManager` keeps nothing across either.

Restoration runs **after the device is first unlocked**, not at boot: Android
keeps app storage credential-encrypted until then, so stored schedules cannot be
read earlier. A reminder due in that window is delivered once restoration runs.

### Delivery precision

Inexact alarms are the default. Exact alarms are a scarce system resource and
require a user-visible permission on Android 12+, so requesting one may be
downgraded rather than granted:

```kotlin
LocalNotificationAndroidOptions(exact = true)
```

`LocalScheduleResult.Scheduled.precision` reports what was **actually** granted.
Never assume the request succeeded.

Battery optimisation and OEM background restrictions can delay inexact alarms.
That is a platform constraint, not a reliability guarantee this SDK can make.

```kotlin
import android.app.Activity
import android.os.Bundle
import dev.notifie.Notifie

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate()
        Notifie.initialize(applicationContext, "<SDK_INGEST_KEY>")
        Notifie.enableNotifications()
    }
}
```

Track product events where they happen:

```kotlin
Notifie.track("notifie_test_notification")
```

Handle silent/data-only pushes without replacing the SDK's Firebase service:

```kotlin
Notifie.setBackgroundMessageHandler { data ->
    // Refresh local state using the string payload.
}
```

Register the handler from `Application.onCreate()` when work must start immediately
after a cold-process delivery. Otherwise Notifie persists the payload and replays
it after initialization and handler registration.

Android does not invoke `FirebaseMessagingService.onMessageReceived()` for
system-rendered alert notifications while the app is backgrounded. Notifie records
device receipt for foreground alerts and data-only messages; for background alerts,
provider acceptance and notification-open attribution remain available, but no
device-receipt event is claimed.

Identify after sign-in and reset before the host session is discarded:

```kotlin
Notifie.identify("user-123", mapOf("plan" to "pro"))
Notifie.reset()
```

`reset()` persists a server-side token revocation before clearing local identity.
If the device is offline, the SDK replays that revocation after connectivity or
the next application launch. A later `identify()` reattaches the retained device
token to the new signed-in identity without prompting for notification permission again.

The library manifest registers `NotifieFirebaseMessagingService` (the stable native
component identity retained for upgrades), creates the
`notifie_default` notification channel, handles `onNewToken`, displays rich
foreground notifications, and records opens from notification intents.

If the app already owns a `FirebaseMessagingService`, remove the library service
with a manifest merge rule and forward both callbacks:

```xml
<service
    android:name="dev.notifie.NotifieFirebaseMessagingService"
    tools:node="remove" />
```

```kotlin
override fun onNewToken(token: String) =
    Notifie.registerPushToken(applicationContext, token)

override fun onMessageReceived(message: RemoteMessage) {
    Notifie.handleRemoteMessage(this, message)
}
```

Firebase still requires the standard `google-services.json` native project
configuration. Never add the server-side Firebase service-account JSON to the app.