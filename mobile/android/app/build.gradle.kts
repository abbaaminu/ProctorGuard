import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

/// Release signing material, read from `android/key.properties` (git-ignored - see
/// `mobile/android/key.properties.example` for the four keys it needs).
///
/// The Flutter template signs the release build with the **debug** keystore so that
/// `flutter run --release` works in a fresh checkout. For a proctoring app that is a
/// shipping hazard rather than a convenience: the debug key is public and its
/// password is `android`, so anyone can build an APK that Android accepts as an
/// *upgrade* of the installed one - camera permission, kiosk pin and all - and hand
/// it to a student. A release build therefore requires a real keystore and fails
/// loudly without one, and the opt-out below has to be written down on purpose.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

val releaseSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val hasReleaseSigning = releaseSigningKeys.all {
    !keystoreProperties.getProperty(it).isNullOrBlank()
}

/// Deliberate opt-out for a *demo* release build: set
/// `proctorGuard.debugSigning=true` in `android/gradle.properties` (or pass
/// `-PproctorGuard.debugSigning=true`) and the release build type falls back to the
/// debug keystore instead of failing. Never use it for a build a student runs.
val allowDebugSigning =
    (providers.gradleProperty("proctorGuard.debugSigning").orNull ?: "false").toBoolean()

// Checked at configuration time and only for release *tasks*, so `flutter test`,
// `flutter analyze`, debug builds and `gradlew tasks` keep working in a checkout
// without signing material.
val requestedReleaseTask = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

android {
    namespace = "com.example.exam_proctor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // The engine "MediaPipe" is really `com.google.mlkit:face-detection` (the bundled
    // face detector, see `mediapipe_proctoring_service.dart`), and that AAR ships its
    // models as assets: `assets/models_bundled/fssd_25_8bit_v2.tflite`, `blazeface.tfl`,
    // `fssd_anchors_v2.pb`, `BCLjoy_200.emd`, … AAPT deflates assets by default, and a
    // deflated asset has no file offset - the native detector maps these out of the APK
    // as *files*, so compression would push the loader into inflating ~8 MB into the
    // Java heap next to a live camera preview. Storing them costs a little package size
    // and is what makes detections happen at all; the smoke test on a real device is
    // what proves it.
    androidResources {
        noCompress.add("tflite")
        noCompress.add("tfl")
        noCompress.add("pb")
        noCompress.add("emd")
    }

    defaultConfig {
        // TODO(PG-1): still the `flutter create` placeholder, and it is the app's
        // permanent identity on Android (data directory, granted permissions, upgrade
        // path). Changing it makes every installed build a *different* app, so it has
        // to land before the first deployment rather than after one - see the
        // hardening report.
        applicationId = "com.example.exam_proctor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            } else if (allowDebugSigning) {
                // Opted in explicitly (see `allowDebugSigning`).
                signingConfig = signingConfigs.getByName("debug")
            }

            // Shrinking is on for the release build: the app ships a face detector
            // and a camera pipeline the size of a small app on their own, and an
            // unshrunk APK also hands an attacker the full class list of a proctoring
            // client. The rules that keep the reflectively-reached parts alive are in
            // `proguard-rules.pro`; the on-device smoke test after this change is
            // what proves them (ML Kit face detection and the `record` capture path
            // are the two that a shrinker can break silently).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

if (requestedReleaseTask && !hasReleaseSigning && !allowDebugSigning) {
    throw GradleException(
        """
        Refusing to build a release APK signed with the public debug key.

        Create `mobile/android/key.properties` (git-ignored, see
        `key.properties.example`) with:

            storeFile=../upload-keystore.jks
            storePassword=<keystore password>
            keyAlias=<key alias>
            keyPassword=<key password>

        ...and put the matching `.jks` next to `mobile/android/`. Generate it once
        with:

            keytool -genkey -v -keystore upload-keystore.jks -storetype JKS \
              -keyalg RSA -keysize 2048 -validity 10000 -alias upload

        For a throwaway demo build only, `proctorGuard.debugSigning=true` in
        `android/gradle.properties` restores the old debug-key behaviour.
        """.trimIndent(),
    )
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
