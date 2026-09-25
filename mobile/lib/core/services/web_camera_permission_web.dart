import 'dart:js_interop';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web/web.dart' as web;

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
  Future<bool> ensureAccess({bool audio = true}) async {
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(
            web.MediaStreamConstraints(
              video: true.toJS,
              audio: audio.toJS,
            ),
          )
          .toDart;

      // Release the probe immediately: the exam's own CameraController opens the
      // stream that is actually recorded, and holding a second one would keep
      // the capture LED on and can make the real request fail with "device in
      // use" on platforms that allow only one consumer.
      for (final track in stream.getTracks().toDart) {
        track.stop();
      }
      return true;
    } catch (error) {
      // NotAllowedError (denied / dismissed), NotFoundError (no device),
      // SecurityError (insecure origin such as http://<lan-ip>), or
      // `navigator.mediaDevices` being undefined on a non-secure context.
      debugPrint('WebCameraPermission: camera/microphone probe refused: $error');
      return false;
    }
  }
}
