import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';
import 'package:integration_test/integration_test.dart';

const apiKey = String.fromEnvironment('NOTIFIE_API_KEY');
const baseUrl = String.fromEnvironment('NOTIFIE_BASE_URL');
const eventName = String.fromEnvironment('NOTIFIE_EVENT_NAME');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sends a real event through the production SDK', (_) async {
    expect(apiKey, isNotEmpty);
    expect(baseUrl, isNotEmpty);
    expect(eventName, isNotEmpty);
    final errors = <Object>[];

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

    expect(errors, isEmpty);
  });
}