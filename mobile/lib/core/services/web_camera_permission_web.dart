import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../utils/proctor_log.dart';

import 'web_camera_permission.dart';

/// Creates the browser probe (web builds only).
WebCameraPermission createWebCameraPermission() =>
    const BrowserWebCameraPermission();

/// `navigator.mediaDevices.getUserMedia`, used as a one-shot permission probe.
class BrowserWebCameraPermission implements WebCameraPermission {
  const BrowserWebCameraPermission();

  @override
  bool get isSupported => true;

  /// Two probes, video then audio, each opening and immediately closing its own
  /// stream.
  ///
  /// `getUserMedia({video: true, audio: true})` is a single all-or-nothing
  /// promise: if the microphone is missing or blocked the whole call rejects, and
  /// the caller cannot tell a refused camera from a refused microphone. That made
  /// the gate tell a student with a perfectly good camera to fix their camera
  /// because their laptop has no microphone. Asking separately costs one extra
  /// permission round-trip (the browser remembers a grant for the origin, so the
  /// second prompt is rare) and answers each device with its own result.
  ///
  /// Both are awaited, sequentially rather than concurrently: two simultaneous
  /// device opens make some engines pick the same device twice or fail the second
  /// with `NotReadableError`, and the delay between them is a few milliseconds.
  @override
  Future<WebCameraAccess> probe({bool audio = true}) async {
    final video = await _open(video: true, audio: false);
    if (audio == false) {
      // A camera-only caller asked nothing about the microphone, so the audio
      // half must not be reported as refused - it would be a claim about a
      // device nobody checked.
      return WebCameraAccess(
        granted: video.granted,
        video: video.granted,
        videoRefused: !video.granted,
      );
    }

    final mic = await _open(video: false, audio: true);

    return WebCameraAccess(
      // "Granted" means at least one request was answered: the gate renders the
      // two rows from `video`/`audio` and their refused flags, so a camera-only
      // laptop still reaches the device screen and gets a microphone-specific
      // message instead of a blanket "blocked".
      granted: video.granted || mic.granted,
      video: video.granted,
      audio: mic.granted,
      videoRefused: !video.granted,
      audioRefused: !mic.granted,
    );
  }

  /// Opens one `getUserMedia` request and closes it again.
  ///
  /// Returns whether the browser handed back a live track; every failure mode
  /// (`NotAllowedError` for a denied prompt, `NotFoundError` for no device,
  /// `SecurityError` on an insecure origin such as `http://<lan-ip>`, or
  /// `navigator.mediaDevices` being undefined outside a secure context) is a
  /// `false` rather than an exception - the caller reports it, it does not crash
  /// the gate.
  Future<({bool granted})> _open({
    required bool video,
    required bool audio,
  }) async {
    web.MediaStream? stream;
    try {
      stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              video: video.toJS,
              audio: audio.toJS,
            ),
          )
          .toDart;

      // Read the track lists *before* releasing them. A stopped track is gone
      // from the stream's own view of itself on some engines, and "did the
      // browser hand back this device" has to be answered from what arrived, not
      // from what is left after the cleanup below.
      final tracks = video
          ? stream.getVideoTracks().toDart
          : stream.getAudioTracks().toDart;
      return (granted: tracks.isNotEmpty);
    } catch (error) {
      // NotAllowedError (denied / dismissed), NotFoundError (no device),
      // SecurityError (insecure origin such as http://<lan-ip>), or
      // `navigator.mediaDevices` being undefined on a non-secure context.
      proctorLog(
        'WebCameraPermission: ${video ? 'camera' : 'microphone'} probe '
        'refused: $error',
      );
      return (granted: false);
    } finally {
      // Release the probe immediately: the exam's own CameraController opens the
      // stream that is actually recorded, and holding a second one would keep
      // the capture LED on and can make the real request fail with "device in
      // use" on platforms that allow only one consumer. Released in `finally` so
      // a rejected *second* probe cannot leave the first stream open.
      for (final track in stream?.getTracks().toDart ?? <web.MediaStreamTrack>[]) {
        track.stop();
      }
    }
  }
}
