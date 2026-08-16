import 'package:flutter/material.dart';
import 'package:notifie_flutter/notifie_flutter.dart';

const apiKey = String.fromEnvironment('NOTIFIE_API_KEY');
const baseUrl = String.fromEnvironment('NOTIFIE_BASE_URL');
const eventName = String.fromEnvironment('NOTIFIE_EVENT_NAME');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhysicalDeviceTestApp());
}

class PhysicalDeviceTestApp extends StatelessWidget {
  const PhysicalDeviceTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2563EB)),
      home: const PhysicalDeviceTestScreen(),
    );
  }
}

class PhysicalDeviceTestScreen extends StatefulWidget {
  const PhysicalDeviceTestScreen({super.key});

  @override
  State<PhysicalDeviceTestScreen> createState() =>
      _PhysicalDeviceTestScreenState();
}

class _PhysicalDeviceTestScreenState extends State<PhysicalDeviceTestScreen> {
  String status = 'Starting production SDK test...';
  bool running = true;
  bool passed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    setState(() {
      status = 'Sending $eventName...';
      running = true;
      passed = false;
    });

    final errors = <Object>[];
    try {
      await Notifie.initialize(
        apiKey: apiKey,
        baseUrl: baseUrl,
        batchSize: 100,
        flushInterval: Duration.zero,
        onError: errors.add,
      );
      await Notifie.identify(
        'flutter-physical-device',
        properties: const {'sdk': 'flutter', 'physical': true},
      );
      await Notifie.track(
        eventName,
        properties: const {'source': 'flutter_physical'},
      );
      await Notifie.flush();
      if (errors.isNotEmpty) throw StateError(errors.last.toString());

      if (!mounted) return;
      setState(() {
        status = 'Event sent';
        passed = true;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => status = error.toString());
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = passed ? Colors.green.shade700 : Colors.blue.shade700;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifie Flutter')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                passed ? Icons.check_circle : Icons.phone_iphone,
                color: color,
                size: 56,
              ),
              const SizedBox(height: 20),
              Text(
                status,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text(
                '$baseUrl\n$eventName',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: running ? null : _run,
                icon: const Icon(Icons.refresh),
                label: Text(running ? 'Running...' : 'Run again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
