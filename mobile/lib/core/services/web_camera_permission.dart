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

  /// Whether this browser has a camera to ask at all.
  ///
  /// False when `navigator.mediaDevices.getUserMedia` is missing: an embedded or
  /// legacy Android browser (the ones shipped by some phone vendors and
  /// "lite" browsers), or any page served over plain HTTP, where the API is
  /// deliberately absent. Nothing the student can change in a settings menu
  /// produces a camera there, so the gate has to point at the browser rather than
  /// at a permission - "allow camera access" sends them round a loop that cannot
  /// end in a working camera.
  ///
  /// True (the default for a browser that has the API) says nothing about whether
  /// permission was *granted*; that is [probe]'s answer.
  bool get canRequestCapture;

  /// Asks the browser for camera access and - by default - microphone access,
  /// as **two independent `getUserMedia` calls**, and reports what the browser
  /// actually handed back.
  ///
  /// Two calls, not one `{video, audio}` request: a combined request is
  /// all-or-nothing, so a laptop with a working camera and no microphone (or one
  /// whose microphone permission was blocked) rejects with `NotFoundError` and
  /// the gate used to report *both* devices as refused - sending a student to fix
  /// a camera that was never the problem. Asking separately means each row is
  /// answered by its own device, and one refusal cannot hide the other half's
  /// real state.
  ///
  /// The probe tracks are released before it returns, so the caller can go on
  /// to enumerate devices or open the session that is actually recorded. Never
  /// throws: a browser refusal (denied, no device, insecure origin) is a
  /// [WebCameraAccess] with the refused half marked.
  Future<WebCameraAccess> probe({bool audio = true});
}

/// What one browser probe found.
///
/// A record of *which* halves arrived rather than a bare yes/no: a laptop with a
/// camera and no microphone gets a video track and no audio track, and that has
/// to be reported as a microphone problem rather than as "the device cannot be
/// proctored". The refused flags separate the two ways a half can be missing -
/// the browser said no (a permission the student must change) from the browser
/// said yes but produced no track (a device to plug in) - because those need
/// different instructions.
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
    this.videoRefused = false,
    this.audioRefused = false,
  });

  /// The browser refused: no grant, no stream, nothing to inspect.
  const WebCameraAccess.refused()
      : this(granted: false, videoRefused: true, audioRefused: true);

  /// True when at least one of the probes resolved - including when the page
  /// already held the grant, since that resolves without prompting.
  final bool granted;

  /// A live video track came with the video probe.
  final bool video;

  /// A live audio track came with the audio probe.
  final bool audio;

  /// The video probe was rejected by the browser (`NotAllowedError`,
  /// `NotFoundError`, `SecurityError` on an insecure origin).
  final bool videoRefused;

  /// The audio probe was rejected by the browser.
  ///
  /// False when the caller asked for a camera-only probe ([WebCameraPermission
  /// .probe] with `audio: false`) - nothing was asked, so nothing is claimed.
  final bool audioRefused;

  /// Both devices were proved usable.
  bool get isComplete => granted && video && audio;
}
