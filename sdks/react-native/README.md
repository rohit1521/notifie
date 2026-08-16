# Notifie for React Native

Notifie owns anonymous identity, user association, lifecycle events, durable
event delivery, Firebase token refresh, notification attribution, and logout
cleanup behind one React Native API.

## Install

```bash
pnpm add @notifie/react-native \
	@react-native-async-storage/async-storage \
	@react-native-firebase/app \
	@react-native-firebase/messaging
```

Add the standard Firebase native configuration to Android and iOS. Never put a
Firebase service-account key or Notifie server send key in a mobile app.

## Initialize

```tsx
import { Notifie } from '@notifie/react-native';

await Notifie.initialize({
	apiKey: '<SDK_INGEST_KEY>',
	baseUrl: 'https://notifie.dev',
	requestTimeoutMs: 15_000,
	onError(error) {
		diagnostics.record(error);
	},
	onNotificationOpened(notification) {
		if (notification.deepLink) Linking.openURL(notification.deepLink);
	},
});
```

`initialize()` emits `install` and `first_open` once, then `app_open` and
`session_start` for launches and returns from background.

## Identity and events

```tsx
await Notifie.identify('user-42', { plan: 'pro' });
await Notifie.track('post_liked', { post_id: 'post-7' });
```

Events are persisted to AsyncStorage before delivery, use a stable UUID
`messageId`, batch up to 100 per request, and retry `429`, `5xx`, and network
failures with capped exponential backoff. Permanent `4xx` rejections are
removed so one bad event cannot block later events.

## Notifications

Request permission in product context:

```tsx
await Notifie.enableNotifications();
```

The SDK handles Android 13 notification permission, iOS remote-message
registration, FCM token refresh, foreground receipt, opened notifications,
cold-start opens, deep links, image URLs, and `gk_invocation_id` attribution.
Data-only background messages are persisted automatically and replayed through
`onNotificationReceived` on initialize. Register optional immediate app work at
module startup:

```tsx
Notifie.setBackgroundMessageHandler(async notification => {
	await refreshRecord(notification.data.record_id);
});
```

Use `Notifie.flush()` before controlled shutdowns. Call
`Notifie.reset()` on logout; it rotates anonymous identity and durably retries
token revocation after offline sessions.

Provider acceptance is not proof that a device displayed a notification. Real
presentation still requires a physical-device check.

## Validate

```bash
pnpm typecheck
pnpm test
```

See `examples/react-native` for the React Native 0.86 Android/iOS harness.