import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/src/firebase_push_token_provider.dart';
import 'package:notifie_flutter/src/notifie_client.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('NotifieClient', () {
    test('persists a queued event and reuses its message ID after retry',
        () async {
      final bodies = <Map<String, Object?>>[];
      var status = 503;
      final store = _MemoryStore();
      final client = _client(
        store: store,
        handler: (request) async {
          bodies.add(_body(request));
          return Response('', status);
        },
      );

      await client.start();
      await client
          .track('notification_requested', properties: {'source': 'button'});
      await client.flush();

      expect(client.pendingEventCount, 1);
      expect(client.retryAttempt, 1);
      expect(store.values['notifie.event_queue'], isNotNull);

      status = 202;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await client.flush();

      final firstEvent = (bodies.first['events']! as List<Object?>).first
          as Map<String, Object?>;
      final retriedEvent = (bodies.last['events']! as List<Object?>).first
          as Map<String, Object?>;
      expect(retriedEvent['messageId'], firstEvent['messageId']);
      expect(retriedEvent['messageId'], '11111111-1111-4111-8111-111111111111');
      expect(client.pendingEventCount, 0);
      expect(store.values['notifie.event_queue'], isNull);
      await client.close();
    });

    test('reports transport exceptions and retains the event for retry',
        () async {
      final errors = <Object>[];
      final client = _client(
        store: _MemoryStore(),
        handler: (_) async => throw ClientException('offline'),
        onError: errors.add,
      );

      await client.start();
      await client.track('offline_event');
      await client.flush();

      expect(errors, hasLength(1));
      expect(errors.single, isA<ClientException>());
      expect(client.pendingEventCount, 1);
      expect(client.retryAttempt, 1);
      await client.close();
    });

    test('restores a persisted queue after restart', () async {
      final store = _MemoryStore();
      final offline =
          _client(store: store, handler: (_) async => Response('', 503));
      await offline.start();
      await offline.track('offline_event');
      await offline.close();

      late Map<String, Object?> sent;
      final restarted = _client(
        store: store,
        handler: (request) async {
          sent = _body(request);
          return Response('', 202);
        },
      );
      await restarted.start();
      expect(restarted.pendingEventCount, 1);
      await restarted.flush();

      final event =
          (sent['events']! as List<Object?>).single as Map<String, Object?>;
      expect(event['event'], 'offline_event');
      expect(event['messageId'], '11111111-1111-4111-8111-111111111111');
      await restarted.close();
    });

    test('identifies before registering the stored push token for that user',
        () async {
      final paths = <String>[];
      final bodies = <Map<String, Object?>>[];
      final client = _client(
        store: _MemoryStore(),
        pushProvider: _FakePushTokenProvider(
          const PushToken(
              token: 'fcm-token', platform: 'android', provider: 'fcm'),
        ),
        handler: (request) async {
          paths.add(request.url.path);
          bodies.add(_body(request));
          return Response('', 202);
        },
      );

      await client.start();
      await client.enableNotifications();
      paths.clear();
      bodies.clear();
      await client.identify('user-7', properties: {'plan': 'pro'});

      expect(paths, ['/api/v1/identify', '/api/v1/push-tokens']);
      expect(bodies.first, containsPair('userId', 'user-7'));
      expect(bodies.last, containsPair('userId', 'user-7'));
      await client.close();
    });

    test('revokes push token and rotates anonymous identity on reset',
        () async {
      final methods = <String>[];
      final paths = <String>[];
      var nextId = 0;
      final client = _client(
        store: _MemoryStore(),
        messageIdFactory: () {
          nextId += 1;
          return nextId == 1
              ? '11111111-1111-4111-8111-111111111111'
              : '22222222-2222-4222-8222-222222222222';
        },
        pushProvider: _FakePushTokenProvider(
          const PushToken(token: 'fcm-token', platform: 'ios', provider: 'fcm'),
        ),
        handler: (request) async {
          methods.add(request.method);
          paths.add(request.url.path);
          return Response('', 202);
        },
      );

      await client.start();
      final originalId = client.anonymousId;
      await client.enableNotifications();
      await client.reset();

      expect(methods, contains('DELETE'));
      expect(paths.last, '/api/v1/push-tokens');
      expect(client.userId, isNull);
      expect(client.anonymousId, isNot(originalId));
      await client.close();
    });

    test('re-identify restores the token revoked during reset', () async {
      final paths = <String>[];
      final bodies = <Map<String, Object?>>[];
      final client = _client(
        store: _MemoryStore(),
        pushProvider: _FakePushTokenProvider(
          const PushToken(
            token: 'fcm-login-token',
            platform: 'android',
            provider: 'fcm',
          ),
        ),
        handler: (request) async {
          paths.add(request.url.path);
          bodies.add(_body(request));
          return Response('', 202);
        },
      );

      await client.start();
      await client.enableNotifications();
      await client.reset();
      paths.clear();
      bodies.clear();

      await client.identify('user-after-login');

      expect(paths, ['/api/v1/identify', '/api/v1/push-tokens']);
      expect(bodies.last, containsPair('token', 'fcm-login-token'));
      expect(bodies.last, containsPair('userId', 'user-after-login'));
      await client.close();
    });

    test('token refresh cannot undo a concurrent reset', () async {
      final refreshes = StreamController<PushToken>.broadcast();
      final revocation = Completer<Response>();
      final calls = <Request>[];
      final client = _client(
        store: _MemoryStore(),
        pushProvider: _FakePushTokenProvider(
          const PushToken(
            token: 'original-token',
            platform: 'android',
            provider: 'fcm',
          ),
          refreshes: refreshes.stream,
        ),
        handler: (request) {
          calls.add(request);
          if (request.method == 'DELETE') return revocation.future;
          return Future.value(Response('', 202));
        },
      );

      await client.start();
      await client.attachPushProvider();
      await client.enableNotifications();
      final reset = client.reset();
      await Future<void>.delayed(Duration.zero);
      refreshes.add(
        const PushToken(
          token: 'refreshed-token',
          platform: 'android',
          provider: 'fcm',
        ),
      );
      revocation.complete(Response('', 200));
      await reset;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final registrationsAfterReset = calls.where(
        (request) =>
            request.method == 'POST' &&
            request.url.path == '/api/v1/push-tokens' &&
            _body(request)['token'] == 'refreshed-token',
      );
      expect(registrationsAfterReset, isEmpty);

      await client.identify('user-after-refresh');
      expect(
        calls.any(
          (request) =>
              request.method == 'POST' &&
              request.url.path == '/api/v1/push-tokens' &&
              _body(request)['token'] == 'refreshed-token',
        ),
        isTrue,
      );
      await refreshes.close();
      await client.close();
    });

    test('tracks notification engagement and forwards host callbacks',
        () async {
      final opened = StreamController<NotifieNotification>.broadcast();
      final sentEvents = <String>[];
      NotifieNotification? callbackNotification;
      final client = _client(
        store: _MemoryStore(),
        pushProvider: _FakePushTokenProvider(null, opened: opened.stream),
        onNotificationOpened: (notification) =>
            callbackNotification = notification,
        handler: (request) async {
          final body = _body(request);
          for (final item in body['events']! as List<Object?>) {
            sentEvents.add((item! as Map<String, Object?>)['event']! as String);
          }
          return Response('', 202);
        },
      );

      await client.start();
      await client.enableNotifications();
      opened.add(const NotifieNotification(data: {
        'gk_invocation_id': 'inv-9',
        'gk_deep_link': 'myapp://posts/7',
      }));
      await Future<void>.delayed(Duration.zero);
      await client.flush();

      expect(sentEvents, contains('notification_opened'));
      expect(callbackNotification?.invocationId, 'inv-9');
      expect(callbackNotification?.deepLink.toString(), 'myapp://posts/7');
      await opened.close();
      await client.close();
    });

    test('deduplicates receipt and open callbacks by invocation', () async {
      final sentEvents = <String>[];
      var messageSequence = 0;
      final client = _client(
        store: _MemoryStore(),
        messageIdFactory: () {
          messageSequence += 1;
          return '00000000-0000-4000-8000-${messageSequence.toString().padLeft(12, '0')}';
        },
        handler: (request) async {
          final body = _body(request);
          for (final item in body['events']! as List<Object?>) {
            sentEvents.add((item! as Map<String, Object?>)['event']! as String);
          }
          return Response('', 202);
        },
      );
      const notification = NotifieNotification(
        data: {'gk_invocation_id': 'duplicate-invocation'},
      );

      await client.start();
      await client.recordNotificationReceived(notification);
      await client.recordNotificationReceived(notification);
      await client.recordNotificationOpened(notification);
      await client.recordNotificationOpened(notification);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await client.flush();

      expect(
        sentEvents.where((event) => event == 'notification_received'),
        hasLength(1),
      );
      expect(
        sentEvents.where((event) => event == 'notification_opened'),
        hasLength(1),
      );
      await client.close();
    });

    test('prepares push provider before attaching cold-open listeners',
        () async {
      final provider = _OrderedPushTokenProvider();
      NotifieNotification? opened;
      final client = _client(
        store: _MemoryStore(),
        pushProvider: provider,
        onNotificationOpened: (notification) => opened = notification,
        handler: (_) async => Response('', 202),
      );

      await client.start();
      await client.attachPushProvider();

      expect(provider.calls,
          ['prepare', 'openedStream', 'listenersAttached', 'initial']);
      expect(opened?.invocationId, 'cold-open');
      await client.close();
    });

    test('reset waits for an in-flight flush before clearing the queue',
        () async {
      final response = Completer<Response>();
      final client = _client(
        store: _MemoryStore(),
        handler: (_) => response.future,
      );
      await client.start();
      await client.track('in_flight_event');

      final flush = client.flush();
      await Future<void>.delayed(Duration.zero);
      final reset = client.reset();
      expect(client.pendingEventCount, 1);

      response.complete(Response('', 202));
      await flush;
      await reset;

      expect(client.pendingEventCount, 0);
      await client.close();
    });

    test('rejects nested properties before enqueueing', () async {
      final client = _client(
          store: _MemoryStore(), handler: (_) async => Response('', 202));
      await client.start();

      expect(
        () => client.track('invalid', properties: {
          'nested': {'no': true}
        }),
        throwsA(isA<NotifieException>()),
      );
      expect(client.pendingEventCount, 0);
      await client.close();
    });
  });

  test('drains each persisted background notification once', () async {
    SharedPreferences.setMockInitialValues({
      'notifie.pending_background_notification.message-1': jsonEncode({
        'title': 'Background update 1',
        'body': null,
        'data': {
          'gk_invocation_id': 'inv-background-1',
          'refresh': 'true',
        },
      }),
      'notifie.pending_background_notification.message-2': jsonEncode({
        'title': 'Background update 2',
        'body': null,
        'data': {
          'gk_invocation_id': 'inv-background-2',
          'refresh': 'true',
        },
      }),
    });

    final notifications =
        await FirebasePushTokenProvider.pendingNotifications();
    final beforeAcknowledgement =
        await FirebasePushTokenProvider.pendingNotifications();
    for (final pending in notifications) {
      await FirebasePushTokenProvider.acknowledgePendingNotification(
        pending.key,
      );
    }
    final secondDrain = await FirebasePushTokenProvider.pendingNotifications();

    expect(notifications, hasLength(2));
    expect(beforeAcknowledgement, hasLength(2));
    expect(
      notifications.map((pending) => pending.notification.invocationId),
      ['inv-background-1', 'inv-background-2'],
    );
    expect(secondDrain, isEmpty);
  });

  test('retries attaching the push provider after a failed prepare', () async {
    final opened = StreamController<NotifieNotification>.broadcast();
    addTearDown(opened.close);
    final provider = _UnpreparedPushTokenProvider(opened: opened.stream);
    final requests = <Request>[];
    final client = _client(
      store: _MemoryStore(),
      pushProvider: provider,
      handler: (request) {
        requests.add(request);
        return Future.value(Response('', 202));
      },
    );

    await client.start();
    await expectLater(client.attachPushProvider(), throwsA(isA<Exception>()));
    expect(provider.prepareCalls, 1);

    // Adding google-services.json later must not be permanently ignored.
    provider.firebaseConfigured = true;
    await client.attachPushProvider();
    expect(provider.prepareCalls, 2);

    opened.add(
      const NotifieNotification(
        data: {'gk_invocation_id': 'inv-after-retry'},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await client.flush();

    final events = requests
        .where((request) => request.method == 'POST')
        .expand((request) => _events(request))
        .toList();
    expect(
      events.map((event) => event['event']),
      contains('notification_opened'),
      reason: 'listeners must be attached by the successful retry',
    );
  });
}

List<Map<String, Object?>> _events(Request request) {
  final body = _body(request);
  final events = body['events'];
  if (events is! List) return const [];
  return events.cast<Map<String, Object?>>();
}

NotifieClient _client({
  required _MemoryStore store,
  required Future<Response> Function(Request request) handler,
  PushTokenProvider? pushProvider,
  NotifieNotificationCallback? onNotificationOpened,
  NotifieErrorCallback? onError,
  String Function()? messageIdFactory,
}) {
  return NotifieClient(
    apiKey: 'sdk_test_key',
    baseUrl: Uri.parse('https://notifie.example'),
    anonymousId: 'device-123',
    httpClient: MockClient(handler),
    pushTokenProvider: pushProvider ?? _FakePushTokenProvider(null),
    store: store,
    flushInterval: Duration.zero,
    retryBaseDelay: const Duration(milliseconds: 1),
    autoFlushOnStart: false,
    messageIdFactory:
        messageIdFactory ?? () => '11111111-1111-4111-8111-111111111111',
    now: () => DateTime.utc(2026, 8, 9),
    onNotificationOpened: onNotificationOpened,
    onError: onError,
  );
}

Map<String, Object?> _body(Request request) =>
    jsonDecode(request.body) as Map<String, Object?>;

final class _MemoryStore implements NotifieStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

final class _FakePushTokenProvider extends PushTokenProvider {
  _FakePushTokenProvider(
    this.token, {
    Stream<NotifieNotification>? opened,
    Stream<PushToken>? refreshes,
  })  : _opened = opened ?? const Stream.empty(),
        _refreshes = refreshes ?? const Stream.empty();

  final PushToken? token;
  final Stream<NotifieNotification> _opened;
  final Stream<PushToken> _refreshes;

  @override
  Future<PushToken?> enableNotifications() async => token;

  @override
  Stream<NotifieNotification> get openedNotifications => _opened;

  @override
  Stream<PushToken> get tokenRefreshes => _refreshes;
}

/// Mirrors an Android project without google-services.json: prepare() fails
/// until Firebase is configured, then succeeds.
final class _UnpreparedPushTokenProvider extends PushTokenProvider {
  _UnpreparedPushTokenProvider({Stream<NotifieNotification>? opened})
      : _opened = opened ?? const Stream.empty();

  final Stream<NotifieNotification> _opened;
  int prepareCalls = 0;
  bool firebaseConfigured = false;

  @override
  Future<void> prepare() async {
    prepareCalls += 1;
    if (!firebaseConfigured) {
      throw const NotifieException('No Firebase App has been created.');
    }
  }

  @override
  Future<PushToken?> enableNotifications() async => null;

  @override
  Stream<NotifieNotification> get openedNotifications => _opened;
}

final class _OrderedPushTokenProvider extends PushTokenProvider {
  final List<String> calls = [];
  bool _prepared = false;

  @override
  Future<void> prepare() async {
    calls.add('prepare');
    _prepared = true;
  }

  @override
  Stream<NotifieNotification> get openedNotifications {
    if (!_prepared) throw StateError('Provider was not prepared.');
    calls.add('openedStream');
    return const Stream.empty();
  }

  @override
  Future<void> notificationListenersAttached() async {
    calls.add('listenersAttached');
  }

  @override
  Future<NotifieNotification?> initialNotification() async {
    calls.add('initial');
    return const NotifieNotification(
      data: {'gk_invocation_id': 'cold-open'},
    );
  }

  @override
  Future<PushToken?> enableNotifications() async => null;
}
