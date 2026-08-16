import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

typedef NotifieProperties = Map<String, Object?>;
typedef NotifieNotificationCallback = void Function(
  NotifieNotification notification,
);
typedef NotifieErrorCallback = void Function(Object error);

final class PushToken {
  const PushToken({
    required this.token,
    required this.platform,
    required this.provider,
  });

  final String token;
  final String platform;
  final String provider;

  Map<String, Object?> toJson() => {
        'token': token,
        'platform': platform,
        'provider': provider,
      };

  factory PushToken.fromJson(Map<String, Object?> json) => PushToken(
        token: json['token'] as String,
        platform: json['platform'] as String,
        provider: json['provider'] as String,
      );
}

final class NotifieNotification {
  const NotifieNotification({
    required this.data,
    this.title,
    this.body,
  });

  final Map<String, Object?> data;
  final String? title;
  final String? body;

  String? get invocationId => data['gk_invocation_id'] as String?;

  Uri? get deepLink {
    final value = data['gk_deep_link'];
    return value is String ? Uri.tryParse(value) : null;
  }

  Uri? get imageUrl {
    final value = data['gk_image_url'];
    return value is String ? Uri.tryParse(value) : null;
  }

  NotifieProperties get analyticsProperties {
    final id = invocationId;
    return id == null ? const {} : {'invocation_id': id};
  }
}

abstract class PushTokenProvider {
  Future<void> prepare() async {}

  Future<void> notificationListenersAttached() async {}

  Future<PushToken?> enableNotifications();

  Stream<PushToken> get tokenRefreshes => const Stream<PushToken>.empty();

  Stream<NotifieNotification> get foregroundNotifications =>
      const Stream<NotifieNotification>.empty();

  Stream<NotifieNotification> get openedNotifications =>
      const Stream<NotifieNotification>.empty();

  Future<NotifieNotification?> initialNotification() async => null;
}

abstract interface class NotifieStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> remove(String key);
}

final class NotifieException implements Exception {
  const NotifieException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' ($statusCode)';
    return 'NotifieException$status: $message';
  }
}

final class NotifieClient {
  NotifieClient({
    required this.apiKey,
    required this.baseUrl,
    required http.Client httpClient,
    required PushTokenProvider pushTokenProvider,
    required NotifieStore store,
    String? anonymousId,
    this.batchSize = 20,
    this.maxQueueSize = 1000,
    this.flushInterval = const Duration(seconds: 30),
    this.retryBaseDelay = const Duration(seconds: 1),
    this.requestTimeout = const Duration(seconds: 15),
    this.autoFlushOnStart = true,
    this.onNotificationReceived,
    this.onNotificationOpened,
    this.onError,
    DateTime Function()? now,
    String Function()? messageIdFactory,
  })  : _httpClient = httpClient,
        _pushTokenProvider = pushTokenProvider,
        _store = store,
        _providedAnonymousId = anonymousId,
        _now = now ?? DateTime.now,
        _messageIdFactory = messageIdFactory ?? _uuidV4 {
    if (apiKey.trim().isEmpty) {
      throw const NotifieException('API key cannot be empty.');
    }
    if (batchSize < 1 || batchSize > _maxBatchSize) {
      throw const NotifieException('batchSize must be between 1 and 100.');
    }
    if (maxQueueSize < batchSize) {
      throw const NotifieException(
        'maxQueueSize must be greater than or equal to batchSize.',
      );
    }
  }

  static const _maxBatchSize = 100;
  static const _maxBackoff = Duration(minutes: 5);
  static const _anonymousIdKey = 'notifie.anonymous_id';
  static const _userIdKey = 'notifie.user_id';
  static const _queueKey = 'notifie.event_queue';
  static const _pendingIdentifyKey = 'notifie.pending_identify';
  static const _pushTokenKey = 'notifie.push_token';
  static const _retainedPushTokenKey = 'notifie.retained_push_token';
  static const _pushRegistrationSuspendedKey =
      'notifie.push_registration_suspended';
  static const _lastPushRegistrationKey = 'notifie.last_push_registration';
  static const _pendingRevocationsKey = 'notifie.pending_push_revocations';
  static final _eventNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _.:-]*$');

  final String apiKey;
  final Uri baseUrl;
  final int batchSize;
  final int maxQueueSize;
  final Duration flushInterval;
  final Duration retryBaseDelay;
  final Duration requestTimeout;
  final bool autoFlushOnStart;
  final NotifieNotificationCallback? onNotificationReceived;
  final NotifieNotificationCallback? onNotificationOpened;
  final NotifieErrorCallback? onError;
  final http.Client _httpClient;
  final PushTokenProvider _pushTokenProvider;
  final NotifieStore _store;
  final String? _providedAnonymousId;
  final DateTime Function() _now;
  final String Function() _messageIdFactory;

  final List<Map<String, Object?>> _pendingEvents = [];
  final Set<String> _inFlightEventIds = {};
  final Set<String> _receivedInvocationIds = {};
  final Set<String> _openedInvocationIds = {};
  final List<String> _pendingRevocations = [];
  String _anonymousId = '';
  String? _userId;
  Map<String, Object?>? _pendingIdentify;
  PushToken? _pushToken;
  PushToken? _retainedPushToken;
  bool _pushRegistrationSuspended = false;
  String? _lastPushRegistration;
  Timer? _flushTimer;
  Timer? _retryTimer;
  DateTime? _retryAt;
  int _retryAttempt = 0;
  Future<void>? _startFuture;
  Future<void>? _flushFuture;
  bool _flushRequested = false;
  Future<void> _queuePersistence = Future.value();
  Future<void> _pushStateChain = Future.value();
  StreamSubscription<PushToken>? _tokenRefreshSubscription;
  StreamSubscription<NotifieNotification>? _receivedSubscription;
  StreamSubscription<NotifieNotification>? _openedSubscription;
  bool _pushProviderAttached = false;
  bool _closed = false;

  String get anonymousId => _anonymousId;
  String? get userId => _userId;
  int get pendingEventCount => _pendingEvents.length;
  int get retryAttempt => _retryAttempt;

  Future<void> start() => _startFuture ??= _start();

  Future<void> _start() async {
    _anonymousId = _providedAnonymousId ??
        await _store.read(_anonymousIdKey) ??
        _messageIdFactory();
    await _store.write(_anonymousIdKey, _anonymousId);
    _userId = await _store.read(_userIdKey);
    _pendingEvents.addAll(await _readObjectList(_queueKey));
    _pendingIdentify = await _readObject(_pendingIdentifyKey);
    final storedPush = await _readObject(_pushTokenKey);
    if (storedPush != null) _pushToken = PushToken.fromJson(storedPush);
    final retainedPush = await _readObject(_retainedPushTokenKey);
    if (retainedPush != null) {
      _retainedPushToken = PushToken.fromJson(retainedPush);
    }
    _pushRegistrationSuspended =
        await _store.read(_pushRegistrationSuspendedKey) == 'true';
    _lastPushRegistration = await _store.read(_lastPushRegistrationKey);
    _pendingRevocations.addAll(await _readStringList(_pendingRevocationsKey));

    if (flushInterval > Duration.zero) {
      _flushTimer = Timer.periodic(flushInterval, (_) => _runDetached(flush()));
    }
    if (autoFlushOnStart) scheduleMicrotask(() => _runDetached(flush()));
  }

  Future<void> identify(
    String userId, {
    NotifieProperties properties = const {},
  }) =>
      _serializePushState(
        () => _identify(userId, properties: properties),
      );

  Future<void> _identify(
    String userId, {
    required NotifieProperties properties,
  }) async {
    await start();
    if (userId.trim().isEmpty || userId.length > 256) {
      throw const NotifieException('userId must contain 1-256 characters.');
    }
    _validateProperties(properties);
    _userId = userId;
    await _store.write(_userIdKey, userId);
    final retainedToken = _retainedPushToken;
    if (retainedToken != null) {
      _pushToken = retainedToken;
      _retainedPushToken = null;
      await _writeObject(_pushTokenKey, retainedToken.toJson());
      await _store.remove(_retainedPushTokenKey);
    }
    _pushRegistrationSuspended = false;
    await _store.remove(_pushRegistrationSuspendedKey);
    _pendingIdentify = {
      'userId': userId,
      'anonymousId': _anonymousId,
      'properties': properties,
      'timestamp': _timestamp(),
    };
    await _writeObject(_pendingIdentifyKey, _pendingIdentify!);
    _lastPushRegistration = null;
    await _store.remove(_lastPushRegistrationKey);
    await flush();
  }

  Future<void> track(
    String eventName, {
    NotifieProperties properties = const {},
  }) async {
    await start();
    _validateEventName(eventName);
    _validateProperties(properties);
    final event = <String, Object?>{
      'messageId': _messageIdFactory(),
      'anonymousId': _anonymousId,
      if (_userId != null) 'userId': _userId,
      'event': eventName,
      'timestamp': _timestamp(),
      'properties': properties,
    };
    _pendingEvents.add(event);
    while (_pendingEvents.length > maxQueueSize) {
      final dropIndex = _pendingEvents.indexWhere(
        (item) => !_inFlightEventIds.contains(item['messageId']),
      );
      if (dropIndex < 0) break;
      _pendingEvents.removeAt(dropIndex);
      _reportError(const NotifieException(
        'Event queue is full; dropped the oldest event not currently in flight.',
      ));
    }
    await _persistQueue();
    if (_pendingEvents.length >= batchSize) _runDetached(flush());
  }

  Future<void> enableNotifications() async {
    await start();
    final token = await _pushTokenProvider.enableNotifications();
    await attachPushProvider();
    if (token != null) await registerPushToken(token);
  }

  Future<void> attachPushProvider() async {
    if (_pushProviderAttached) return;
    _pushProviderAttached = true;
    await _pushTokenProvider.prepare();
    _tokenRefreshSubscription = _pushTokenProvider.tokenRefreshes.listen(
      (token) => _runDetached(_handleTokenRefresh(token)),
    );
    _receivedSubscription = _pushTokenProvider.foregroundNotifications.listen(
      (notification) => _runDetached(recordNotificationReceived(notification)),
    );
    _openedSubscription = _pushTokenProvider.openedNotifications.listen(
      (notification) => _runDetached(recordNotificationOpened(notification)),
    );
    await _pushTokenProvider.notificationListenersAttached();
    final initial = await _pushTokenProvider.initialNotification();
    if (initial != null) await recordNotificationOpened(initial);
  }

  Future<void> registerPushToken(PushToken token) =>
      _serializePushState(() => _registerPushToken(token));

  Future<void> _registerPushToken(PushToken token) async {
    await start();
    if (token.token.trim().isEmpty) return;
    _pushRegistrationSuspended = false;
    _retainedPushToken = null;
    _pushToken = token;
    _lastPushRegistration = null;
    await _writeObject(_pushTokenKey, token.toJson());
    await _store.remove(_retainedPushTokenKey);
    await _store.remove(_pushRegistrationSuspendedKey);
    await _store.remove(_lastPushRegistrationKey);
    await _flushPushToken();
  }

  Future<void> _handleTokenRefresh(PushToken token) =>
      _serializePushState(() => _handleTokenRefreshSerialized(token));

  Future<void> _handleTokenRefreshSerialized(PushToken token) async {
    await start();
    if (!_pushRegistrationSuspended) {
      await _registerPushToken(token);
      return;
    }
    _retainedPushToken = token;
    await _writeObject(_retainedPushTokenKey, token.toJson());
  }

  Future<void> flush() async {
    await start();
    final existing = _flushFuture;
    if (existing != null) {
      _flushRequested = true;
      return existing;
    }
    final future = _drainUntilIdle();
    _flushFuture = future;
    try {
      await future;
    } finally {
      if (identical(_flushFuture, future)) _flushFuture = null;
    }
  }

  Future<void> _drainUntilIdle() async {
    do {
      _flushRequested = false;
      await _drain();
    } while (_flushRequested && !_closed);
  }

  Future<void> _drain() async {
    if (_closed) return;
    final retryAt = _retryAt;
    if (retryAt != null && retryAt.isAfter(_now())) return;
    final revocationsFlushed = await _flushRevocations();
    await _flushEvents();
    await _flushIdentify();
    if (revocationsFlushed) await _flushPushToken();
  }

  Future<void> _flushEvents() async {
    while (_pendingEvents.isNotEmpty) {
      final batch = _pendingEvents.take(_maxBatchSize).toList(growable: false);
      final batchIds =
          batch.map((event) => event['messageId']).whereType<String>().toSet();
      _inFlightEventIds.addAll(batchIds);
      final result = await _request('POST', '/api/v1/events', {
        'events': batch,
        'sentAt': _timestamp(),
      });
      _inFlightEventIds.removeAll(batchIds);
      if (result.retryable) {
        _scheduleRetry();
        return;
      }
      _pendingEvents.removeWhere(
        (event) => batchIds.contains(event['messageId']),
      );
      await _persistQueue();
      _clearRetry();
    }
  }

  Future<void> _flushIdentify() async {
    final payload = _pendingIdentify;
    if (payload == null) return;
    final result = await _request('POST', '/api/v1/identify', payload);
    if (result.delivered || result.permanent) {
      if (identical(_pendingIdentify, payload)) {
        _pendingIdentify = null;
        await _store.remove(_pendingIdentifyKey);
      }
    } else {
      _scheduleRetry();
    }
  }

  Future<void> _flushPushToken() async {
    if (_pushRegistrationSuspended) return;
    final token = _pushToken;
    if (token == null) return;
    final fingerprint = '${token.token}:${_userId ?? ''}:$_anonymousId';
    if (_lastPushRegistration == fingerprint) return;
    final result = await _request('POST', '/api/v1/push-tokens', {
      'anonymousId': _anonymousId,
      if (_userId != null) 'userId': _userId,
      ...token.toJson(),
    });
    if (result.delivered) {
      final currentToken = _pushToken;
      final currentFingerprint = currentToken == null
          ? null
          : '${currentToken.token}:${_userId ?? ''}:$_anonymousId';
      if (currentFingerprint == fingerprint && !_pushRegistrationSuspended) {
        _lastPushRegistration = fingerprint;
        await _store.write(_lastPushRegistrationKey, fingerprint);
      }
    } else if (result.retryable) {
      _scheduleRetry();
    }
  }

  Future<bool> _flushRevocations() async {
    for (final token in List<String>.from(_pendingRevocations)) {
      final result = await _request('DELETE', '/api/v1/push-tokens', {
        'token': token,
      });
      if (!result.delivered) {
        if (result.retryable) _scheduleRetry();
        return false;
      }
      _pendingRevocations.remove(token);
      await _persistRevocations();
    }
    return true;
  }

  Future<void> reset() => _serializePushState(_reset);

  Future<void> _reset() async {
    await start();
    final inFlight = _flushFuture;
    if (inFlight != null) await inFlight;
    await _queuePersistence;
    final token = _pushToken?.token;
    if (token != null && !_pendingRevocations.contains(token)) {
      _pendingRevocations.add(token);
      await _persistRevocations();
    }
    final retainedToken = _pushToken ?? _retainedPushToken;
    _pendingEvents.clear();
    _pendingIdentify = null;
    _retainedPushToken = retainedToken;
    _pushToken = null;
    _pushRegistrationSuspended = true;
    _lastPushRegistration = null;
    _userId = null;
    _anonymousId = _messageIdFactory();
    await Future.wait([
      _store.remove(_queueKey),
      _store.remove(_pendingIdentifyKey),
      _store.remove(_pushTokenKey),
      if (retainedToken != null)
        _writeObject(_retainedPushTokenKey, retainedToken.toJson())
      else
        _store.remove(_retainedPushTokenKey),
      _store.write(_pushRegistrationSuspendedKey, 'true'),
      _store.remove(_lastPushRegistrationKey),
      _store.remove(_userIdKey),
      _store.write(_anonymousIdKey, _anonymousId),
    ]);
    await _flushRevocations();
  }

  Future<void> _serializePushState(
    Future<void> Function() operation,
  ) {
    final next = _pushStateChain.then<void>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    _pushStateChain = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  Future<void> recordNotificationReceived(
    NotifieNotification notification,
  ) async {
    final invocationId = notification.invocationId;
    if (invocationId != null && !_receivedInvocationIds.add(invocationId)) {
      return;
    }
    _trimInvocationIds(_receivedInvocationIds);
    await track(
      'notification_received',
      properties: notification.analyticsProperties,
    );
    onNotificationReceived?.call(notification);
    _runDetached(flush());
  }

  Future<void> recordNotificationOpened(
    NotifieNotification notification,
  ) async {
    final invocationId = notification.invocationId;
    if (invocationId != null && !_openedInvocationIds.add(invocationId)) return;
    _trimInvocationIds(_openedInvocationIds);
    await track(
      'notification_opened',
      properties: notification.analyticsProperties,
    );
    onNotificationOpened?.call(notification);
    _runDetached(flush());
  }

  void _trimInvocationIds(Set<String> values) {
    while (values.length > 256) {
      values.remove(values.first);
    }
  }

  Future<void> close() async {
    _closed = true;
    _flushTimer?.cancel();
    _retryTimer?.cancel();
    await Future.wait([
      if (_tokenRefreshSubscription != null)
        _tokenRefreshSubscription!.cancel(),
      if (_receivedSubscription != null) _receivedSubscription!.cancel(),
      if (_openedSubscription != null) _openedSubscription!.cancel(),
    ]);
    final inFlight = _flushFuture;
    if (inFlight != null) await inFlight;
    _httpClient.close();
  }

  Future<_HttpResult> _request(
    String method,
    String path,
    Map<String, Object?> payload,
  ) async {
    try {
      final headers = {
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json; charset=UTF-8',
      };
      final uri = _resolve(path);
      final body = jsonEncode(payload);
      final response = method == 'DELETE'
          ? await _httpClient
              .delete(uri, headers: headers, body: body)
              .timeout(requestTimeout)
          : await _httpClient
              .post(uri, headers: headers, body: body)
              .timeout(requestTimeout);
      return _HttpResult(response.statusCode);
    } on Object catch (error) {
      _reportError(error);
      return const _HttpResult(0);
    }
  }

  void _scheduleRetry() {
    if (_closed) return;
    if (_retryTimer?.isActive ?? false) return;
    _retryAttempt += 1;
    final factor = pow(2, _retryAttempt - 1).toDouble();
    final baseMilliseconds = retryBaseDelay.inMilliseconds * factor;
    final cappedMilliseconds = min(
      baseMilliseconds,
      _maxBackoff.inMilliseconds.toDouble(),
    );
    final jitter = 0.85 + Random().nextDouble() * 0.3;
    final delay = Duration(
      milliseconds: max(1, (cappedMilliseconds * jitter).round()),
    );
    _retryAt = _now().add(delay);
    _retryTimer = Timer(delay, () {
      _retryAt = null;
      _runDetached(flush());
    });
  }

  void _clearRetry() {
    _retryAttempt = 0;
    _retryAt = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<Map<String, Object?>?> _readObject(String key) async {
    final raw = await _store.read(key);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      return value is Map<String, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }

  Future<List<Map<String, Object?>>> _readObjectList(String key) async {
    final raw = await _store.read(key);
    if (raw == null) return [];
    try {
      final value = jsonDecode(raw);
      if (value is! List<Object?>) return [];
      return value.whereType<Map<String, Object?>>().toList();
    } on FormatException {
      return [];
    }
  }

  Future<List<String>> _readStringList(String key) async {
    final raw = await _store.read(key);
    if (raw == null) return [];
    try {
      final value = jsonDecode(raw);
      return value is List<Object?> ? value.whereType<String>().toList() : [];
    } on FormatException {
      return [];
    }
  }

  Future<void> _writeObject(String key, Map<String, Object?> value) =>
      _store.write(key, jsonEncode(value));

  Future<void> _persistQueue() {
    final encoded = _pendingEvents.isEmpty ? null : jsonEncode(_pendingEvents);
    Future<void> write() => encoded == null
        ? _store.remove(_queueKey)
        : _store.write(_queueKey, encoded);
    final next = _queuePersistence.then<void>(
      (_) => write(),
      onError: (Object _, StackTrace __) => write(),
    );
    _queuePersistence = next;
    return next;
  }

  Future<void> _persistRevocations() => _pendingRevocations.isEmpty
      ? _store.remove(_pendingRevocationsKey)
      : _store.write(_pendingRevocationsKey, jsonEncode(_pendingRevocations));

  void _validateEventName(String eventName) {
    if (eventName.isEmpty ||
        eventName.length > 64 ||
        !_eventNamePattern.hasMatch(eventName)) {
      throw const NotifieException(
        'Event name must start alphanumeric, be at most 64 characters, and contain only letters, numbers, spaces, _ . : -.',
      );
    }
  }

  void _validateProperties(NotifieProperties properties) {
    if (properties.length > 64) {
      throw const NotifieException('At most 64 properties are allowed.');
    }
    for (final entry in properties.entries) {
      if (entry.key.isEmpty || entry.key.length > 128) {
        throw const NotifieException(
          'Property keys must contain 1-128 characters.',
        );
      }
      final value = entry.value;
      if (value != null &&
          value is! String &&
          value is! num &&
          value is! bool) {
        throw const NotifieException(
          'Properties must be flat string, number, boolean, or null values.',
        );
      }
      if (value is String && value.length > 1024) {
        throw const NotifieException(
          'String property values must be at most 1024 characters.',
        );
      }
      if (value is num && !value.isFinite) {
        throw const NotifieException('Number properties must be finite.');
      }
    }
  }

  String _timestamp() => _now().toUtc().toIso8601String();

  Uri _resolve(String path) {
    final base = baseUrl.toString().replaceFirst(RegExp(r'/$'), '');
    return Uri.parse('$base$path');
  }

  void _runDetached(Future<void> future) {
    unawaited(future.catchError((Object error) {
      _reportError(error);
    }));
  }

  void _reportError(Object error) {
    try {
      onError?.call(error);
    } on Object {
      // Host diagnostics must never interrupt SDK lifecycle work.
    }
  }

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

final class _HttpResult {
  const _HttpResult(this.statusCode);

  final int statusCode;

  bool get delivered => statusCode >= 200 && statusCode < 300;
  bool get permanent =>
      statusCode >= 400 && statusCode < 500 && statusCode != 429;
  bool get retryable =>
      statusCode == 0 || statusCode == 429 || statusCode >= 500;
}
