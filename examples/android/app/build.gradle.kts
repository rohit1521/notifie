plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.gms.google-services")
}

android {
    namespace = "dev.notifie.androidtest"
    compileSdk = 35

    defaultConfig {
        applicationId = "dev.notifie.androidtest"
        minSdk = 23
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        buildConfigField(
            "String",
            "NOTIFIE_API_KEY",
            quoted(providers.gradleProperty("NOTIFIE_API_KEY").orElse("").get()),
        )
        buildConfigField(
            "String",
            "NOTIFIE_BASE_URL",
            quoted(
                providers.gradleProperty("NOTIFIE_BASE_URL")
                    .orElse("http://127.0.0.1:3000")
                    .get(),
            ),
        )
        buildConfigField(
            "String",
            "NOTIFIE_EXTERNAL_USER_ID",
            quoted(
                    providers.gradleProperty("NOTIFIE_EXTERNAL_USER_ID")
                        .orElse("notifie-android-test-device")
                        .get(),
            ),
        )
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation(project(":notifie"))
}

private fun quoted(value: String): String {
    val escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
    return "\"$escaped\""
}