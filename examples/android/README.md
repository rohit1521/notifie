# Notifie Android device test

This app consumes the local `sdks/android/notifie` module and exercises the
same public API shown in the dashboard:

```kotlin
Notifie.initialize(applicationContext, apiKey)
Notifie.enableNotifications()
Notifie.track("notifie_test_notification")
```

Before building, add the Firebase Android app configuration at
`app/google-services.json`. Keep it local; the repository ignores it.

For a USB-connected device, expose the local dashboard and build with an SDK
ingest key:

```sh
adb reverse tcp:3000 tcp:3000
./gradlew :app:installDebug \
  -PNOTIFIE_API_KEY="$NOTIFIE_API_KEY" \
  -PNOTIFIE_BASE_URL=http://127.0.0.1:3000 \
  -PNOTIFIE_EXTERNAL_USER_ID="android-device-test-$(date +%s)"
```