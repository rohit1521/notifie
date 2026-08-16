import 'package:shared_preferences/shared_preferences.dart';

import 'notifie_core.dart';

final class SharedPreferencesNotifieStore implements NotifieStore {
  const SharedPreferencesNotifieStore(this.preferences);

  final SharedPreferences preferences;

  @override
  Future<String?> read(String key) async => preferences.getString(key);

  @override
  Future<void> remove(String key) async {
    await preferences.remove(key);
  }

  @override
  Future<void> write(String key, String value) async {
    await preferences.setString(key, value);
  }
}
