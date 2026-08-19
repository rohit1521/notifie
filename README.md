# Notifie

Open-source SDKs for delivering mobile push notifications, plus the contracts and
CLI that support them.

Notifie Device works without a Notifie account: you own the credentials, the
tokens and the delivery. [Notifie Cloud](https://notifie.dev) is an optional
hosted service that adds identity, durable queues and workflows on top of the
same SDKs — adopting it does not require changing SDK.

Everything here is in public beta. Versions below are the ones currently
published; this table is generated from the manifests that ship, so it cannot
drift from a release.

## Install

**Swift** — `Podfile`

```ruby
pod 'Notifie', '0.1.0-beta.3'
```

**Android** — `app/build.gradle.kts`

```kotlin
implementation("dev.notifie:notifie-android:0.1.0-beta.4")
```

**Flutter**

```bash
flutter pub add notifie_flutter:^0.1.0-beta.7
```

**CLI** — `latest` still resolves to a withdrawn build, so pin the version:

```bash
npm install -g @notifie-dev/cli@0.1.0-beta.2
```

Then read the [quickstart](docs-public/quickstart.mdx).

## Published

| Package | Description | Registry | Coordinate | Version |
| --- | --- | --- | --- | --- |
| [Swift](sdks/swift) | iOS 15+ SDK: local notifications, APNs tokens, lifecycle events | CocoaPods | `Notifie` | `0.1.0-beta.3` |
| [Android](sdks/android) | Android SDK: local alarms, FCM tokens, reboot recovery | Maven Central | `dev.notifie:notifie-android` | `0.1.0-beta.4` |
| [Flutter](sdks/flutter) | Flutter SDK bridging the native implementations | pub.dev | `notifie_flutter` | `0.1.0-beta.7` |
| [CLI](packages/cli) | Project configuration and integration diagnostics | npm | `@notifie-dev/cli` | `0.1.0-beta.2` |
| [Contracts](packages/contracts) | Event, identity, push token and notification wire types | npm | `@notifie-dev/contracts` | `0.1.0-beta.2` |

## Known issues in published versions

These are fixed in this repository but not yet on the registry.

- **Android `0.1.0-beta.4`** — until `0.1.0-beta.5` is published, four defects remain. Tapping a notification whose deep link the app does not declare crashes the app. In a Flutter app, tapping a locally scheduled notification does nothing at all — the tap resolves to an activity the merged manifest no longer declares; remote push taps are unaffected. Two local reminders whose identifiers happen to share a 32-bit hash collapse onto one alarm, so scheduling the second silently replaces the first and cancelling either cancels both, while `pending()` keeps reporting the one that can no longer fire. And signing out while offline, then signing back in, revokes the push token the device has just re-registered, leaving it silently unreachable.

## Source available, not yet published

These build and test in this repository but are **not on npm**. Installing them
will fail until they are released; use them by reading the source or by pinning
a git checkout.

| Package | Description | Reserved coordinate |
| --- | --- | --- |
| [Server SDK](packages/server) | Typed track, identify and notify calls from a Node backend | `@notifie-dev/server` |
| [React Native](sdks/react-native) | Events and FCM tokens; no local notification scheduling yet | `@notifie-dev/react-native` |
| [Web](sdks/web) | Browser event client | `@notifie-dev/web` |

## Documentation

Guides live in [docs-public](docs-public) and at
[notifie.dev](https://notifie.dev).

## Development

```bash
corepack enable
pnpm install --no-frozen-lockfile
pnpm check
```

Native SDKs use their own toolchains:

```bash
xcrun swift test --package-path sdks/swift
cd sdks/flutter && flutter test
```

Publishing is manual for every registry except npm. See
[RELEASING.md](RELEASING.md).

## Security

Report vulnerabilities privately. See [SECURITY.md](SECURITY.md). Never commit
APNs `.p8` keys, Firebase service accounts or `google-services.json`.

## License

[Apache-2.0](LICENSE).
