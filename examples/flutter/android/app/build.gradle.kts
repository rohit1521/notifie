plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Applied unconditionally. This was guarded by a `file(...).exists()` check,
// which meant a missing google-services.json produced a build that succeeded
// and silently could not receive a push — the configuration every developer
// actually ships, never exercised. The config is committed, so its absence is
// a broken checkout and should fail here rather than at a user's device.
apply(plugin = "com.google.gms.google-services")

android {
    namespace = "com.example.notifie_flutter_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // Distinct from the native Android example, which uses
        // dev.notifie.androidtest. Sharing an applicationId means installing
        // one example silently replaces the other, so a developer comparing
        // them loses the first without being told.
        applicationId = "dev.notifie.flutterexample"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
