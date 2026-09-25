import 'web_camera_permission.dart';

/// Creates the probe for platforms that have no browser.
WebCameraPermission createWebCameraPermission() =>
    const UnsupportedWebCameraPermission();

/// No-op probe for Android, iOS, desktop — and for the Dart VM, which is what
/// `flutter test` runs on.
///
/// Android/iOS do not need it: `PermissionService` requests camera + microphone
/// through the platform, and the camera plugin reports a refusal itself.
class UnsupportedWebCameraPermission implements WebCameraPermission {
  const UnsupportedWebCameraPermission();

  @override
  bool get isSupported => false;

  @override
  Future<bool> ensureAccess({bool audio = true}) async => true;
}
