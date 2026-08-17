import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_push_token_provider.dart';
import 'notifie_core.dart';
import 'local_notification_channel.dart';
import 'local_notifications.dart';
import 'shared_preferences_store.dart';

final class Notifie {
  Notifie._();

  static const _installedKey = 'notifie.installed';
  static NotifieClient? _client;
  static _NotifieLifecycleObserver? _lifecycleObserver;
  static Future<void> _initializationChain = Future.value();

  static Future<void> initialize({
    required String apiKey,
    String baseUrl = 'https://notifie.dev',
    String? anonymousId,
    int batchSize = 20,
    int maxQueueSize = 1000,
    Duration flushInterval = const Duration(seconds: 30),
    Duration requestTimeout = const Duration(seconds: 15),
    NotifieNotificationCallback? onNotificationReceived,
    NotifieNotificationCallback? onNotificationOpened,
    NotifieErrorCallback? onError,
    bool registerFirebaseBackgroundHandler = true,
  }) {
    final operation = _initializationChain.then<void>(
      (_) => _initialize(
        apiKey: apiKey,
        baseUrl: baseUrl,
        anonymousId: anonymousId,
        batchSize: batchSize,
        maxQueueSize: maxQueueSize,
        flushInterval: flushInterval,
        requestTimeout: requestTimeout,
        onNotificationReceived: onNotificationReceived,
        onNotificationOpened: onNotificationOpened,
        onError: onError,
        registerFirebaseBackgroundHandler: registerFirebaseBackgroundHandler,
      ),
      onError: (Object _, StackTrace __) => _initialize(
        apiKey: apiKey,
        baseUrl: baseUrl,
        anonymousId: anonymousId,
        batchSize: batchSize,
        maxQueueSize: maxQueueSize,
        flushInterval: flushInterval,
        requestTimeout: requestTimeout,
        onNotificationReceived: onNotificationReceived,
        onNotificationOpened: onNotificationOpened,
        onError: onError,
        registerFirebaseBackgroundHandler: registerFirebaseBackgroundHandler,
      ),
    );
    _initializationChain = operation;
    return operation;
  }

  static Future<void> _initialize({
    required String apiKey,
    required String baseUrl,
    required String? anonymousId,
    required int batchSize,
    required int maxQueueSize,
    required Duration flushInterval,
    required Duration requestTimeout,
    required NotifieNotificationCallback? onNotificationReceived,
    required NotifieNotificationCallback? onNotificationOpened,
    required NotifieErrorCallback? onError,
    required bool registerFirebaseBackgroundHandler,
  }) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (apiKey.trim().isEmpty) {
      throw const NotifieException('API key cannot be empty.');
    }

    final preferences = await SharedPreferences.getInstance();
    final store = SharedPreferencesNotifieStore(preferences);
    await _disposeCurrentClient();
    if (registerFirebaseBackgroundHandler) {
      await _reportOptionalPushFailureAsync(
        onError,
        FirebasePushTokenProvider.registerBackgroundHandler,
      );
    }

    final client = NotifieClient(
      apiKey: apiKey,
      baseUrl: Uri.parse(baseUrl),
      anonymousId: anonymousId,
      batchSize: batchSize,
      maxQueueSize: maxQueueSize,
      flushInterval: flushInterval,
      requestTimeout: requestTimeout,
      httpClient: http.Client(),
      pushTokenProvider: FirebasePushTokenProvider(),
      store: store,
      onNotificationReceived: onNotificationReceived,
      onNotificationOpened: onNotificationOpened,
      onError: onError,
    );
    _NotifieLifecycleObserver? observer;
    try {
      await client.start();
      // Remote push is optional. A project without Firebase configured must
      // still track events and schedule local notifications, so a failure to
      // attach the push provider is reported and then tolerated here. An
      // explicit enableNotifications() call still throws.
      await _reportOptionalPushFailureAsync(
        onError,
        client.attachPushProvider,
      );
      for (final pending
          in await FirebasePushTokenProvider.pendingNotifications()) {
        await client.recordNotificationReceived(pending.notification);
        await FirebasePushTokenProvider.acknowledgePendingNotification(
          pending.key,
        );
      }
      observer = _NotifieLifecycleObserver(
        onForeground: _trackSession,
        onBackground: flush,
      );
      _lifecycleObserver = observer;
      WidgetsBinding.instance.addObserver(observer);
      _client = client;

      final lifecycleProperties = <String, Object?>{
        'sdk': 'flutter',
        'platform': _platformName,
      };
      if (!(preferences.getBool(_installedKey) ?? false)) {
        await client.track('install', properties: lifecycleProperties);
        await client.track('first_open');
        await preferences.setBool(_installedKey, true);
      }
      await client.track('app_open', properties: lifecycleProperties);
      await client.track('session_start');
    } on Object {
      if (observer != null) WidgetsBinding.instance.removeObserver(observer);
      if (identical(_lifecycleObserver, observer)) _lifecycleObserver = null;
      if (identical(_client, client)) _client = null;
      await client.close();
      rethrow;
    }
  }

  // Remote push depends on Firebase, which most projects add only after their
  // first event has arrived. These helpers keep that dependency optional
  // during initialization instead of failing the whole SDK.
  static Future<void> _reportOptionalPushFailureAsync(
    NotifieErrorCallback? onError,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      onError?.call(_pushUnavailable(error));
    }
  }

  static NotifieException _pushUnavailable(Object error) => NotifieException(
        'Remote push is unavailable, so Notifie started without it. Events and '
        'local notifications still work. Add google-services.json (Android) or '
        'GoogleService-Info.plist (iOS), then call enableNotifications() to '
        'turn on remote push. Cause: $error',
      );

  static Future<void> identify(
    String userId, {
    NotifieProperties properties = const {},
  }) =>
      _requireClient().identify(userId, properties: properties);

  static Future<void> enableNotifications() =>
      _requireClient().enableNotifications();

  static Future<void> registerPushToken({
    required String token,
    required String platform,
    String provider = 'fcm',
  }) =>
      _requireClient().registerPushToken(
        PushToken(token: token, platform: platform, provider: provider),
      );

  static Future<void> track(
    String eventName, {
    NotifieProperties properties = const {},
  }) =>
      _requireClient().track(eventName, properties: properties);

  static Future<void> flush() => _requireClient().flush();

  static Future<void> reset() => _requireClient().reset();

  static Future<void> _trackSession() async {
    final client = _client;
    if (client == null) return;
    await client.track('app_open', properties: {
      'sdk': 'flutter',
      'platform': _platformName,
    });
    await client.track('session_start');
  }

  static NotifieClient _requireClient() {
    final client = _client;
    if (client == null) {
      throw StateError('Call Notifie.initialize() before using the SDK.');
    }

    return client;
  }

  static Future<void> _disposeCurrentClient() async {
    final observer = _lifecycleObserver;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
    _lifecycleObserver = null;
    await _client?.close();
    _client = null;
  }

  static String get _platformName {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  // Local notifications
  //
  // These require no API key, no network and no [initialize] call. The channel
  // delegates to the native Swift and Android schedulers rather than
  // reimplementing persistence or scheduling in Dart.

  static LocalNotificationChannel _localChannel = LocalNotificationChannel();

  /// Replaces the local notification channel. Tests only.
  @visibleForTesting
  static set localNotificationChannel(LocalNotificationChannel channel) {
    _localChannel = channel;
  }

  /// Schedules a local notification.
  ///
  /// Scheduling an id that is already pending replaces it, so calling this on
  /// every launch re-asserts a reminder rather than duplicating it.
  static Future<LocalScheduleResult> schedule(LocalNotification notification) =>
      _localChannel.schedule(notification);

  /// Cancels a pending local notification. Unknown ids are ignored.
  static Future<void> cancelScheduled(String id) => _localChannel.cancel(id);

  /// Local notifications this SDK scheduled that have not yet fired.
  static Future<List<PendingLocalNotification>> pendingScheduled() =>
      _localChannel.pending();

  /// What this device can actually do: permission state, exact-alarm
  /// availability, supported schedule kinds and pending capacity where the
  /// platform defines one.
  static Future<LocalNotificationCapabilities> notificationCapabilities() =>
      _localChannel.capabilities();

  /// Requests notification permission.
  ///
  /// Ask in product context. iOS shows this prompt once per install, so a
  /// denial is effectively permanent.
  static Future<LocalNotificationPermission> requestNotificationPermission() =>
      _localChannel.requestPermission();
}

final class _NotifieLifecycleObserver with WidgetsBindingObserver {
  _NotifieLifecycleObserver({
    required this.onForeground,
    required this.onBackground,
  });

  final Future<void> Function() onForeground;
  final Future<void> Function() onBackground;
  bool _wasBackgrounded = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          unawaited(onForeground());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _wasBackgrounded = true;
        unawaited(onBackground());
    }
  }
}
