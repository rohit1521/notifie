plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("maven-publish")
    id("signing")
}

/**
 * Published so other packages can depend on this SDK as an artifact.
 *
 * The Flutter and React Native bridges must delegate to this implementation
 * rather than reimplementing scheduling, and an Android library cannot be
 * consumed by source: resource `R` classes resolve against the compiling
 * module's namespace, so SDK code compiled elsewhere fails to link. A Maven
 * coordinate is the only mechanism that serves both a monorepo bridge and a
 * published consumer.
 */
val notifieVersion = "0.1.0-beta.5"

android {
    namespace = "dev.notifie"
    compileSdk = 35

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    publishing {
        singleVariant("release") {
            // Sources let a consumer step into the SDK while debugging a
            // delivery problem, which is when they most need to.
            withSourcesJar()
            // Required by Maven Central, which rejects a release without one.
            withJavadocJar()
        }
    }
}

dependencies {
    // `api` rather than `implementation`: RemoteMessage appears in the public
    // signature of handleRemoteMessage, so a consumer resolving this artifact
    // must be able to compile against it. As an implementation dependency the
    // published POM would offer a method nobody could call.
    api("com.google.firebase:firebase-messaging:24.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.14.1")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "dev.notifie"
            artifactId = "notifie-android"
            version = notifieVersion

            afterEvaluate {
                from(components["release"])
            }

            pom {
                name.set("Notifie Android SDK")
                description.set(
                    "Notifie Device SDK for Android: local notifications, push tokens, " +
                        "lifecycle events and durable delivery.",
                )
                url.set("https://notifie.dev")
                licenses {
                    license {
                        name.set("The Apache License, Version 2.0")
                        url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
                    }
                }
                // Required by Maven Central: an artifact with no attributable
                // maintainer is rejected at validation, not at upload.
                developers {
                    developer {
                        id.set("rohit1521")
                        name.set("Rohith Krishnan")
                        url.set("https://github.com/rohit1521")
                    }
                }
                scm {
                    url.set("https://github.com/rohit1521/notifie")
                    connection.set("scm:git:https://github.com/rohit1521/notifie.git")
                    developerConnection.set("scm:git:ssh://git@github.com/rohit1521/notifie.git")
                }
            }
        }
    }

    // Staged to a local directory rather than uploaded directly.
    //
    // The Central Portal accepts a single bundle containing the full Maven
    // layout with signatures and checksums, so producing that locally keeps the
    // upload inspectable: the exact bytes can be verified before they become
    // permanent. Maven Central never allows a released version to be replaced.
    repositories {
        maven {
            name = "centralBundle"
            url = uri(layout.buildDirectory.dir("central-bundle"))
        }
    }
}

/**
 * Signs published artifacts.
 *
 * Maven Central rejects unsigned artifacts. The key is read from the
 * environment rather than a file so that no signing material is ever written
 * into the repository, and signing is skipped entirely when the environment is
 * absent so local development and CI do not need a private key.
 */
signing {
    val signingKey = System.getenv("NOTIFIE_SIGNING_KEY")
    val signingPassword = System.getenv("NOTIFIE_SIGNING_PASSWORD")
    isRequired = signingKey != null

    if (signingKey != null) {
        // The password defaults to empty rather than null: a key with no
        // passphrase is legitimate for CI, and passing null leaves Gradle with
        // no signatory configured, which surfaces much later as an unrelated
        // "no configured signatory" failure.
        useInMemoryPgpKeys(signingKey, signingPassword ?: "")
        afterEvaluate {
            sign(publishing.publications["release"])
        }
    }
}

/**
 * Packages the staged artifacts into a Central Portal upload bundle.
 *
 * The Portal expects a zip whose root is the group path, which is exactly the
 * layout `publishAllPublicationsToCentralBundleRepository` produces.
 */
tasks.register<Zip>("centralBundle") {
    dependsOn("publishAllPublicationsToCentralBundleRepository")
    from(layout.buildDirectory.dir("central-bundle"))
    // Gradle writes these for local resolution; the Portal rejects them.
    exclude("**/maven-metadata*")
    archiveFileName.set("notifie-android-$notifieVersion-bundle.zip")
    destinationDirectory.set(layout.buildDirectory.dir("central-portal"))
}