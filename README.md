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
pod 'Notifie', '0.1.0-beta.5'
```

**Android** — `app/build.gradle.kts`

```kotlin
implementation("dev.notifie:notifie-android:0.1.0-beta.6")
```

**Flutter**

```bash
flutter pub add notifie_flutter:^0.1.0-beta.9
```

**CLI** — `latest` still resolves to a withdrawn build, so pin the version:

```bash
npm install -g @notifie-dev/cli@0.1.0-beta.2
```

Then read the [quickstart](docs-public/quickstart.mdx).

## Published

| Package | Description | Registry | Coordinate | Version |
| --- | --- | --- | --- | --- |
| [Swift](sdks/swift) | iOS 15+ SDK: events, APNs tokens, notification callbacks | CocoaPods | `Notifie` | `0.1.0-beta.5` |
| [Android](sdks/android) | Android SDK: events, FCM tokens, notification handling | Maven Central | `dev.notifie:notifie-android` | `0.1.0-beta.6` |
| [Flutter](sdks/flutter) | Flutter SDK bridging the native implementations | pub.dev | `notifie_flutter` | `0.1.0-beta.9` |
| [CLI](packages/cli) | Project configuration and integration diagnostics | npm | `@notifie-dev/cli` | `0.1.0-beta.2` |
| [Contracts](packages/contracts) | Event, identity, push token and notification wire types | npm | `@notifie-dev/contracts` | `0.1.0-beta.1` |

## Known issues in published versions

These are fixed in this repository but not yet on the registry.

- **CLI `0.1.0-beta.2`** — until `0.1.0-beta.3` is published, notifie init and doctor still ask native iOS apps to forward AppDelegate and notification center callbacks manually. Notifie 0.1.0-beta.5 intercepts and forwards those callbacks automatically, so the old CLI adds unnecessary integration work.
- **Contracts `0.1.0-beta.1`** — until `0.1.0-beta.2` is published, the local notification contracts are missing. Nothing documented references them, so this affects only a consumer importing the types directly. The release is ready and waiting on an npm credential.

## Source available, not yet published

These build and test in this repository but are **not on npm**. Installing them
will fail until they are released; use them by reading the source or by pinning
a git checkout.

| Package | Description | Reserved coordinate |
| --- | --- | --- |
| [Server SDK](packages/server) | Typed track, identify and notify calls from a Node backend | `@notifie-dev/server` |
| [React Native](sdks/react-native) | Events and FCM tokens | `@notifie-dev/react-native` |
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

## Security

Report vulnerabilities privately. See [SECURITY.md](SECURITY.md). Never commit
APNs `.p8` keys, Firebase service accounts or `google-services.json`.

## License

[Apache-2.0](LICENSE).
