import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';

LocalNotification reminder({
  String id = 'daily-reminder',
  String title = 'Time to practise',
  String body = 'Your streak is waiting.',
  LocalSchedule? schedule,
  String? deepLink,
  Map<String, String> customData = const {},
}) =>
    LocalNotification(
      id: id,
      title: title,
      body: body,
      schedule: schedule ?? const LocalScheduleDaily(hour: 9, minute: 0),
      deepLink: deepLink,
      customData: customData,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validation', () {
    test('accepts a minimal daily reminder', () {
      expect(reminder().validate(), isNull);
    });

    test('rejects an id claiming the reserved namespace', () {
      expect(
        reminder(id: '${kLocalNotificationIdNamespace}spoofed').validate(),
        contains('reserved'),
      );
    });

    test('rejects ids that cannot survive the Android integer mapping', () {
      for (final id in ['has space', 'has/slash', '']) {
        expect(reminder(id: id).validate(), isNotNull, reason: 'id "$id"');
      }
    });

    test('rejects the reserved remote data prefix', () {
      expect(
        reminder(customData: {'gk_invocation_id': 'stolen'}).validate(),
        contains('gk_'),
      );
    });

    test('measures the custom data budget in UTF-8 bytes', () {
      // 1400 three-byte characters passes any character-count limit but
      // exceeds the 4 KB byte budget.
      final wide = {'note': '한' * 1400};
      expect(reminder(customData: wide).validate(), contains('4 KB'));
    });

    test('rejects an out-of-range weekday', () {
      expect(
        reminder(schedule: const LocalScheduleWeekly(weekday: 8, hour: 9, minute: 0))
            .validate(),
        contains('weekday'),
      );
    });

    test('rejects a sub-second interval', () {
      expect(
        reminder(schedule: const LocalScheduleAfter(Duration.zero)).validate(),
        contains('at least 1 second'),
      );
    });
  });

  group('serialization', () {
    test('absolute schedules carry an explicit offset', () {
      final json = LocalScheduleAt(
        DateTime.utc(2026, 3, 10, 18, 30),
      ).toJson();

      // Without an offset the platform would reinterpret the instant in its
      // own timezone.
      expect(json['timestamp'], '2026-03-10T18:30:00.000Z');
    });

    test('schedules are tagged so the native side can discriminate', () {
      expect(const LocalScheduleDaily(hour: 9, minute: 0).toJson()['type'], 'daily');
      expect(
        const LocalScheduleWeekly(weekday: 3, hour: 9, minute: 0).toJson()['type'],
        'weekly',
      );
      expect(const LocalScheduleAfter(Duration(seconds: 90)).toJson()['seconds'], 90);
    });
  });

  group('nextLocalOccurrence', () {
    final noon = DateTime(2026, 3, 10, 12);

    test('returns null for an absolute time already past', () {
      expect(
        nextLocalOccurrence(LocalScheduleAt(DateTime(2020, 1, 1)), noon),
        isNull,
      );
    });

    test('moves a daily time that already passed today to tomorrow', () {
      final next = nextLocalOccurrence(
        const LocalScheduleDaily(hour: 9, minute: 0),
        noon,
      );
      expect(next, DateTime(2026, 3, 11, 9));
    });

    test('keeps a daily time still ahead today on today', () {
      final next = nextLocalOccurrence(
        const LocalScheduleDaily(hour: 18, minute: 30),
        noon,
      );
      expect(next, DateTime(2026, 3, 10, 18, 30));
    });

    test('schedules a weekly slot later this week without skipping a week', () {
      // 10 March 2026 is a Tuesday; Thursday is two days later.
      final next = nextLocalOccurrence(
        const LocalScheduleWeekly(weekday: 4, hour: 9, minute: 0),
        noon,
      );
      expect(next, DateTime(2026, 3, 12, 9));
    });

    test('rolls a weekly slot that already passed today to next week', () {
      final next = nextLocalOccurrence(
        const LocalScheduleWeekly(weekday: 2, hour: 9, minute: 0),
        noon,
      );
      expect(next, DateTime(2026, 3, 17, 9));
    });

    test('treats Sunday as ISO weekday 7', () {
      final next = nextLocalOccurrence(
        const LocalScheduleWeekly(weekday: 7, hour: 9, minute: 0),
        noon,
      );
      expect(next, DateTime(2026, 3, 15, 9));
      expect(next!.weekday, DateTime.sunday);
    });

    test('builds recurring slots from calendar components, not fixed offsets', () {
      // Constructing the next calendar day is what keeps a wall-clock reminder
      // stable across a daylight-saving transition; adding 24 hours would not.
      final next = nextLocalOccurrence(
        const LocalScheduleDaily(hour: 9, minute: 0),
        DateTime(2026, 3, 7, 20),
      );
      expect(next!.hour, 9);
      expect(next.day, 8);
    });
  });

  group('channel', () {
    const channelName = 'notifie_flutter/notifications';
    late List<MethodCall> calls;

    void mock(Future<Object?>? Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), (call) {
        calls.add(call);
        return handler(call);
      });
    }

    setUp(() => calls = []);

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), null);
    });

    test('invalid content never reaches the platform', () async {
      mock((_) async => <Object?, Object?>{});
      final channel = LocalNotificationChannel();

      final result = await channel.schedule(reminder(id: 'has space'));

      // Validating in Dart gives a readable reason on the calling thread
      // instead of an opaque platform exception.
      expect(result, isA<LocalScheduleFailure>());
      expect((result as LocalScheduleFailure).error, LocalScheduleError.invalidRequest);
      expect(calls, isEmpty);
    });

    test('a scheduled notification reports the granted precision', () async {
      mock((_) async => <Object?, Object?>{
            'precision': 'inexact',
            'nextTrigger': 1772100000000,
          });

      final result = await LocalNotificationChannel().schedule(reminder());

      expect(result, isA<LocalScheduleSuccess>());
      final success = result as LocalScheduleSuccess;
      expect(success.precision, LocalSchedulePrecision.inexact);
      expect(success.nextTrigger, isNotNull);
      expect(calls.single.method, 'scheduleLocalNotification');
    });

    test('platform error codes map to stable cross-platform errors', () async {
      for (final entry in {
        'permission_denied': LocalScheduleError.permissionDenied,
        'capacity_exceeded': LocalScheduleError.capacityExceeded,
        'schedule_in_past': LocalScheduleError.scheduleInPast,
        'invalid_request': LocalScheduleError.invalidRequest,
        'something_unknown': LocalScheduleError.platformError,
      }.entries) {
        mock((_) async => <Object?, Object?>{'error': entry.key});
        final result = await LocalNotificationChannel().schedule(reminder());
        expect(
          (result as LocalScheduleFailure).error,
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('a platform exception is reported, not thrown at the caller', () async {
      mock((_) async => throw PlatformException(code: 'permission_denied'));

      final result = await LocalNotificationChannel().schedule(reminder());

      expect((result as LocalScheduleFailure).error, LocalScheduleError.permissionDenied);
    });

    test('cancel is forwarded and tolerates unknown ids', () async {
      mock((_) async => null);

      await LocalNotificationChannel().cancel('never-scheduled');

      expect(calls.single.method, 'cancelLocalNotification');
      expect((calls.single.arguments as Map)['id'], 'never-scheduled');
    });

    test('pending notifications are decoded', () async {
      mock((_) async => <Object?>[
            <Object?, Object?>{'id': 'streak', 'nextTrigger': 1772100000000},
            <Object?, Object?>{'id': 'weekly'},
          ]);

      final pending = await LocalNotificationChannel().pending();

      expect(pending.map((entry) => entry.id), ['streak', 'weekly']);
      expect(pending.first.nextTrigger, isNotNull);
      // A recurring schedule whose next date the platform owns.
      expect(pending.last.nextTrigger, isNull);
    });

    test('capabilities expose platform limits', () async {
      mock((_) async => <Object?, Object?>{
            'permission': 'granted',
            'canScheduleExactAlarms': false,
            'supportedSchedules': <Object?>['at', 'after', 'daily', 'weekly'],
            'pendingCapacity': 64,
          });

      final capabilities = await LocalNotificationChannel().capabilities();

      expect(capabilities.permission, LocalNotificationPermission.granted);
      expect(capabilities.canScheduleExactAlarms, isFalse);
      expect(capabilities.supportedSchedules, contains('weekly'));
      expect(capabilities.pendingCapacity, 64);
    });

    test('a missing plugin degrades to no capabilities rather than throwing', () async {
      // Claiming capabilities the platform may not have is the dangerous
      // direction: an app trusting a false positive loses reminders silently.
      final capabilities = await LocalNotificationChannel().capabilities();

      expect(capabilities.permission, LocalNotificationPermission.notDetermined);
      expect(capabilities.canScheduleExactAlarms, isFalse);
      expect(capabilities.supportedSchedules, isEmpty);
    });
  });
}
