import 'package:proctorguard/core/services/permission_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

/// Regression cover for the web startup crash:
///
/// `Unsupported operation: The Permission.systemAlertWindow permission is
/// currently not supported on web` used to escape [PermissionService.requestAll]
/// during `main()`, so the app never reached its first frame (white screen).
/// The service must now skip permissions a platform lacks and downgrade every
/// other failure to a status.
void main() {
  // permission_handler goes through a MethodChannel even when it fails, and
  // channel access needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('platform support rules', () {
    test('Android-only overlay permission is skipped on web', () {
      expect(
        PermissionService.isSupported(StartupPermission.systemAlertWindow,
            isWeb: true),
        isFalse,
      );
      expect(
        PermissionService.isSupported(StartupPermission.systemAlertWindow,
            isWeb: false),
        isTrue,
      );
    });

    test('camera and microphone are supported on web', () {
      expect(
        PermissionService.isSupported(StartupPermission.camera, isWeb: true),
        isTrue,
      );
      expect(
        PermissionService.isSupported(StartupPermission.microphone, isWeb: true),
        isTrue,
      );
    });
  });

  group('requestAll never throws', () {
    test('returns one safe fallback result per permission', () async {
      final results = await PermissionService().requestAll();

      expect(results.map((r) => r.permission), StartupPermission.values);
      for (final result in results) {
        expect(result.isGranted, isFalse);
        expect(
          result.status,
          anyOf(PermissionStatus.denied, PermissionStatus.restricted),
        );
      }
    });

    test('critical-permission helpers degrade instead of throwing', () async {
      final service = PermissionService();

      expect(await service.allCriticalGranted(), isFalse);
      expect(
        await service.missingCriticalPermissions(),
        containsAll(<StartupPermission>[
          StartupPermission.camera,
          StartupPermission.microphone,
        ]),
      );
    });
  });

  group('PermissionResult', () {
    test('is granted only for a granted status', () {
      const granted = PermissionResult(
        StartupPermission.camera,
        PermissionStatus.granted,
      );
      expect(granted.isGranted, isTrue);
      expect(granted.notApplicable, isFalse);
    });

    test('flags skipped, platform-only permissions as not applicable', () {
      const skipped = PermissionResult(
        StartupPermission.systemAlertWindow,
        PermissionStatus.restricted,
        notApplicable: true,
      );
      expect(skipped.isGranted, isFalse);
      expect(skipped.notApplicable, isTrue);
    });
  });
}
