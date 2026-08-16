# Notifie for Flutter

Notifie owns anonymous identity, user association, lifecycle events, durable
event delivery, Firebase token refresh, notification attribution, and logout
cleanup behind a small Flutter API.

## Install

```yaml
dependencies:
  notifie_flutter:
    path: path/to/Notifie/sdks/flutter
```

Add the standard Firebase Android and iOS configuration files to the host app.
Never add a Firebase service-account key or Notifie server send key to a
mobile application.

Private-beta users upgrading from `notifie_flutter` must change the dependency
and import name once. The deprecated `Notifie` Dart facade, legacy library entry
point, native plugin classes, method channel, stored state, and notification intents
remain compatible so the upgrade does not lose queued events or attribution.

## Initialize

```dart
import 'package:notifie_flutter/notifie_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Notifie.initialize(
    apiKey: '<SDK_INGEST_KEY>',
    baseUrl: 'https://notifie.dev',
    requestTimeout: const Duration(seconds: 15),
    onError: (error) => diagnostics.record(error),
    onNotificationOpened: (notification) {
      final deepLink = notification.deepLink;
      if (deepLink != null) router.open(deepLink);
    },
  );
  runApp(const MyApp());
}
```

`initialize()` emits `install` and `first_open` once, then `app_open` and
`session_start` for launches and returns from background.

## Identity and events

```dart
await Notifie.identify('user-42', properties: {'plan': 'pro'});
await Notifie.track('post_liked', properties: {'post_id': 'post-7'});
```

Events are persisted before delivery, receive a stable UUID `messageId`, batch
up to 100 per request, and retry `429`, `5xx`, and network failures with capped
exponential backoff. Permanent `4xx` rejections are removed so one bad event
cannot block the queue.

## Notifications

Request permission in a user-appropriate product context:

```dart
await Notifie.enableNotifications();
```

On Android the SDK registers the current FCM token. On iOS it registers the
native APNs token directly, so the APNs key uploaded in Notifie remains the
single Apple delivery credential; Firebase does not need a second copy of that
key. The SDK follows token refreshes, re-registers the token after `identify()`,
tracks foreground receipt and opens with
`gk_invocation_id`, and exposes deep-link/image metadata through
`NotifieNotification`. Data-only background payloads are persisted by a
top-level Firebase handler and replayed through `onNotificationReceived` on the
next main-isolate startup, so attribution survives process suspension.

FlutterFire supports one global background handler. If the host already owns
it, disable Notifie's automatic registration and forward messages through a
single dispatcher:

```dart
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  await notifieFirebaseBackgroundHandler(message);
  await appBackgroundHandler(message);
}

await Notifie.initialize(
  apiKey: '<SDK_INGEST_KEY>',
  registerFirebaseBackgroundHandler: false,
);
FirebaseMessaging.onBackgroundMessage(firebaseBackgroundHandler);
```

Use `Notifie.flush()` before controlled shutdowns. Call
`Notifie.reset()` on logout; it rotates anonymous identity and durably retries
token revocation if the device is offline.

Provider acceptance is not proof that a device displayed a notification. Real
presentation still requires a physical-device check.

## Validate

```bash
flutter analyze
flutter test
```

See `examples/flutter` for the Android/iOS harness and integration test.