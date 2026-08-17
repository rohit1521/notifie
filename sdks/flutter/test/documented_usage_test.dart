import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';

/// Compile-time guard for the usage published on notifie.dev, in the README,
/// and in the documentation.
///
/// These bodies are never executed — they need a real platform channel. Merely
/// declaring them is the point: if the public API drifts, this file stops
/// analyzing and the published snippets are known to be wrong. The website once
/// advertised `Notifie.scheduleAfter` and `Notifie.scheduleDaily`, neither of
/// which ever existed.
Future<void> documentedQuickstart(String apiKey, String orderId) async {
  await Notifie.initialize(apiKey: apiKey);
  await Notifie.enableNotifications();

  await Notifie.identify('user-42');
  await Notifie.track('order_shipped', properties: {'order_id': orderId});
}

Future<void> documentedLocalSchedules() async {
  await Notifie.schedule(
    const LocalNotification(
      id: 'daily-check-in',
      title: 'Daily check-in',
      body: 'Two minutes is enough.',
      schedule: LocalScheduleDaily(hour: 19, minute: 0),
    ),
  );

  await Notifie.schedule(
    const LocalNotification(
      id: 'still-working',
      title: 'Still working?',
      body: 'Pick up where you left off.',
      schedule: LocalScheduleAfter(Duration(hours: 2)),
    ),
  );

  await Notifie.cancelScheduled('daily-check-in');
  await Notifie.pendingScheduled();
}

void main() {
  test('documented usage resolves against the public API', () {
    expect(documentedQuickstart, isNotNull);
    expect(documentedLocalSchedules, isNotNull);
  });
}
