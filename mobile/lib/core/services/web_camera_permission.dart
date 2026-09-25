import 'web_camera_permission_stub.dart'
    if (dart.library.js_interop) 'web_camera_permission_web.dart' as impl;

/// Browser-side camera/microphone permission probe.
///
/// Why this exists: `camera_web` enumerates devices with
/// `navigator.mediaDevices.enumerateDevices()` and **filters out every device
/// whose `deviceId` is empty** — which is precisely what a browser reports
/// before the user has granted camera access (and always, on an insecure
/// origin). So on the web `availableCameras()` legitimately returns an empty
/// list until something calls `getUserMedia()`, and a session started without
/// that probe concludes "no camera is available" and shows the crossed-out
/// camera placeholder.
///
/// [ensureAccess] makes that one call, releases the probe tracks immediately and
/// returns whether the browser granted access, so the caller can enumerate
/// again and get real devices.
///
/// On Android/iOS/desktop and in the Dart VM (`flutter test`) there is no
/// browser to ask and the camera plugin reports a refusal itself, so
/// [isSupported] is false and [ensureAccess] reports success without doing
/// anything.
abstract class WebCameraPermission {
  /// Picks the implementation for the platform this code was compiled for.
  factory WebCameraPermission() => impl.createWebCameraPermission();

  /// False on every non-web platform (and in VM widget tests).
  bool get isSupported;

  /// Asks the browser for camera (and, by default, microphone) access.
  ///
  /// Returns true when the page holds the grant — including when it already
  /// did, because `getUserMedia` resolves without prompting in that case — and
  /// false when the browser refused (denied, no device, insecure origin).
  /// Never throws.
  Future<bool> ensureAccess({bool audio = true});
}
