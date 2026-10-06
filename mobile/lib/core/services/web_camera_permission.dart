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
/// [probe] makes that one call, releases the probe tracks immediately and
/// reports which devices the browser handed back, so the caller can enumerate
/// again and get real devices.
///
/// On Android/iOS/desktop and in the Dart VM (`flutter test`) there is no
/// browser to ask and the camera plugin reports a refusal itself, so
/// [isSupported] is false and [probe] reports success without doing anything.
abstract class WebCameraPermission {
  /// Picks the implementation for the platform this code was compiled for.
  factory WebCameraPermission() => impl.createWebCameraPermission();

  /// False on every non-web platform (and in VM widget tests).
  bool get isSupported;

  /// Asks the browser for camera (and, by default, microphone) access, and
  /// reports what the browser actually handed back.
  ///
  /// The probe tracks are released before it returns, so the caller can go on
  /// to enumerate devices or open the session that is actually recorded. Never
  /// throws: a browser refusal (denied, no device, insecure origin) is a
  /// [WebCameraAccess] with `granted == false`.
  Future<WebCameraAccess> probe({bool audio = true});
}

/// What one browser `getUserMedia` probe found.
///
/// One `getUserMedia({video, audio})` call answers two questions at once, which
/// is why this is a record of *which* halves arrived rather than a bare
/// yes/no: a laptop with a camera and no microphone gets a video track and no
/// audio track, and that has to be reported as a microphone problem rather than
/// as "the device cannot be proctored".
///
/// The `video` / `audio` flags only carry meaning when [granted] is true, and
/// they only carry meaning **on the web** — the other platforms never call
/// [WebCameraPermission.probe] at all (see [WebCameraPermission.isSupported]),
/// because `PermissionService` and the camera plugin answer the same question
/// there.
class WebCameraAccess {
  const WebCameraAccess({
    required this.granted,
    this.video = false,
    this.audio = false,
  });

  /// The browser refused: no grant, no stream, nothing to inspect.
  const WebCameraAccess.refused() : this(granted: false);

  /// True when the browser resolved `getUserMedia` — including when the page
  /// already held the grant, since that resolves without prompting.
  final bool granted;

  /// A live video track came with the stream.
  final bool video;

  /// A live audio track came with the stream.
  final bool audio;

  /// Both devices were proved usable.
  bool get isComplete => granted && video && audio;
}
