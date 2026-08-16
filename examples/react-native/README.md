# Notifie React Native Example

This React Native 0.86 iOS/Android host app exercises initialization, identify,
event tracking, notification permission/token registration, notification
callbacks, queue flush, and logout reset.

## Run locally

1. Add your Firebase `android/app/google-services.json` and/or
	`ios/GoogleService-Info.plist`. Both are ignored by Git.
2. Apply the standard Google Services Gradle plugin and iOS Firebase setup for
	your own project.
3. Start the Notifie dashboard and worker.
4. For a USB Android device:

```bash
adb reverse tcp:3000 tcp:3000
adb reverse tcp:8081 tcp:8081
```

5. Start and install the app:

```bash
pnpm --filter @notifie/react-native-example start
pnpm --filter @notifie/react-native-example android
```

Enter an SDK ingest key and base URL in the harness. No credentials are stored
in this repository.

## Validate

```bash
pnpm --filter @notifie/react-native-example typecheck
pnpm --filter @notifie/react-native-example lint
pnpm --filter @notifie/react-native-example test
pnpm --filter @notifie/react-native-example android:build
```

The Jest workflow uses an injected facade and proves the complete host
interaction without real credentials. Physical FCM presentation still requires
your Firebase project and a real device send.
