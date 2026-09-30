import 'dart:io';

import 'package:exam_proctor/core/services/hardware_integrity_service.dart';
import 'package:exam_proctor/core/services/kiosk_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the Android half of the app's security contract, the same way
/// `schema_contract_test.dart` pins the Supabase one.
///
/// None of this is reachable from a Dart test at runtime - it is manifest metadata,
/// Gradle configuration and a Kotlin method channel - so the files themselves are the
/// contract. Everything asserted here is a decision that was made for a security
/// reason and that a later edit could undo silently:
///
///  * `allowBackup="false"` (the persisted session and the offline violation queue are
///    credentials and audit data, not something to copy into a cloud account);
///  * no `SYSTEM_ALERT_WINDOW` (a standing draw-over-other-apps grant is a proctoring
///    bypass surface, and nothing in the app draws a system overlay);
///  * cleartext denied at the platform layer, with loopback as the only exception;
///  * `FLAG_SECURE` for the duration of an exam, and re-pinning on resume;
///  * R8 on for release, with the keep rules the face detector needs;
///  * a release build that can no longer be signed with the public debug key.
void main() {
  /// Reads a file relative to the package root (`mobile/`, which is the working
  /// directory `flutter test` uses). Null when a checkout does not have it, so the
  /// test never pretends to have checked something it did not read.
  String? read(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  group('AndroidManifest.xml', () {
    test('does not back the session up off the device', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      if (manifest == null) return;

      // The Supabase session (access + refresh token) lives in shared_preferences, and
      // the offline violation queue holds the school's audit rows: auto-backup copies
      // both into the student's own cloud account, where they outlive the exam.
      expect(manifest, contains('android:allowBackup="false"'));
    });

    test('declares no system-overlay permission', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      if (manifest == null) return;

      // Nothing drew a system overlay; the permission only bought a sensitive-permission
      // review and a bypass surface. The check is on the *declaration*, not the bare
      // word - the manifest comment explains why the permission is gone and has to be
      // able to name it.
      expect(
        manifest,
        isNot(matches(RegExp(
          r'<uses-permission[^>]*android\.name="android\.permission\.'
          r'SYSTEM_ALERT_WINDOW"',
        ))),
      );
    });

    test('keeps the permissions the exam actually needs', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      if (manifest == null) return;

      expect(manifest, contains('android.permission.CAMERA'));
      expect(manifest, contains('android.permission.RECORD_AUDIO'));
      expect(manifest, contains('android.permission.INTERNET'));
      expect(
        manifest,
        contains('android.hardware.camera.front'),
        reason: 'the exam opens the front camera, so the device must have one',
      );
    });

    test('pins the exam activity and points it at the network policy', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      if (manifest == null) return;

      // `if_whitelisted` is what lets a device owner lock the app into the exam without
      // a second app having to ask for it at runtime.
      expect(manifest, contains('android:lockTaskMode="if_whitelisted"'));
      expect(manifest, contains('@xml/network_security_config'));
    });
  });

  group('network security config', () {
    test('denies cleartext everywhere except loopback', () {
      final config = read('android/app/src/main/res/xml/network_security_config.xml');
      if (config == null) return;

      // The Dart-side validator refuses an http backend; this makes it a platform
      // guarantee too, so a dependency that falls back to http fails loudly instead of
      // sending a session token over the exam room's Wi-Fi.
      expect(config, contains('<base-config cleartextTrafficPermitted="false" />'));
      expect(config, contains('<domain-config cleartextTrafficPermitted="true">'));
      for (final host in <String>['localhost', '127.0.0.1', '10.0.2.2']) {
        expect(config, contains('>$host</domain>'), reason: host);
      }
    });
  });

  group('release build', () {
    test('shrinks and keeps the face detector alive', () {
      final gradle = read('android/app/build.gradle.kts');
      final rules = read('android/app/proguard-rules.pro');
      if (gradle == null || rules == null) return;

      expect(gradle, contains('isMinifyEnabled = true'));
      expect(gradle, contains('isShrinkResources = true'));
      expect(gradle, contains('"proguard-rules.pro"'));
      expect(gradle, contains('getDefaultProguardFile("proguard-android-optimize.txt")'));

      // The engine is reached by class name from inside the bundled native library, which
      // no consumer rule can see: without these keeps every face signal degrades to
      // `no_face`, i.e. students disqualified by a shrinker.
      expect(rules, contains('com.google.mlkit'));
      expect(rules, contains('com.google.mediapipe'));
      expect(rules, contains('com.example.exam_proctor'));
      expect(rules, contains('io.flutter'));
      expect(rules, contains('SourceFile,LineNumberTable'));
      // The bundled detector's own rules only keep the *fields* of its generated proto
      // classes, and the JNI entry point plus the module descriptor are looked up by name
      // at runtime. These three packages are what is left over for us to keep.
      expect(rules, contains('com.google.android.gms.internal.mlkit_vision_face_bundled'));
      expect(rules, contains('com.google.android.gms.vision'));
      expect(rules, contains('com.google.android.gms.dynamite.descriptors'));
    });

    test('ships the detector models uncompressed', () {
      final gradle = read('android/app/build.gradle.kts');
      if (gradle == null) return;

      // `com.google.mlkit:face-detection` carries the engine as assets
      // (`assets/models_bundled/fssd_25_8bit_v2.tflite`, `blazeface.tfl`, `*.emd`, …) and
      // the native detector opens them as files out of the APK. A deflated asset has no
      // file offset, so AAPT's default compression is the difference between a detection
      // and an `IOException` next to a live camera preview.
      expect(gradle, contains('noCompress'));
      for (final extension in <String>['tflite', 'tfl', 'pb', 'emd']) {
        expect(gradle, contains('"$extension"'), reason: extension);
      }
    });

    test('cannot be signed with the debug key by accident', () {
      final gradle = read('android/app/build.gradle.kts');
      if (gradle == null) return;

      // The Flutter template's `signingConfig = signingConfigs.getByName("debug")` is a
      // shipping hazard: the debug keystore is public, so a forged APK upgrades the
      // installed proctoring app with camera and kiosk permissions intact.
      expect(gradle, contains('key.properties'));
      expect(gradle, contains('GradleException'));
      expect(gradle, contains('proctorGuard.debugSigning'));
      // The debug fallback survives only behind the documented opt-out: it is mentioned
      // before the branch that reads it, never as the default.
      expect(
        gradle.indexOf('proctorGuard.debugSigning'),
        lessThan(gradle.indexOf('signingConfig = signingConfigs.getByName("debug")')),
        reason: 'the debug keystore is only reachable through the opt-out',
      );
    });

    test('the keystore and the file that unlocks it are git-ignored', () {
      final ignore = read('../.gitignore');
      if (ignore == null) return;

      expect(ignore, contains('mobile/android/key.properties'));
      expect(ignore, contains('*.jks'));
      expect(ignore, contains('*.keystore'));
    });
  });

  group('MainActivity.kt', () {
    test('blocks screenshots for the duration of a pinned exam', () {
      final activity =
          read('android/app/src/main/kotlin/com/example/exam_proctor/MainActivity.kt');
      if (activity == null) return;

      expect(activity, contains('WindowManager.LayoutParams.FLAG_SECURE'));
      // Applied by the pin and only by the pin: a permanent FLAG_SECURE would also black
      // out every screenshot a student legitimately takes outside an exam.
      expect(activity, contains('private fun applyScreenshotBlock(block: Boolean)'));
      expect(activity, contains('applyScreenshotBlock(secure)'));
      expect(activity, contains('applyScreenshotBlock(false)'));
      // ...and the Dart side's choice has to reach it.
      expect(activity, contains('call.argument<Boolean>("secure")'));
      expect(KioskService.channelName, 'lock_task_channel');
    });

    test('re-pins the exam when the platform dropped the pin', () {
      final activity =
          read('android/app/src/main/kotlin/com/example/exam_proctor/MainActivity.kt');
      if (activity == null) return;

      // Android drops lock task mode whenever the activity is stopped and never restores
      // it, so without this the second half of an exam runs unpinned while the app still
      // looks locked down.
      expect(activity, contains('override fun onResume()'));

      final onResume = activity.substring(
        activity.indexOf('override fun onResume()'),
        activity.indexOf('private fun handle'),
      );
      // Only a session that asked to be pinned is re-pinned: the flag is set by
      // `startLock` and cleared by `stopLock`, so a student using the app normally is
      // never trapped by a resume.
      expect(onResume, contains('locksRequested'));
      expect(onResume, contains('isLockTaskActive()'));
      expect(onResume, contains('startLockTask()'));
    });

    test('answers the channel names and methods the Dart side calls', () {
      final activity =
          read('android/app/src/main/kotlin/com/example/exam_proctor/MainActivity.kt');
      if (activity == null) return;

      // A rename on either side of a string-keyed bridge fails at runtime, on a student's
      // device, in the middle of an exam - so the two halves are compared here.
      expect(activity, contains('"${KioskService.channelName}"'));
      expect(activity, contains('"${HardwareIntegrityService.channelName}"'));
      for (final method in <String>[
        'startLock',
        'stopLock',
        'isLockTaskActive',
        'isLockTaskPermitted',
        'getIntegrityReport',
      ]) {
        expect(activity, contains('"$method"'), reason: method);
      }
    });
  });
}
