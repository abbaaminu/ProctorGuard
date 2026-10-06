import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../utils/proctor_log.dart';

import 'web_camera_permission.dart';

/// Creates the browser probe (web builds only).
WebCameraPermission createWebCameraPermission() =>
    const BrowserWebCameraPermission();

/// `navigator.mediaDevices.getUserMedia({video, audio})`, used as a one-shot
/// permission probe.
class BrowserWebCameraPermission implements WebCameraPermission {
  const BrowserWebCameraPermission();

  @override
  bool get isSupported => true;

  @override
  Future<WebCameraAccess> probe({bool audio = true}) async {
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              video: true.toJS,
              audio: audio.toJS,
            ),
          )
          .toDart;

      // Read the track lists *before* releasing them. A stopped track is gone
      // from the stream's own view of itself on some engines, and "did the
      // browser hand back a camera and a microphone" has to be answered from
      // what arrived, not from what is left after the cleanup below.
      final video = stream.getVideoTracks().toDart.isNotEmpty;
      final captured = stream.getAudioTracks().toDart.isNotEmpty;

      // Release the probe immediately: the exam's own CameraController opens the
      // stream that is actually recorded, and holding a second one would keep
      // the capture LED on and can make the real request fail with "device in
      // use" on platforms that allow only one consumer.
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }

      return WebCameraAccess(granted: true, video: video, audio: captured);
    } catch (error) {
      // NotAllowedError (denied / dismissed), NotFoundError (no device),
      // SecurityError (insecure origin such as http://<lan-ip>), or
      // `navigator.mediaDevices` being undefined on a non-secure context.
      proctorLog('WebCameraPermission: camera/microphone probe refused: $error');
      return const WebCameraAccess.refused();
    }
  }
}
