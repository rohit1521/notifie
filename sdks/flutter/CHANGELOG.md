# Changelog

## 0.1.0-beta.10

### Fixed

- The iOS bridge now pins `Notifie` 0.1.0-beta.5. The previous release pinned
  0.1.0-beta.4 exactly, so once the native pod moved to 0.1.0-beta.5 an app that
  also depended on the native SDK directly could not resolve CocoaPods at all.
  Flutter behaviour is unchanged: this plugin registers APNs tokens itself
  rather than through the native enrolment call.

## 0.1.0-beta.9

### Fixed

- Android notification taps now deliver the complete FCM payload to the
  destination activity through `dev.notifie:notifie-android` 0.1.0-beta.6.
  The native SDK previously attributed the open but started the app with no
  extras, so custom data could not reach application code.
- Android's Gradle integration no longer applies the Kotlin Gradle Plugin,
  avoiding Flutter's built-in-Kotlin compatibility warning.
- Initializing without Firebase reports the missing setup through `onError`
  once rather than twice.
- The iOS bridge now pins `Notifie` 0.1.0-beta.4, which exposes documented APNs
  registration facades and prevents `enableNotifications()` from timing out
  when its AppDelegate callbacks are forwarded.

## 0.1.0-beta.8

### Fixed

- Tapping a local notification now opens the app and delivers its deep link on
  Android. The native SDK addressed the tap to its own open activity by class,
  and this plugin removes that activity from the merged manifest so it can route
  deep links through Dart rather than navigating them natively — so every
  locally scheduled notification pointed at a class the app did not declare. The
  tap failed with `START_CLASS_NOT_FOUND` and did nothing at all: no crash, no
  log, no open. Taps are now addressed by intent action, which is what lets a
  host app legitimately replace the activity, and remain scoped to the app.
- Two local reminders whose identifiers happen to share a 32-bit hash no longer
  collapse onto one alarm on Android. The native SDK derived a `PendingIntent`
  request code from `String.hashCode`, which is stable but not unique, so
  scheduling the second reminder silently replaced the first, cancelling either
  cancelled both, and `pendingScheduled` kept reporting one that could no longer
  fire. Codes are now allocated and persisted per identifier.
- `pendingScheduled` now reports what the operating system will actually
  deliver on Android. It previously read only the SDK's own store, so a
  reminder whose alarm had been lost was reported as pending; a missing alarm
  is now re-armed and an elapsed one-shot is dropped.
- Signing out while offline and signing back in no longer revokes the push
  token the device has just re-registered on Android. Registration bypassed the
  revocation gate, and because Firebase returns the same token after a logout,
  the queued revocation deleted the live registration and left the device
  silently unreachable while the plugin believed push was active.
- Bundles `dev.notifie:notifie-android` 0.1.0-beta.5, which carries the fixes
  above. The plugin pins that artifact exactly, so they could not otherwise have
  reached a Flutter app — 0.1.0-beta.7 still pinned 0.1.0-beta.4.

## 0.1.0-beta.7

### Fixed

- Tapping a local notification now reaches Dart on iOS. The bridge forwarded a
  tap only when the payload carried `gk_invocation_id`, which is set on remote
  pushes; a notification scheduled through `Notifie.schedule` is stamped with
  `notifie_local_id` instead, so every local tap — and the deep link it
  carried — was discarded in silence. Both keys are now accepted.
- Replies to Flutter are delivered on the platform thread. The scheduling,
  pending, capabilities and permission handlers replied from a bare `Task`,
  which resumes on Swift's cooperative pool rather than the thread Flutter
  requires for a method-channel result.
- The buffers holding notifications that arrive before Dart attaches are now
  guarded by a lock, capped, and reset when the plugin registers. Previously a
  new Flutter engine kept the previous engine's "handler ready" flag, so opens
  were delivered into a dead channel instead of being buffered for the new one.
- Bundles `Notifie` 0.1.0-beta.3, which stops push registration being stranded
  after a logout and stops an `identify` made offline being lost. The podspec
  pinned 0.1.0-beta.2 exactly, so those fixes could not otherwise have reached
  a Flutter app.
- The iOS podspec version tracked the Dart version again; it had drifted to
  0.1.0-beta.3 while pub.dev was on 0.1.0-beta.6, making the pod
  unresolvable for anyone who asked for the version pub.dev advertised.

## 0.1.0-beta.6

### Fixed

- Tapping a notification no longer opens Android's "Complete action using"
  chooser listing the same app twice, and no longer crashes when the wrong
  entry is picked. This plugin and the Android SDK it depends on each declared
  an activity for `dev.notifie.NOTIFICATION_OPEN`; the class names differ, so
  the manifest merger kept both and Android could not choose between them.
  Selecting the native one threw `ActivityNotFoundException`, because it
  navigates the deep link itself while Flutter resolves routes in Dart. The
  plugin now merges the native activity away and keeps the single handler that
  hands the payload to Dart.
- Delivered pushes now arrive on the `notifie_default` channel. The channel is
  created by the native SDK's `initialize`, which a Flutter host never calls,
  so Android logged "Notification Channel requested (notifie_default) has not
  been created by the app" and fell back to Firebase's generic "Miscellaneous"
  channel. The plugin now creates it on attach, reading the id from the
  manifest entry the SDK already declares so the two cannot drift apart.
- `enableNotifications()` now reports a missing Firebase setup as a
  `NotifieException` explaining what to add, instead of rethrowing the raw
  platform error naming a generated `values.xml` the developer never wrote.
- Firebase setup guidance now names the Google Services Gradle plugin.
  `google-services.json` does nothing until that plugin turns it into the
  resources Firebase reads, so a developer who had already added the file was
  told to add the file again.

### Changed

- The bundled `dev.notifie:notifie-android` dependency moves from
  `0.1.0-beta.2` to `0.1.0-beta.4`, and the plugin no longer resolves it from
  `mavenLocal()` now that it is published.

## 0.1.0-beta.5

### Fixed

- `Notifie.initialize` no longer leaks an unhandled asynchronous error when
  Firebase is not configured. The 0.1.0-beta.4 guard could not catch this one:
  `FirebaseMessaging.onBackgroundMessage` returns `void` but dispatches to a
  platform channel, so the failure surfaced after the surrounding `try` had
  already returned. The background handler is now registered only once Firebase
  has been established, so an unconfigured project is reported through `onError`
  like every other optional-push failure.

## 0.1.0-beta.4

### Fixed

- `Notifie.initialize` no longer fails when Firebase is not configured. It
  attached the push provider unconditionally, so on a project without
  `google-services.json` the Firebase lookup threw, initialization unwound the
  client, and the SDK tracked no events at all. Remote push is now optional at
  startup: the failure is reported through `onError` and events and local
  notifications keep working. An explicit `enableNotifications()` call still
  throws.
- A failed push attach no longer marks the provider as attached. The flag was
  set before the work that could fail, so a retry after adding
  `google-services.json` returned early and left the notification listeners
  detached for the rest of the process.

## 0.1.0-beta.3

### Changed

- Remove the unpublished old-brand compatibility surface. There were no
  external consumers, so keeping duplicate classes, packages and method
  channels would preserve confusion without protecting an integration.
- Depend on the Notifie-only native SDK releases:
  `Notifie 0.1.0-beta.2` and
  `dev.notifie:notifie-android:0.1.0-beta.2`.

## 0.1.0-beta.2

### Fixed

- Pin the iOS bridge to `Notifie 0.1.0-beta.1`. CocoaPods does not select a
  prerelease to satisfy an open-ended dependency, so `0.1.0-beta.1` could not
  resolve in a clean iOS application even though the native pod was available.

## 0.1.0-beta.1

First public beta.

### Added

- Local notifications that require no Notifie account, API key or network:
  `schedule`, `cancelScheduled`, `pendingScheduled` and
  `notificationCapabilities`.
- Absolute, interval, daily and weekly schedules. Recurring schedules repeat on
  wall-clock components, so a reminder holds its time across a daylight-saving
  change.
- Stable cross-platform error codes distinguishing denied permission, exhausted
  capacity, past timestamps and invalid content.
- `Notifie` as the primary API, with the previous `Notifie` facade retained as
  a deprecated alias.

### Notes

Scheduling delegates to the native Swift and Android implementations rather than
running in Dart, so behaviour matches the native SDKs exactly.

Request notification permission before scheduling. Until permission is granted,
iOS accepts a scheduled request and then keeps nothing, and the platform reports
success either way.
