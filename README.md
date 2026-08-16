# Notifie

Open-source SDKs for delivering mobile push notifications, plus the contracts and
CLI that support them.

Notifie Device works without a Notifie account: you own the credentials, the
tokens and the delivery. [Notifie Cloud](https://notifie.dev) is an optional
hosted service that adds identity, durable queues and workflows on top of the
same SDKs — adopting it does not require changing SDK.

## Packages

| Package | Description |
| --- | --- |
| [`@notifie/contracts`](packages/contracts) | Event, identity, push token and notification wire contracts |
| [`@notifie/cli`](packages/cli) | Project setup and integration diagnostics |
| [`@notifie/server`](packages/server) | Server SDK for events and notifications |
| [`@notifie/react-native`](sdks/react-native) | React Native SDK |
| [`@notifie/web`](sdks/web) | Browser SDK |
| [Swift](sdks/swift) | iOS/macOS SDK |
| [Android](sdks/android) | Android SDK |
| [Flutter](sdks/flutter) | Flutter SDK |

## Documentation

Guides live in [docs-public](docs-public) and at
[notifie.dev](https://notifie.dev).

## Development

```bash
corepack enable
pnpm install --frozen-lockfile
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
