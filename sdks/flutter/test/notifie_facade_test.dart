import 'package:flutter_test/flutter_test.dart';
import 'package:notifie_flutter/notifie_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the static facade, which is the only surface a host app touches.
///
/// Every other suite builds a [NotifieClient] directly and injects a fake push
/// token provider. That is useful, but it means the provider the facade
/// actually constructs — `FirebasePushTokenProvider` — was never exercised, and
/// a hard Firebase requirement in `Notifie.initialize` could not be observed
/// here no matter how many client tests were added.
///
/// The test binding registers no Firebase plugin, so Firebase is genuinely
/// unavailable rather than stubbed to fail. That is the same condition as a
/// project without `google-services.json`, which is every project before its
/// first event arrives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('initializes and tracks events when Firebase is unavailable', () async {
    final errors = <Object>[];

    // A closed port: the queue must survive a failing transport too, and this
    // keeps the test off the network.
    await Notifie.initialize(
      apiKey: 'gk_test_facade',
      baseUrl: 'http://127.0.0.1:1',
      onError: errors.add,
    );

    // Guards against a vacuous pass. If Firebase ever did resolve in this
    // environment the test would prove nothing, so require the evidence that
    // the unavailable path was the one taken.
    expect(
      errors.map((error) => error.toString()),
      contains(contains('Remote push is unavailable')),
      reason: 'expected the optional-push failure that this test exists to '
          'tolerate; without it the assertions below are meaningless',
    );

    // The regression: this used to throw, and the failure handler tore the
    // client down, so no event was ever recorded.
    await Notifie.identify('user-42');
    await Notifie.track('purchase_completed', properties: {'amount': 9.99});
  });

  test('reports that remote push needs a Firebase configuration', () async {
    final errors = <Object>[];

    await Notifie.initialize(
      apiKey: 'gk_test_facade',
      baseUrl: 'http://127.0.0.1:1',
      onError: errors.add,
    );

    // The message has to name the missing file. "PlatformException(channel-
    // error)" sends a developer looking at their own code rather than at the
    // Firebase setup they have not done yet.
    final message = errors.map((error) => error.toString()).join('\n');
    expect(message, contains('google-services.json'));
    expect(message, contains('GoogleService-Info.plist'));
    expect(message, contains('enableNotifications()'));
  });

  test('explicitly enabling remote push still fails loudly', () async {
    await Notifie.initialize(
      apiKey: 'gk_test_facade',
      baseUrl: 'http://127.0.0.1:1',
      onError: (_) {},
    );

    // Tolerating the failure during initialize is only correct because asking
    // for push explicitly still reports it. Otherwise enabling push would
    // silently do nothing.
    await expectLater(Notifie.enableNotifications(), throwsA(isA<Object>()));
  });
}
