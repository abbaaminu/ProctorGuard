/// What the two native plugins this app cannot proctor without are able to do on
/// the platform it is running on.
///
/// These are facts about the *plugin ecosystem*, not about the device, and they
/// are deliberately not `kIsWeb` checks. "Not the web" does not mean "has a
/// camera and a face detector": `camera` ships federated implementations for
/// android, ios and the browser only, and `google_mlkit_face_detection` ships
/// none for the browser or any desktop. Asking the two questions separately is
/// what lets the browser report the true thing — a real camera, no on-device
/// detector — instead of a device fault it can never fix, and it is why the
/// desktop rows below still have an answer even though those runners have been
/// removed from the workspace.
///
/// | target                    | [platformHasCamera] | [platformHasFaceDetector] |
/// |---------------------------|---------------------|---------------------------|
/// | android, ios              | yes                 | yes                       |
/// | web (`camera_web`)        | yes                 | no                        |
/// | windows, linux, macos     | no                  | no                        |
///
/// Both take an overridable target so a Dart VM test can ask about a platform it
/// is not running on — the same seam, and for the same reason, as
/// `examRunsOnPlatform` in `mobile_exam_only.dart`.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

/// Whether the `camera` plugin can enumerate and open a device here.
///
/// False on the desktop targets, where there is no `camera_windows` or
/// `camera_linux`: `CameraPlatform.instance` falls back to the package's default
/// method-channel stub, so `availableCameras()` does not return an empty list, it
/// throws `UnimplementedError('availableCameras() is not implemented.')`. Callers
/// must not read `false` as "this machine has no webcam" — a Windows laptop
/// usually has one — but as "this build cannot reach it".
bool platformHasCamera({TargetPlatform? platform, bool? isWeb}) {
  if (isWeb ?? kIsWeb) return true;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.android || target == TargetPlatform.iOS;
}

/// Whether an on-device face detector exists here.
///
/// ML Kit is the only engine behind `MediaPipeProctoringService`, and it is
/// Android and iOS only. The web is the interesting case: a browser camera is a
/// real camera ([platformHasCamera] is true) but nothing there can pick a face out
/// of the frames, which is why the gate says so before the exam rather than a
/// proctoring report admitting it afterwards.
bool platformHasFaceDetector({TargetPlatform? platform, bool? isWeb}) {
  if (isWeb ?? kIsWeb) return false;
  final target = platform ?? defaultTargetPlatform;
  return target == TargetPlatform.android || target == TargetPlatform.iOS;
}
