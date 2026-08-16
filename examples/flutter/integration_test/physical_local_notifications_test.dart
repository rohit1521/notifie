import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';

/// Exercises the real local notification bridge on a physical device.
///
/// Unlike the widget tests, nothing here is faked: these calls cross the method
/// channel into the native Swift or Android scheduler. That is the whole point
/// — the Dart and native halves are individually tested, and this is the only
/// check that they agree.
///
/// Run with:
///   flutter test integration_test/physical_local_notifications_test.dart -d `device-id`
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    for (final id in ['device-flutter', 'device-flutter-daily']) {
      await Notifie.cancelScheduled(id);
    }
  });

  /// iOS keeps no pending requests until notification permission is granted:
  /// `add` succeeds but the request is discarded. Asserting the pending list
  /// without permission would fail for a platform reason rather than a defect,
  /// so those assertions are gated on the real authorisation state.
  Future<bool> permissionGranted() async {
    final capabilities = await Notifie.notificationCapabilities();
    return capabilities.permission == LocalNotificationPermission.granted;
  }

  testWidgets('schedules through the native scheduler with no account', (_) async {
    // Deliberately no initialize(): local notifications must not require an
    // API key, a base URL or a network.
    final result = await Notifie.schedule(
      const LocalNotification(
        id: 'device-flutter',
        title: 'Flutter device check',
        body: 'Scheduled through the native scheduler with no account.',
        schedule: LocalScheduleAfter(Duration(seconds: 10)),
        deepLink: 'notifiedemo://local?id=device-flutter',
      ),
    );

    expect(
      result,
      isA<LocalScheduleSuccess>(),
      reason: 'the native scheduler rejected a valid request: $result',
    );

    if (await permissionGranted()) {
      final pending = await Notifie.pendingScheduled();
      expect(pending.map((entry) => entry.id), contains('device-flutter'));
    }
  });

  testWidgets('replacing an id does not duplicate the notification', (_) async {
    await Notifie.schedule(
      const LocalNotification(
        id: 'device-flutter',
        title: 'First',
        body: 'Original body.',
        schedule: LocalScheduleAfter(Duration(seconds: 60)),
      ),
    );
    await Notifie.schedule(
      const LocalNotification(
        id: 'device-flutter',
        title: 'Second',
        body: 'Replacement body.',
        schedule: LocalScheduleAfter(Duration(seconds: 90)),
      ),
    );

    if (!await permissionGranted()) return;

    final pending = await Notifie.pendingScheduled();
    final matching = pending.where((entry) => entry.id == 'device-flutter');

    expect(
      matching.length,
      1,
      reason: 'scheduling the same id must replace rather than accumulate',
    );
  });

  testWidgets('cancellation is idempotent on the platform', (_) async {
    await Notifie.schedule(
      const LocalNotification(
        id: 'device-flutter',
        title: 'To cancel',
        body: 'Should never fire.',
        schedule: LocalScheduleAfter(Duration(seconds: 120)),
      ),
    );

    await Notifie.cancelScheduled('device-flutter');
    await Notifie.cancelScheduled('device-flutter');
    await Notifie.cancelScheduled('never-scheduled');

    final pending = await Notifie.pendingScheduled();
    expect(pending.map((entry) => entry.id), isNot(contains('device-flutter')));
  });

  testWidgets('a past timestamp is rejected rather than silently dropped', (_) async {
    final result = await Notifie.schedule(
      LocalNotification(
        id: 'device-flutter',
        title: 'Already past',
        body: 'Should not schedule.',
        schedule: LocalScheduleAt(DateTime.utc(2020)),
      ),
    );

    expect(result, isA<LocalScheduleFailure>());
    expect(
      (result as LocalScheduleFailure).error,
      LocalScheduleError.scheduleInPast,
    );
  });

  testWidgets('capabilities report what this device can actually do', (_) async {
    final capabilities = await Notifie.notificationCapabilities();

    // A real platform must report the schedule kinds it supports; an empty set
    // means the bridge fell back to its conservative default, which would mean
    // the native handler never answered.
    expect(
      capabilities.supportedSchedules,
      containsAll(<String>['at', 'after', 'daily', 'weekly']),
      reason: 'native capabilities were not returned across the bridge',
    );
  });
}
