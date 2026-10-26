import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/hardware_verification_service.dart';
import 'package:proctorguard/core/services/permission_service.dart';
import 'package:proctorguard/core/services/platform_capabilities.dart';

/// The two questions a single `kIsWeb` check used to answer in one breath.
///
/// "Not the web" was the same answer as "has a camera and a face detector", so a
/// `kIsWeb` test was correct wherever it appeared. It is not any more: `camera`
/// implements android, ios and the browser, ML Kit implements android and ios
/// only, and the desktop `TargetPlatform`s have neither (their runners are gone
/// from the workspace, but the answer still has to be right for them). These
/// tests pin the two apart so a `!kIsWeb` shortcut cannot quietly come back.
void main() {
  group('the camera plugin exists on mobile and in the browser', () {
    test('android and ios can open a camera', () {
      expect(platformHasCamera(platform: TargetPlatform.android), isTrue);
      expect(platformHasCamera(platform: TargetPlatform.iOS), isTrue);
    });

    test('the web can, through camera_web', () {
      expect(platformHasCamera(isWeb: true), isTrue);
    });

    test('windows, linux and macos cannot — there is no desktop implementation',
        () {
      for (final target in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.fuchsia,
      ]) {
        expect(
          platformHasCamera(platform: target, isWeb: false),
          isFalse,
          reason: '$target would otherwise reach availableCameras(), which '
              'throws UnimplementedError there',
        );
      }
    });
  });

  group('ML Kit exists on mobile only', () {
    test('android and ios have a detector', () {
      expect(platformHasFaceDetector(platform: TargetPlatform.android), isTrue);
      expect(platformHasFaceDetector(platform: TargetPlatform.iOS), isTrue);
    });

    test('the browser and the desktop targets have none', () {
      expect(platformHasFaceDetector(isWeb: true), isFalse);
      for (final target in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(
          platformHasFaceDetector(platform: target, isWeb: false),
          isFalse,
          reason: '$target',
        );
      }
    });

    test('a browser camera with no detector is the asymmetry the gate reports',
        () {
      // This is the whole reason the two questions are separate: on the web the
      // camera is real and nothing here can read a face out of it.
      expect(platformHasCamera(isWeb: true), isTrue);
      expect(platformHasFaceDetector(isWeb: true), isFalse);
    });
  });

  group('the hardware gate on a desktop target', () {
    // `defaultTargetPlatform` is what the verifier reads at run time, and the VM
    // test host is not a phone: overriding it is the only way to ask "what does a
    // Windows/Linux build do" from a Dart VM test.
    TargetPlatform? previous;

    setUp(() {
      previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = previous;
    });

    test('blocks with an explanation instead of throwing', () async {
      // The gate must never throw: the exam screen it guards has no back button
      // to escape a crash with.
      final report = await DeviceHardwareVerifier(
        permissions: _ClearPermissions(),
      ).verify();

      expect(report.isVerified, isFalse);
      expect(report.hasFailed, isTrue);
      expect(report.isRunning, isFalse);
      expect(
        report.camera.message,
        contains('phone or tablet'),
        reason: 'a desktop build must name the real limitation rather than '
            'report a device fault and a retry that can never succeed',
      );
      expect(
        report.settingsHint,
        isFalse,
        reason: 'no OS setting installs a camera plugin into a build without one',
      );
    });

    test('marks the attempt face-detection-free, like the browser', () async {
      final report = await DeviceHardwareVerifier(
        permissions: _ClearPermissions(),
      ).verify();

      expect(
        report.faceDetectionInactive,
        isTrue,
        reason: 'ML Kit has no desktop implementation either, and the gate is the '
            'one place a student can be told before the exam',
      );
    });
  });

  group('the hardware gate on a mobile target', () {
    TargetPlatform? previous;

    setUp(() {
      previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = previous;
    });

    test('is not marked face-detection-free', () async {
      // No camera plugin is registered in a test run, so the probe fails — the
      // point here is the *absent* desktop note, not the failing camera.
      final report = await DeviceHardwareVerifier(
        permissions: _ClearPermissions(),
      ).verify();

      expect(report.hasFailed, isTrue);
      expect(report.faceDetectionInactive, isFalse);
    });
  });
}

/// A [PermissionService] that reports nothing denied or unknown, so the verifier
/// reaches its camera branch without touching a platform channel.
class _ClearPermissions extends PermissionService {
  @override
  Future<CriticalPermissionReport> checkCritical() async =>
      const CriticalPermissionReport(denied: <StartupPermission>[], unknown: <StartupPermission>[]);
}
