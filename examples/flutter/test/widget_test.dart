import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';
import 'package:notifie_flutter_example/main.dart';

void main() {
  testWidgets('drives the complete Notifie host workflow', (tester) async {
    // The harness scrolls on a real phone. Giving the test a surface tall
    // enough to hold it keeps these assertions about behaviour rather than
    // about scroll mechanics.
    await tester.binding.setSurfaceSize(const Size(1200, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sdk = FakeDemoSdk();
    await tester.pumpWidget(NotifieExampleApp(sdk: sdk));

    await tester.ensureVisible(find.byKey(const ValueKey('initialize')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('initialize')));
    await tester.pump();
    expect(sdk.initialized, isTrue);
    expect(find.text('SDK initialized'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('identify')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('identify')));
    await tester.pump();
    expect(sdk.userId, 'flutter-example-user');

    await tester.ensureVisible(find.byKey(const ValueKey('track')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('track')));
    await tester.pump();
    expect(sdk.events, ['post_liked']);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('notifications')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('notifications')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('notifications')));
    await tester.pump();
    expect(sdk.notificationsEnabled, isTrue);
    expect(find.textContaining('myapp://posts/post-7'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('flush')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('flush')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('flush')));
    await tester.pump();
    expect(sdk.flushCount, 1);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reset')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('reset')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reset')));
    await tester.pump();
    expect(sdk.resetCount, 1);
  });
}

final class FakeDemoSdk implements DemoSdk {
  bool initialized = false;
  bool notificationsEnabled = false;
  String? userId;
  final List<String> events = [];
  int flushCount = 0;
  int resetCount = 0;
  late void Function(NotifieNotification notification) _onOpened;

  @override
  Future<void> initialize({
    required void Function(NotifieNotification notification) onReceived,
    required void Function(NotifieNotification notification) onOpened,
  }) async {
    initialized = true;
    _onOpened = onOpened;
  }

  @override
  Future<void> identify(String userId) async {
    this.userId = userId;
  }

  @override
  Future<void> track(String eventName) async {
    events.add(eventName);
  }

  @override
  Future<void> enableNotifications() async {
    notificationsEnabled = true;
    _onOpened(const NotifieNotification(data: {
      'gk_invocation_id': 'inv-example',
      'gk_deep_link': 'myapp://posts/post-7',
    }));
  }

  @override
  Future<void> flush() async {
    flushCount += 1;
  }

  @override
  Future<void> reset() async {
    resetCount += 1;
  }

  // Local notifications. Recorded rather than scheduled: a widget test has no
  // platform to schedule against, and the real behaviour is verified by the
  // native suites and on-device runs.
  final List<LocalNotification> scheduled = [];
  final List<String> cancelled = [];

  @override
  Future<LocalScheduleResult> schedule(LocalNotification notification) async {
    final invalid = notification.validate();
    if (invalid != null) {
      return LocalScheduleFailure(LocalScheduleError.invalidRequest, invalid);
    }
    scheduled.add(notification);
    return const LocalScheduleSuccess(
      precision: LocalSchedulePrecision.inexact,
    );
  }

  @override
  Future<void> cancelScheduled(String id) async => cancelled.add(id);

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
  Future<LocalNotificationPermission> requestNotificationPermission() async =>
      LocalNotificationPermission.granted;
}
