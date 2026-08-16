# Changelog

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
