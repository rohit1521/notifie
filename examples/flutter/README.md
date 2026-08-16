# Notifie Flutter Example

This iOS/Android harness exercises initialization, identify, event tracking,
notification permission/token registration, notification callbacks, queue
flush, and logout reset.

## Run locally

1. Add your own Firebase `google-services.json` and/or
	 `GoogleService-Info.plist`. Both paths are ignored by Git.
2. Start the Notifie dashboard and worker.
3. For a USB Android device, run `adb reverse tcp:3000 tcp:3000`.
4. For a physical iOS device, set your own Apple Developer Team ID — signing is
   not committed, because a team identifies its owner and nobody outside it can
   build against it. Uncomment `GK_TEAM_ID` in `ios/Flutter/Debug.xcconfig` and
   `ios/Flutter/Release.xcconfig`, or pick a team in Xcode under Signing &
   Capabilities. The simulator needs neither.
4. Launch:

```bash
flutter run \
	--dart-define=NOTIFIE_API_KEY=<SDK_INGEST_KEY> \
	--dart-define=NOTIFIE_BASE_URL=http://127.0.0.1:3000 \
	--dart-define=NOTIFIE_EXTERNAL_USER_ID=flutter-device-test \
	--dart-define=NOTIFIE_EVENT_NAME=flutter_blackbox_event
```

The committed integration test uses an injected SDK facade, so it proves the
native host UI and workflow without requiring real credentials:

```bash
flutter test test/widget_test.dart
flutter test integration_test/sdk_flow_test.dart -d <device-id>
```

The physical-device run does not by itself prove FCM presentation. That final
boundary requires a configured Firebase project and a real notification send.
