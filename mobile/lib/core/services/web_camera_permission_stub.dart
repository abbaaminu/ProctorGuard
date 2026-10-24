import 'web_camera_permission.dart';

/// Creates the probe for platforms that have no browser.
WebCameraPermission createWebCameraPermission() =>
    const UnsupportedWebCameraPermission();

/// No-op probe for Android, iOS, desktop — and for the Dart VM, which is what
/// `flutter test` runs on.
///
/// Android/iOS do not need it: `PermissionService` requests camera + microphone
/// through the platform, and the camera plugin reports a refusal itself.
///
/// The `video` / `audio` flags are left false on purpose: they describe what a
/// *browser* handed back, and nothing off the web should read them. Every
/// caller checks [isSupported] first (see `DeviceHardwareVerifier.probe`), so
/// only [granted] ever matters here — and "not applicable" is not a refusal.
class UnsupportedWebCameraPermission implements WebCameraPermission {
  const UnsupportedWebCameraPermission();

  @override
  bool get isSupported => false;

  /// False: no browser here to ask, so nothing may claim the capability. Every
  /// caller reads it only after [isSupported] (see the exam page's "no camera"
  /// message), where this is the "not applicable" answer.
  @override
  bool get canRequestCapture => false;

  @override
  Future<WebCameraAccess> probe({bool audio = true}) async =>
      const WebCameraAccess(granted: true);
}
