import 'package:flutter/services.dart';

import 'local_notifications.dart';

/// The Dart side of the local notification bridge.
///
/// This class marshals and validates; it never schedules. Persistence, reboot
/// recovery and the platform trigger APIs live in the Swift and Android
/// implementations, and duplicating any of that here would create a second
/// engine to drift from the first.
final class LocalNotificationChannel {
  LocalNotificationChannel({MethodChannel? channel})
      : _channel = channel ??
            // The legacy channel name is retained deliberately: renaming it
            // would break hosts that registered the plugin before the rename,
            // and the name is an internal bridge detail rather than a brand.
            const MethodChannel('notifie_flutter/notifications');

  final MethodChannel _channel;

  /// Schedules a local notification.
  ///
  /// Validation runs in Dart first so a mistake is reported here, with a
  /// readable reason, rather than as an opaque platform exception.
  Future<LocalScheduleResult> schedule(LocalNotification notification) async {
    final invalid = notification.validate();
    if (invalid != null) {
      return LocalScheduleFailure(LocalScheduleError.invalidRequest, invalid);
    }

    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'scheduleLocalNotification',
        notification.toJson(),
      );
      if (response == null) {
        return const LocalScheduleFailure(
          LocalScheduleError.platformError,
          'no response from platform',
        );
      }

      final error = response['error'] as String?;
      if (error != null) {
        return LocalScheduleFailure(
          LocalScheduleError.fromCode(error),
          response['message'] as String?,
        );
      }

      final nextTrigger = response['nextTrigger'] as int?;
      return LocalScheduleSuccess(
        precision: LocalSchedulePrecision.fromCode(
          response['precision'] as String?,
        ),
        nextTrigger: nextTrigger == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(nextTrigger),
      );
    } on PlatformException catch (exception) {
      // A platform exception is a bridge failure, not a scheduling decision.
      // Classifying it as such keeps callers from treating an integration bug
      // as a user-permission problem.
      return LocalScheduleFailure(
        LocalScheduleError.fromCode(exception.code),
        exception.message,
      );
    } on MissingPluginException {
      return const LocalScheduleFailure(
        LocalScheduleError.platformError,
        'Notifie plugin is not registered on this platform',
      );
    }
  }

  /// Cancels a pending local notification. Unknown ids are ignored, so
  /// cancellation is idempotent and safe to call defensively.
  Future<void> cancel(String id) async {
    try {
      await _channel.invokeMethod<void>('cancelLocalNotification', {'id': id});
    } on MissingPluginException {
      // Nothing was scheduled if the plugin was never registered.
    }
  }

  /// Local notifications this SDK scheduled that have not yet fired.
  Future<List<PendingLocalNotification>> pending() async {
    try {
      final response = await _channel
          .invokeListMethod<Object?>('pendingLocalNotifications');
      if (response == null) return const [];
      return response
          .whereType<Map<Object?, Object?>>()
          .map((entry) {
            final next = entry['nextTrigger'] as int?;
            return PendingLocalNotification(
              id: entry['id']! as String,
              nextTrigger: next == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(next),
            );
          })
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    }
  }

  /// What this device can actually do.
  Future<LocalNotificationCapabilities> capabilities() async {
    try {
      final response = await _channel
          .invokeMapMethod<Object?, Object?>('localNotificationCapabilities');
      if (response != null) {
        return LocalNotificationCapabilities.fromJson(response);
      }
    } on MissingPluginException {
      // Fall through to the conservative default below.
    }

    // Reporting "nothing is available" is safer than claiming capabilities the
    // platform may not have: an application that adapts to a false negative
    // still works, one that trusts a false positive silently loses reminders.
    return const LocalNotificationCapabilities(
      permission: LocalNotificationPermission.notDetermined,
      canScheduleExactAlarms: false,
      supportedSchedules: {},
    );
  }

  /// Requests notification permission.
  ///
  /// Ask in product context rather than at launch: iOS shows this prompt once
  /// per install, so a denial is effectively permanent.
  Future<LocalNotificationPermission> requestPermission() async {
    try {
      final response =
          await _channel.invokeMethod<String>('requestNotificationPermission');
      return LocalNotificationPermission.fromCode(response);
    } on MissingPluginException {
      return LocalNotificationPermission.notDetermined;
    }
  }
}
