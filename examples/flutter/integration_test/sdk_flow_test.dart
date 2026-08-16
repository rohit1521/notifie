import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';
import 'package:notifie_flutter_example/main.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('initialize, identify, track, enable push, flush, and reset', (
    tester,
  ) async {
    final sdk = _IntegrationSdk();
    await tester.pumpWidget(NotifieExampleApp(sdk: sdk));

    await tester.ensureVisible(find.byKey(const ValueKey('initialize')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('initialize')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('identify')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('identify')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('track')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('track')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('notifications')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('notifications')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notifications')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('flush')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('flush')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('flush')));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reset')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('reset')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reset')));
    await tester.pumpAndSettle();

    expect(sdk.calls, [
      'initialize',
      'identify:flutter-example-user',
      'track:post_liked',
      'notifications',
      'flush',
      'reset',
    ]);
    expect(find.textContaining('inv-integration'), findsOneWidget);
  });
}

final class _IntegrationSdk implements DemoSdk {
  final List<String> calls = [];
  late void Function(NotifieNotification notification) _onOpened;

  @override
  Future<void> initialize({
    required void Function(NotifieNotification notification) onReceived,
    required void Function(NotifieNotification notification) onOpened,
  }) async {
    calls.add('initialize');
    _onOpened = onOpened;
  }

  @override
  Future<void> identify(String userId) async {
    calls.add('identify:$userId');
  }

  @override
  Future<void> track(String eventName) async {
    calls.add('track:$eventName');
  }

  @override
  Future<void> enableNotifications() async {
    calls.add('notifications');
    _onOpened(
      const NotifieNotification(
        data: {
          'gk_invocation_id': 'inv-integration',
          'gk_deep_link': 'myapp://posts/post-7',
        },
      ),
    );
  }

  @override
  Future<void> flush() async {
    calls.add('flush');
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
  }

  // Local notifications. Recorded rather than scheduled: real behaviour is
  // verified by the native suites and on-device runs.
  final List<LocalNotification> scheduled = [];
  final List<String> cancelled = [];

  @override
  Future<LocalScheduleResult> schedule(LocalNotification notification) async {
    calls.add('schedule:${notification.id}');
    scheduled.add(notification);
    return const LocalScheduleSuccess(
      precision: LocalSchedulePrecision.inexact,
    );
  }

  @override
  Future<void> cancelScheduled(String id) async {
    calls.add('cancelScheduled:$id');
    cancelled.add(id);
  }

  @override
  Future<List<PendingLocalNotification>> pendingScheduled() async => scheduled
      .where((entry) => !cancelled.contains(entry.id))
      .map((entry) => PendingLocalNotification(id: entry.id))
      .toList();

  @override
  Future<LocalNotificationCapabilities> notificationCapabilities() async =>
      const LocalNotificationCapabilities(
        permission: LocalNotificationPermission.granted,
        canScheduleExactAlarms: false,
        supportedSchedules: {'at', 'after', 'daily', 'weekly'},
      );

  @override
  Future<LocalNotificationPermission> requestNotificationPermission() async {
    calls.add('requestNotificationPermission');
    return LocalNotificationPermission.granted;
  }
}
