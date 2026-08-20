import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notifie_client.dart';

const _pendingNotificationPrefix = 'notifie.pending_background_notification.';

final class PendingNotifieNotification {
  const PendingNotifieNotification({
    required this.key,
    required this.notification,
  });

  final String key;
  final NotifieNotification notification;
}

@pragma('vm:entry-point')
Future<void> notifieFirebaseBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  final preferences = await SharedPreferences.getInstance();
  final rawId = message.messageId ??
      '${DateTime.now().microsecondsSinceEpoch}:${message.data.hashCode}';
  final id = base64Url.encode(utf8.encode(rawId)).replaceAll('=', '');
  await preferences.setString(
    '$_pendingNotificationPrefix$id',
    jsonEncode(_notificationToJson(_notificationFromMessage(message))),
  );
}

final class FirebasePushTokenProvider extends PushTokenProvider {
  static const _notificationChannel = MethodChannel(
    'notifie_flutter/notifications',
  );
  static final _nativeOpenedNotifications =
      StreamController<NotifieNotification>.broadcast();
  static final _nativeReceivedNotifications =
      StreamController<NotifieNotification>.broadcast();
  static bool _nativeOpenBridgeAttached = false;

  static Future<void> registerBackgroundHandler() async {
    // Firebase must exist before the handler is registered.
    // `onBackgroundMessage` returns void but dispatches to a platform channel,
    // so with the plugin absent it fails as an unhandled asynchronous error
    // that no caller can catch — a synchronous try/catch around it sees
    // nothing. Establishing Firebase first turns an unconfigured project into
    // a failure the caller can actually handle.
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(notifieFirebaseBackgroundHandler);
  }

  static Future<List<PendingNotifieNotification>>
      pendingNotifications() async {
    final preferences = await SharedPreferences.getInstance();
    final keys = preferences
        .getKeys()
        .where((key) => key.startsWith(_pendingNotificationPrefix))
        .toList()
      ..sort();
    final notifications = <PendingNotifieNotification>[];
    for (final key in keys) {
      final raw = preferences.getString(key);
      if (raw != null) {
        final notification = _decodeNotification(raw);
        if (notification != null) {
          notifications.add(
            PendingNotifieNotification(key: key, notification: notification),
          );
        }
      }
    }
    return notifications;
  }

  static Future<void> acknowledgePendingNotification(String key) async {
    if (!key.startsWith(_pendingNotificationPrefix)) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  }

  String? get _platform => switch (defaultTargetPlatform) {
        TargetPlatform.iOS => 'ios',
        TargetPlatform.android => 'android',
        _ => null,
      };

  @override
  Future<void> prepare() => _ensureFirebase();

  @override
  Future<void> notificationListenersAttached() async {
    await _attachNativeOpenBridge();
  }

  @override
  Future<PushToken?> enableNotifications() async {
    final platform = _platform;
    if (platform == null) return null;

    await _ensureFirebase();

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      throw const NotifieException(
        'Notification permission is denied. Enable notifications in system settings.',
      );
    }
    if (settings.authorizationStatus == AuthorizationStatus.notDetermined) {
      throw const NotifieException(
        'Notification permission was not granted.',
      );
    }

    final token = platform == 'ios'
        ? await _waitForApnsToken(messaging)
        : await messaging.getToken();
    if (token == null || token.isEmpty) {
      throw const NotifieException(
        'The device did not provide a push token.',
      );
    }

    return PushToken(
      token: token,
      platform: platform,
      provider: platform == 'ios' ? 'apns' : 'fcm',
    );
  }

  @override
  Stream<PushToken> get tokenRefreshes {
    final platform = _platform;
    if (platform == null) return const Stream.empty();
    if (platform == 'android') {
      return FirebaseMessaging.instance.onTokenRefresh.map(
        (token) => PushToken(
          token: token,
          platform: platform,
          provider: 'fcm',
        ),
      );
    }
    return FirebaseMessaging.instance.onTokenRefresh
        .asyncMap((_) => FirebaseMessaging.instance.getAPNSToken())
        .where((token) => token != null && token.isNotEmpty)
        .cast<String>()
        .map(
          (token) => PushToken(
            token: token,
            platform: platform,
            provider: 'apns',
          ),
        );
  }

  @override
  Stream<NotifieNotification> get foregroundNotifications =>
      _mergeNotificationStreams(
        FirebaseMessaging.onMessage.map(_notificationFromMessage),
        _nativeReceivedNotifications.stream,
      );

  @override
  Stream<NotifieNotification> get openedNotifications =>
      _mergeNotificationStreams(
        FirebaseMessaging.onMessageOpenedApp.map(_notificationFromMessage),
        _nativeOpenedNotifications.stream,
      );

  @override
  Future<NotifieNotification?> initialNotification() async {
    if (_platform == null) return null;
    await _ensureFirebase();
    final message = await FirebaseMessaging.instance.getInitialMessage();
    return message == null ? null : _notificationFromMessage(message);
  }

  Future<void> _ensureFirebase() async {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  }

  /// Attaches the channel the native SDKs use to report notification opens.
  ///
  /// Both mobile platforms need it, for different halves of the problem. iOS
  /// has no other path at all. Android has one for remote pushes only —
  /// `FirebaseMessaging.onMessageOpenedApp` — and locally scheduled
  /// notifications are posted by this SDK rather than by Firebase, so without
  /// this bridge a Flutter Android app could schedule a local notification,
  /// watch the user tap it, and never learn which one was tapped.
  ///
  /// The Android side only forwards taps carrying its local-notification id,
  /// so remote opens keep arriving once through Firebase rather than twice.
  Future<void> _attachNativeOpenBridge() async {
    if (_nativeOpenBridgeAttached ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return;
    }
    _nativeOpenBridgeAttached = true;
    _notificationChannel.setMethodCallHandler((call) async {
      final arguments = call.arguments;
      if (arguments is Map<Object?, Object?>) {
        final notification = _notificationFromNativeData(arguments);
        if (call.method == 'notificationOpened') {
          _nativeOpenedNotifications.add(notification);
        } else if (call.method == 'notificationReceived') {
          _nativeReceivedNotifications.add(notification);
        }
      }
    });
    final pending = await _notificationChannel
        .invokeMapMethod<Object?, Object?>('markOpenHandlerReady');
    for (final data in _pendingNativeNotifications(pending?['opens'])) {
      _nativeOpenedNotifications.add(_notificationFromNativeData(data));
    }
    for (final data in _pendingNativeNotifications(pending?['receipts'])) {
      _nativeReceivedNotifications.add(_notificationFromNativeData(data));
    }
  }

  Future<String?> _waitForApnsToken(FirebaseMessaging messaging) async {
    for (var attempt = 0; attempt < 20; attempt += 1) {
      final token = await messaging.getAPNSToken();
      if (token != null && token.isNotEmpty) return token;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }
}

Iterable<Map<Object?, Object?>> _pendingNativeNotifications(Object? value) {
  if (value is! List<Object?>) return const [];
  return value.whereType<Map<Object?, Object?>>();
}

Stream<NotifieNotification> _mergeNotificationStreams(
  Stream<NotifieNotification> first,
  Stream<NotifieNotification> second,
) =>
    Stream<NotifieNotification>.multi((controller) {
      final firstSubscription = first.listen(
        controller.add,
        onError: controller.addError,
      );
      final secondSubscription = second.listen(
        controller.add,
        onError: controller.addError,
      );
      controller.onCancel = () async {
        await firstSubscription.cancel();
        await secondSubscription.cancel();
      };
    });

NotifieNotification _notificationFromNativeData(
  Map<Object?, Object?> data,
) =>
    NotifieNotification(
      title: data['gk_title'] as String?,
      body: data['gk_body'] as String?,
      data: data.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    );

NotifieNotification _notificationFromMessage(RemoteMessage message) {
  return NotifieNotification(
    title: message.notification?.title,
    body: message.notification?.body,
    data: Map<String, Object?>.from(message.data),
  );
}

Map<String, Object?> _notificationToJson(NotifieNotification notification) =>
    {
      'title': notification.title,
      'body': notification.body,
      'data': notification.data,
    };

NotifieNotification? _notificationFromJson(Map<String, Object?> json) {
  final data = json['data'];
  if (data is! Map<String, Object?>) return null;
  return NotifieNotification(
    title: json['title'] as String?,
    body: json['body'] as String?,
    data: data,
  );
}

NotifieNotification? _decodeNotification(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, Object?>
        ? _notificationFromJson(decoded)
        : null;
  } on FormatException {
    return null;
  }
}
