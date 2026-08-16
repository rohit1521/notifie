import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:notifie_flutter/notifie_flutter.dart';
import 'package:path_provider/path_provider.dart';

const _apiKey = String.fromEnvironment('NOTIFIE_API_KEY');
const _baseUrl = String.fromEnvironment(
  'NOTIFIE_BASE_URL',
  defaultValue: 'http://127.0.0.1:3000',
);
const _externalUserId = String.fromEnvironment(
  'NOTIFIE_EXTERNAL_USER_ID',
  defaultValue: 'flutter-example-user',
);
const _defaultEventName = String.fromEnvironment(
  'NOTIFIE_EVENT_NAME',
  defaultValue: 'post_liked',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(_runLocalCheckIfRequested());
  runApp(const NotifieExampleApp());
}

/// Exercises the real local notification bridge and prints the result.
///
/// Physical iOS devices cannot be driven from the command line the way `adb`
/// drives Android, and attaching the Dart VM service to a device is
/// unreliable. A build-time flag that reports to stdout makes device
/// verification repeatable:
///
/// ```bash
/// flutter build ios --debug --dart-define=NOTIFIE_LOCAL_CHECK=schedule
/// xcrun devicectl device process launch --console --device <id> <bundle>
/// ```
///
/// Nothing is faked: these calls cross the method channel into the native
/// scheduler, which is the half that unit tests cannot reach.
Future<void> _runLocalCheckIfRequested() async {
  const mode = String.fromEnvironment('NOTIFIE_LOCAL_CHECK');
  if (mode.isEmpty) return;

  final lines = <String>[];
  void report(String message) {
    debugPrint('NOTIFIE_CHECK $message');
    lines.add(message);
  }

  // Permission is requested last. Asking first would block this check on a
  // prompt nobody may be present to answer, and scheduling is accepted while
  // the decision is still pending.
  final capabilities = await Notifie.notificationCapabilities();
  // An empty set means the bridge fell back to its conservative default,
  // which would mean the native handler never answered.
  report('capabilities schedules=${capabilities.supportedSchedules.length} '
      'exact=${capabilities.canScheduleExactAlarms} '
      'capacity=${capabilities.pendingCapacity ?? 'unbounded'}');

  final scheduled = await Notifie.schedule(
    const LocalNotification(
      id: 'device-flutter',
      title: 'Flutter device check',
      body: 'Scheduled through the native scheduler with no account.',
      schedule: LocalScheduleAfter(Duration(seconds: 10)),
      deepLink: 'notifiedemo://local?id=device-flutter',
    ),
  );
  report('schedule=${_describe(scheduled)}');

  // The same id again must replace rather than accumulate.
  final replaced = await Notifie.schedule(
    const LocalNotification(
      id: 'device-flutter',
      title: 'Flutter device check (replaced)',
      body: 'Replacement kept the pending count at one.',
      schedule: LocalScheduleAfter(Duration(seconds: 12)),
    ),
  );
  report('reschedule=${_describe(replaced)}');

  final pending = await Notifie.pendingScheduled();
  report('pending=${pending.length} ${pending.map((e) => e.id).toList()}');

  final past = await Notifie.schedule(
    LocalNotification(
      id: 'device-flutter-past',
      title: 'Already past',
      body: 'Should not schedule.',
      schedule: LocalScheduleAt(DateTime.utc(2020)),
    ),
  );
  report('pastTimestamp=${_describe(past)}');

  // Written before the permission request: that prompt blocks until someone
  // answers it, and a check nobody can read is not a check.
  await _writeCheckResult(lines);

  final permission = await Notifie.requestNotificationPermission();
  report('permission=${permission.name}');
  await _writeCheckResult(lines);
}

/// Persists the check result.
///
/// Written to a file as well as the console. Flutter routes Dart output to
/// Flutter routes Dart output to the unified log rather than the process stdout
/// that `devicectl --console` streams, so on a physical iPhone a file is the
/// only readable channel.
Future<void> _writeCheckResult(List<String> lines) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/notifie-local-check.txt');
    await file.writeAsString(lines.join('\n'));
    debugPrint('NOTIFIE_CHECK wrote ${file.path}');
  } catch (error) {
    debugPrint('NOTIFIE_CHECK could not write result: $error');
  }
}

String _describe(LocalScheduleResult result) => switch (result) {
      LocalScheduleSuccess(:final precision) => 'ok(${precision.name})',
      LocalScheduleFailure(:final error) => 'failed(${error.name})',
    };

abstract interface class DemoSdk {
  Future<void> initialize({
    required void Function(NotifieNotification notification) onReceived,
    required void Function(NotifieNotification notification) onOpened,
  });

  Future<void> identify(String userId);

  Future<void> track(String eventName);

  Future<void> enableNotifications();

  Future<void> flush();

  Future<void> reset();

  // Local notifications. No API key, network or initialize() call required.

  Future<LocalScheduleResult> schedule(LocalNotification notification);

  Future<void> cancelScheduled(String id);

  Future<List<PendingLocalNotification>> pendingScheduled();

  Future<LocalNotificationCapabilities> notificationCapabilities();

  Future<LocalNotificationPermission> requestNotificationPermission();
}

final class ProductionDemoSdk implements DemoSdk {
  const ProductionDemoSdk();

  @override
  Future<void> initialize({
    required void Function(NotifieNotification notification) onReceived,
    required void Function(NotifieNotification notification) onOpened,
  }) {
    if (_apiKey.isEmpty) {
      throw StateError(
        'Launch with --dart-define=NOTIFIE_API_KEY=<ingest-key>.',
      );
    }
    return Notifie.initialize(
      apiKey: _apiKey,
      baseUrl: _baseUrl,
      onNotificationReceived: onReceived,
      onNotificationOpened: onOpened,
    );
  }

  @override
  Future<void> identify(String userId) => Notifie.identify(
    userId,
    properties: const {'sdk': 'flutter', 'example': true},
  );

  @override
  Future<void> track(String eventName) => Notifie.track(
    eventName,
    properties: const {'source': 'flutter_example'},
  );

  @override
  Future<void> enableNotifications() => Notifie.enableNotifications();

  @override
  Future<void> flush() => Notifie.flush();

  @override
  Future<void> reset() => Notifie.reset();

  @override
  Future<LocalScheduleResult> schedule(LocalNotification notification) =>
      Notifie.schedule(notification);

  @override
  Future<void> cancelScheduled(String id) => Notifie.cancelScheduled(id);

  @override
  Future<List<PendingLocalNotification>> pendingScheduled() =>
      Notifie.pendingScheduled();

  @override
  Future<LocalNotificationCapabilities> notificationCapabilities() =>
      Notifie.notificationCapabilities();

  @override
  Future<LocalNotificationPermission> requestNotificationPermission() =>
      Notifie.requestNotificationPermission();
}

class NotifieExampleApp extends StatelessWidget {
  const NotifieExampleApp({super.key, this.sdk = const ProductionDemoSdk()});

  final DemoSdk sdk;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Notifie Flutter',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Colors.white,
        ),
        cardTheme: const CardThemeData(
          margin: EdgeInsets.zero,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xFFDCE2EA)),
          ),
        ),
      ),
      home: NotifieHarness(sdk: sdk),
    );
  }
}

class NotifieHarness extends StatefulWidget {
  const NotifieHarness({super.key, required this.sdk});

  final DemoSdk sdk;

  @override
  State<NotifieHarness> createState() => _NotifieHarnessState();
}

class _NotifieHarnessState extends State<NotifieHarness> {
  final _userController = TextEditingController(text: _externalUserId);
  final _eventController = TextEditingController(text: _defaultEventName);
  bool _busy = false;
  bool _initialized = false;
  String _status = 'Not initialized';
  String _lastNotification = 'No notification received';

  @override
  void dispose() {
    _userController.dispose();
    _eventController.dispose();
    super.dispose();
  }

  Future<void> _run(String success, Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
      if (mounted) setState(() => _status = success);
    } on Object catch (error) {
      if (mounted) setState(() => _status = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _initialize() => _run('SDK initialized', () async {
    await widget.sdk.initialize(
      onReceived: (notification) =>
          _recordNotification('Received', notification),
      onOpened: (notification) => _recordNotification('Opened', notification),
    );
    _initialized = true;
  });

  void _recordNotification(String state, NotifieNotification notification) {
    if (!mounted) return;
    setState(() {
      _lastNotification = [
        state,
        notification.title,
        notification.deepLink?.toString(),
        notification.invocationId,
      ].whereType<String>().join(' · ');
    });
  }

  /// Schedules a one-shot reminder soon enough to observe while backgrounded.
  ///
  /// Never calls initialize(): local notifications must work without an API
  /// key, a network or an account. Run it in airplane mode to see that.
  Future<void> _scheduleLocalSoon() => _scheduleLocal(
        const LocalNotification(
          id: 'demo-soon',
          title: 'Ten seconds later',
          body: 'Scheduled locally with no account and no network.',
          schedule: LocalScheduleAfter(Duration(seconds: 10)),
          deepLink: 'notifiedemo://local?id=demo-soon',
        ),
      );

  Future<void> _scheduleLocalDaily() => _scheduleLocal(
        const LocalNotification(
          id: 'demo-daily',
          title: 'Daily practice',
          body: 'Repeats at 09:00 local time, including across DST.',
          schedule: LocalScheduleDaily(hour: 9, minute: 0),
        ),
      );

  Future<void> _scheduleLocal(LocalNotification notification) async {
    setState(() => _busy = true);
    // Asked in product context rather than at launch: iOS shows the prompt
    // once per install, so a denial is effectively permanent.
    await widget.sdk.requestNotificationPermission();
    final result = await widget.sdk.schedule(notification);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = switch (result) {
        // The granted precision, not the requested one.
        LocalScheduleSuccess(:final precision) =>
          'Scheduled ${notification.id} (${precision.name})',
        LocalScheduleFailure(:final error, :final message) =>
          'Not scheduled: ${error.name} ${message ?? ''}',
      };
    });
  }

  Future<void> _cancelLocal() async {
    // Cancelling an id that was never scheduled is harmless.
    await widget.sdk.cancelScheduled('demo-soon');
    await widget.sdk.cancelScheduled('demo-daily');
    final pending = await widget.sdk.pendingScheduled();
    if (!mounted) return;
    setState(() => _status = 'Cancelled (${pending.length} pending)');
  }

  Future<void> _showCapabilities() async {
    final capabilities = await widget.sdk.notificationCapabilities();
    if (!mounted) return;
    setState(() {
      _status = 'permission=${capabilities.permission.name} '
          'exact=${capabilities.canScheduleExactAlarms} '
          'capacity=${capabilities.pendingCapacity ?? 'unbounded'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifie Flutter'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFDCE2EA)),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusPanel(
              initialized: _initialized,
              busy: _busy,
              status: _status,
              baseUrl: _baseUrl,
            ),
            const SizedBox(height: 16),
            _Section(
              // Deliberately first and never gated on _initialized: local
              // notifications need no API key, no network and no account.
              title: 'Local notifications — no account needed',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('schedule_local'),
                    onPressed: _busy ? null : _scheduleLocalSoon,
                    icon: const Icon(Icons.alarm),
                    label: const Text('Remind me in 10 seconds'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('schedule_local_daily'),
                    onPressed: _busy ? null : _scheduleLocalDaily,
                    icon: const Icon(Icons.repeat),
                    label: const Text('Remind me daily at 09:00'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('cancel_local'),
                    onPressed: _busy ? null : _cancelLocal,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel local reminders'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('local_capabilities'),
                    onPressed: _busy ? null : _showCapabilities,
                    icon: const Icon(Icons.info_outline),
                    label: const Text('Show device capabilities'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: 'SDK lifecycle',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('initialize'),
                    onPressed: _busy ? null : _initialize,
                    icon: const Icon(Icons.power_settings_new),
                    label: const Text('Initialize SDK'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('user_id'),
                    controller: _userController,
                    decoration: const InputDecoration(
                      labelText: 'External user ID',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('identify'),
                    onPressed: !_initialized || _busy
                        ? null
                        : () => _run(
                            'User identified',
                            () => widget.sdk.identify(
                              _userController.text.trim(),
                            ),
                          ),
                    icon: const Icon(Icons.person_outline),
                    label: const Text('Identify user'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: 'Event pipeline',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('event_name'),
                    controller: _eventController,
                    decoration: const InputDecoration(labelText: 'Event name'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('track'),
                    onPressed: !_initialized || _busy
                        ? null
                        : () => _run(
                            'Event queued',
                            () =>
                                widget.sdk.track(_eventController.text.trim()),
                          ),
                    icon: const Icon(Icons.bolt_outlined),
                    label: const Text('Track event'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const ValueKey('flush'),
                    onPressed: !_initialized || _busy
                        ? null
                        : () => _run('Queue flushed', widget.sdk.flush),
                    icon: const Icon(Icons.sync),
                    label: const Text('Flush queue'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: 'Push notifications',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('notifications'),
                    onPressed: !_initialized || _busy
                        ? null
                        : () => _run(
                            'Notification permission and token registered',
                            widget.sdk.enableNotifications,
                          ),
                    icon: const Icon(Icons.notifications_outlined),
                    label: const Text('Enable notifications'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _lastNotification,
                    key: const ValueKey('last_notification'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              key: const ValueKey('reset'),
              onPressed: !_initialized || _busy
                  ? null
                  : () => _run('Identity and token reset', widget.sdk.reset),
              icon: const Icon(Icons.logout),
              label: const Text('Reset SDK identity'),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.initialized,
    required this.busy,
    required this.status,
    required this.baseUrl,
  });

  final bool initialized;
  final bool busy;
  final String status;
  final String baseUrl;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              initialized ? Icons.check_circle : Icons.radio_button_unchecked,
              color: initialized ? Colors.green.shade700 : Colors.blueGrey,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    busy ? 'Working…' : status,
                    key: const ValueKey('status'),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(baseUrl, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
