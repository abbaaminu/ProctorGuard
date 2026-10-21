import 'dart:async';

import 'web_face_signal_source_stub.dart'
    if (dart.library.js_interop) 'web_face_signal_source_web.dart' as impl;

/// The browser's way into the proctoring pipeline: one hook, one stream of
/// detections, and no inference of this app's own.
///
/// The web build has no ML Kit, and the `camera` plugin's web implementation
/// cannot hand `CameraImage` frames to a model (`supportsImageStreaming()` is
/// false there, which is why the exam page never calls `startImageStream` on the
/// web). So the browser cannot *produce* a face signal by itself — but it can
/// host one. A page that runs a detector (WASM/WebGPU, or a remote service)
/// calls [globalName] once per detection with one of the `WebFaceMessages`
/// strings, and this source turns those calls into a stream that
/// `WebFacePresenceMonitor` classifies with the same rules as the on-device
/// engine. A web look-away then costs the same strike as a phone's, through the
/// same `ProctoringNotifier.reportGazeSignal` entry point.
///
/// What this deliberately does **not** do is invent a face. [isSupported] is
/// false on every other platform, and on the web it is true only while the hook
/// is installed — so a browser with no detector reports fewer signals (and says
/// so), rather than logging `no_face` for a student it never looked at.
abstract class WebFaceSignalSource {
  /// Creates the source for the running platform.
  factory WebFaceSignalSource() => impl.createWebFaceSignalSource();

  /// The global function a host detector calls: `window.proctorGuardFaceSignal`
  /// with one string argument (see `WebFaceMessages`).
  ///
  /// Installed when the source is created — with the exam session — and removed
  /// on [dispose], so the hook cannot outlive the attempt it reports on, and a
  /// page that is no longer examining holds no Dart closure on app state. Calls
  /// made before the hook exists (a detector that starts with the page) or after
  /// it is gone are dropped, not queued: a face seen before the exam began is
  /// not evidence about the exam.
  static const String globalName = 'proctorGuardFaceSignal';

  /// False where nothing can call the hook: Android, iOS, desktop, and the Dart
  /// VM `flutter test` runs on.
  bool get isSupported;

  /// One message per detection, lowercased and trimmed, exactly as the host sent
  /// it. Unrecognised strings are passed through too — the monitor decides what
  /// it understands, and dropping vocabulary here would hide a host's typo.
  Stream<String> get messages;

  /// Removes the global hook. Safe to call more than once.
  void dispose();
}
