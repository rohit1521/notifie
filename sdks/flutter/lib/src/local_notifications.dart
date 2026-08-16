/// Local notifications.
///
/// These are scheduled and presented by the operating system on this device.
/// They need no API key, no network and no Notifie account.
///
/// This file defines the portable model and validates it before anything
/// crosses the method channel. Validating in Dart means a mistake is reported
/// with a useful message on the calling thread, rather than surfacing as an
/// opaque platform exception two layers down.
///
/// The scheduling itself is never implemented here: it delegates to the native
/// Swift and Android implementations, which own persistence, reboot recovery
/// and the platform trigger APIs. A second scheduling engine would drift from
/// the first, and the subtle parts — wall-clock recurrence, capacity limits —
/// are exactly where the drift would hide.
library;

import 'dart:convert';

/// Reserved identifier namespace.
///
/// Local notifications and Cloud pushes both become OS notifications with an
/// identifier. If those shared a space, cancelling a reminder could remove a
/// delivered Cloud notification and an open could be attributed to the wrong
/// one. Caller ids are prefixed natively, and ids claiming the prefix are
/// rejected so it cannot be forged.
const String kLocalNotificationIdNamespace = 'notifie.local.';

const int kMaxLocalNotificationIdLength = 64;
const int kMaxLocalNotificationTitleLength = 100;
const int kMaxLocalNotificationBodyLength = 250;
const int kMaxLocalCustomDataKeys = 20;
const int kMaxLocalCustomDataBytes = 4096;

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9._:-]+$');

/// When a local notification fires.
sealed class LocalSchedule {
  const LocalSchedule();

  Map<String, Object?> toJson();
}

/// Fires once at an absolute instant, regardless of later timezone changes.
final class LocalScheduleAt extends LocalSchedule {
  const LocalScheduleAt(this.timestamp);

  final DateTime timestamp;

  @override
  Map<String, Object?> toJson() => {
        'type': 'at',
        // ISO-8601 with an explicit offset: a bare local timestamp would be
        // reinterpreted by whichever platform parsed it.
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      other is LocalScheduleAt && other.timestamp == timestamp;

  @override
  int get hashCode => timestamp.hashCode;
}

/// Fires once after an interval measured from scheduling.
final class LocalScheduleAfter extends LocalSchedule {
  const LocalScheduleAfter(this.duration);

  final Duration duration;

  @override
  Map<String, Object?> toJson() => {
        'type': 'after',
        'seconds': duration.inSeconds,
      };

  @override
  bool operator ==(Object other) =>
      other is LocalScheduleAfter && other.duration == duration;

  @override
  int get hashCode => duration.hashCode;
}

/// Fires every day at a wall-clock time.
///
/// Wall clock rather than a fixed 24-hour interval: a 9am reminder must stay at
/// 9am across a daylight-saving change rather than drifting an hour and staying
/// there.
final class LocalScheduleDaily extends LocalSchedule {
  const LocalScheduleDaily({required this.hour, required this.minute});

  final int hour;
  final int minute;

  @override
  Map<String, Object?> toJson() => {
        'type': 'daily',
        'hour': hour,
        'minute': minute,
      };

  @override
  bool operator ==(Object other) =>
      other is LocalScheduleDaily &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);
}

/// Fires every week at a wall-clock time.
///
/// [weekday] follows ISO-8601 and `DateTime.weekday`: Monday is 1, Sunday is 7.
final class LocalScheduleWeekly extends LocalSchedule {
  const LocalScheduleWeekly({
    required this.weekday,
    required this.hour,
    required this.minute,
  });

  final int weekday;
  final int hour;
  final int minute;

  @override
  Map<String, Object?> toJson() => {
        'type': 'weekly',
        'weekday': weekday,
        'hour': hour,
        'minute': minute,
      };

  @override
  bool operator ==(Object other) =>
      other is LocalScheduleWeekly &&
      other.weekday == weekday &&
      other.hour == hour &&
      other.minute == minute;

  @override
  int get hashCode => Object.hash(weekday, hour, minute);
}

/// iOS-specific options, ignored on Android.
final class LocalNotificationIosOptions {
  const LocalNotificationIosOptions({
    this.threadId,
    this.categoryId,
    this.badge,
    this.sound,
  });

  final String? threadId;
  final String? categoryId;
  final int? badge;

  /// `null` uses the default sound, `false` is silent, a name plays a bundled
  /// file.
  final Object? sound;

  Map<String, Object?> toJson() => {
        if (threadId != null) 'threadId': threadId,
        if (categoryId != null) 'categoryId': categoryId,
        if (badge != null) 'badge': badge,
        if (sound != null) 'sound': sound,
      };
}

/// Android-specific options, ignored on iOS.
final class LocalNotificationAndroidOptions {
  const LocalNotificationAndroidOptions({
    this.channelId,
    this.exact = false,
    this.allowWhileIdle = false,
    this.groupKey,
  });

  final String? channelId;

  /// Requests exact delivery.
  ///
  /// Off by default: exact alarms need a user-visible permission on Android
  /// 12+ and are a scarce system resource. A denied request degrades to inexact
  /// and is reported through [LocalScheduleResult.precision] rather than
  /// failing.
  final bool exact;

  /// Fires during Doze. Reserve for user-critical alarms.
  final bool allowWhileIdle;

  final String? groupKey;

  Map<String, Object?> toJson() => {
        if (channelId != null) 'channelId': channelId,
        'exact': exact,
        'allowWhileIdle': allowWhileIdle,
        if (groupKey != null) 'groupKey': groupKey,
      };
}

/// A local notification to schedule.
final class LocalNotification {
  const LocalNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.schedule,
    this.deepLink,
    this.customData = const {},
    this.ios,
    this.android,
  });

  /// Caller-owned, stable identity. Scheduling the same id replaces the pending
  /// notification rather than adding a second one, which is what makes
  /// scheduling safe to retry.
  final String id;
  final String title;
  final String body;
  final LocalSchedule schedule;

  /// Delivered to the notification-open handler. The SDK never opens it.
  final String? deepLink;

  /// String-only, matching the remote contract. Platform payloads are string
  /// dictionaries, so richer values would mean each SDK inventing an encoding.
  final Map<String, String> customData;

  final LocalNotificationIosOptions? ios;
  final LocalNotificationAndroidOptions? android;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'schedule': schedule.toJson(),
        if (deepLink != null) 'deepLink': deepLink,
        'customData': customData,
        if (ios != null) 'ios': ios!.toJson(),
        if (android != null) 'android': android!.toJson(),
      };

  /// Returns why this notification is invalid, or null when it is acceptable.
  ///
  /// Mirrors `packages/contracts` and the native implementations so every
  /// Notifie SDK rejects the same input for the same reason.
  String? validate() {
    if (id.isEmpty || id.length > kMaxLocalNotificationIdLength) {
      return 'id must be 1-$kMaxLocalNotificationIdLength characters';
    }
    if (id.startsWith(kLocalNotificationIdNamespace)) {
      return 'id must not start with the reserved '
          '"$kLocalNotificationIdNamespace" namespace';
    }
    if (!_idPattern.hasMatch(id)) {
      return 'id may contain only letters, digits, dot, underscore, colon '
          'or hyphen';
    }
    if (title.isEmpty || title.length > kMaxLocalNotificationTitleLength) {
      return 'title must be 1-$kMaxLocalNotificationTitleLength characters';
    }
    if (body.isEmpty || body.length > kMaxLocalNotificationBodyLength) {
      return 'body must be 1-$kMaxLocalNotificationBodyLength characters';
    }
    if (customData.length > kMaxLocalCustomDataKeys) {
      return 'at most $kMaxLocalCustomDataKeys custom data fields';
    }
    if (customData.keys.any((key) => key.startsWith('gk_'))) {
      return 'custom data must not use the reserved gk_ prefix';
    }
    // Measured in UTF-8 because the platform payload budget is bytes. A
    // character count passes for text the platform then refuses to store,
    // which emoji and non-Latin scripts hit first.
    if (utf8.encode(jsonEncode(customData)).length > kMaxLocalCustomDataBytes) {
      return 'custom data must be at most 4 KB';
    }

    final schedule = this.schedule;
    switch (schedule) {
      case LocalScheduleAfter(:final duration):
        if (duration.inSeconds < 1) {
          return 'interval must be at least 1 second';
        }
      case LocalScheduleDaily(:final hour, :final minute):
        return _timeError(hour, minute);
      case LocalScheduleWeekly(:final weekday, :final hour, :final minute):
        if (weekday < 1 || weekday > 7) {
          return 'weekday must be 1-7 with Monday as 1';
        }
        return _timeError(hour, minute);
      case LocalScheduleAt():
        break;
    }
    return null;
  }

  static String? _timeError(int hour, int minute) {
    if (hour < 0 || hour > 23) return 'hour must be 0-23';
    if (minute < 0 || minute > 59) return 'minute must be 0-59';
    return null;
  }
}

/// Why a local notification could not be scheduled.
///
/// Stable across platforms so host code branches on the cause rather than
/// parsing a message. Each case needs a different response: a denied permission
/// is a product problem, a full queue is a scheduling-strategy problem, and an
/// invalid request is a programming error.
enum LocalScheduleError {
  invalidRequest,
  permissionDenied,
  scheduleInPast,

  /// iOS keeps only the 64 soonest pending notifications and silently discards
  /// the rest.
  capacityExceeded,

  platformError;

  static LocalScheduleError fromCode(String code) => switch (code) {
        'invalid_request' => LocalScheduleError.invalidRequest,
        'permission_denied' => LocalScheduleError.permissionDenied,
        'schedule_in_past' => LocalScheduleError.scheduleInPast,
        'capacity_exceeded' => LocalScheduleError.capacityExceeded,
        _ => LocalScheduleError.platformError,
      };
}

/// Delivery precision actually granted, which may be less than requested.
enum LocalSchedulePrecision {
  exact,
  inexact;

  static LocalSchedulePrecision fromCode(String? code) =>
      code == 'exact' ? LocalSchedulePrecision.exact : LocalSchedulePrecision.inexact;
}

/// The outcome of a scheduling attempt.
sealed class LocalScheduleResult {
  const LocalScheduleResult();
}

final class LocalScheduleSuccess extends LocalScheduleResult {
  const LocalScheduleSuccess({
    required this.precision,
    this.nextTrigger,
  });

  /// What the platform actually granted. Never assume the request succeeded as
  /// asked: Android downgrades exact alarms without the 12+ permission.
  final LocalSchedulePrecision precision;

  /// Absent when the platform owns the next date for a recurring schedule.
  final DateTime? nextTrigger;
}

final class LocalScheduleFailure extends LocalScheduleResult {
  const LocalScheduleFailure(this.error, [this.message]);

  final LocalScheduleError error;
  final String? message;

  @override
  String toString() => 'LocalScheduleFailure(${error.name}, $message)';
}

/// A scheduled notification awaiting delivery.
final class PendingLocalNotification {
  const PendingLocalNotification({required this.id, this.nextTrigger});

  final String id;
  final DateTime? nextTrigger;
}

/// What this device can actually do.
///
/// Queryable so an application can adapt before scheduling, rather than
/// discovering a platform limit from a user who never received a reminder.
final class LocalNotificationCapabilities {
  const LocalNotificationCapabilities({
    required this.permission,
    required this.canScheduleExactAlarms,
    required this.supportedSchedules,
    this.pendingCapacity,
  });

  final LocalNotificationPermission permission;

  /// Android 12+ gates exact alarms behind a user-visible permission. Always
  /// true on iOS, where scheduling precision is not separately permissioned.
  final bool canScheduleExactAlarms;

  final Set<String> supportedSchedules;

  /// Maximum pending notifications, where the platform defines one. iOS keeps
  /// 64; Android has no fixed documented limit, so this is null there.
  final int? pendingCapacity;

  static LocalNotificationCapabilities fromJson(Map<Object?, Object?> json) =>
      LocalNotificationCapabilities(
        permission: LocalNotificationPermission.fromCode(
          json['permission'] as String?,
        ),
        canScheduleExactAlarms: json['canScheduleExactAlarms'] as bool? ?? false,
        supportedSchedules: ((json['supportedSchedules'] as List<Object?>?) ?? const [])
            .map((value) => value.toString())
            .toSet(),
        pendingCapacity: json['pendingCapacity'] as int?,
      );
}

/// Notification permission state.
enum LocalNotificationPermission {
  /// Never asked. The prompt has not been shown, so asking can still succeed.
  notDetermined,
  granted,

  /// Refused. On iOS the prompt will not be shown again, so this is effectively
  /// permanent and the application must degrade rather than retry.
  denied,
  provisional;

  static LocalNotificationPermission fromCode(String? code) => switch (code) {
        'granted' => LocalNotificationPermission.granted,
        'denied' => LocalNotificationPermission.denied,
        'provisional' => LocalNotificationPermission.provisional,
        _ => LocalNotificationPermission.notDetermined,
      };
}

/// Resolves the next firing instant, or null for a one-shot already past.
///
/// Kept alongside the contract so Dart callers can preview a schedule without a
/// platform round trip, and so the boundary cases are asserted in Dart tests
/// against the same expectations as the TypeScript and native suites.
///
/// The native implementations remain authoritative for actual delivery.
DateTime? nextLocalOccurrence(LocalSchedule schedule, DateTime from) {
  switch (schedule) {
    case LocalScheduleAt(:final timestamp):
      return timestamp.isAfter(from) ? timestamp : null;
    case LocalScheduleAfter(:final duration):
      return from.add(duration);
    case LocalScheduleDaily(:final hour, :final minute):
      var next = DateTime(from.year, from.month, from.day, hour, minute);
      if (!next.isAfter(from)) {
        // Constructing the next calendar day rather than adding 24 hours: a
        // fixed interval drifts by an hour at a daylight-saving boundary and
        // stays there.
        next = DateTime(from.year, from.month, from.day + 1, hour, minute);
      }
      return next;
    case LocalScheduleWeekly(:final weekday, :final hour, :final minute):
      final candidate = DateTime(from.year, from.month, from.day, hour, minute);
      var delta = weekday - candidate.weekday;
      if (delta < 0) delta += 7;
      if (delta == 0 && !candidate.isAfter(from)) delta = 7;
      return DateTime(from.year, from.month, from.day + delta, hour, minute);
  }
}
