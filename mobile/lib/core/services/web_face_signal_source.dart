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

  /// The second global a host detector calls, when it can tell: whether this page
  /// is able to measure a head *angle* at all — `true` for a sensor that reports
  /// landmarks or a solved pose, `false` for a page that can only count faces.
  ///
  /// The name is fixed (`window.proctorGuardFaceAnalysis`) and the payload is a
  /// boolean, because it is not a detection: it is the page describing its own
  /// eyesight. `mobile/web/proctor_face_detector.js` calls it once per change,
  /// from the same loop that calls [globalName].
  static const String analysisGlobalName = 'proctorGuardFaceAnalysis';

  /// False where nothing can call the hook: Android, iOS, desktop, and the Dart
  /// VM `flutter test` runs on.
  bool get isSupported;

  /// One message per detection, lowercased and trimmed, exactly as the host sent
  /// it. Unrecognised strings are passed through too — the monitor decides what
  /// it understands, and dropping vocabulary here would hide a host's typo.
  Stream<String> get messages;

  /// What the page can actually see, as it changes: `true` when head turns are
  /// being measured, `false` when the page has been reduced to counting faces
  /// (no native detector and no model — a host that disabled it, a browser
  /// without WebAssembly, assets that are not on the server).
  ///
  /// A `centered` from a page that cannot measure an angle and a `centered` from
  /// a student looking at the screen are the same message, and an attempt is
  /// worth different things depending on which one it was. This stream is how
  /// the app tells them apart — for the student, and for
  /// `proctoring_coverage()` through the heartbeat's `monitoring_ok`. It is
  /// deliberately *not* evidence of misconduct: a browser that cannot measure an
  /// angle flags nothing, it says so.
  ///
  /// Empty where there is no page to ask ([isSupported] is false).
  Stream<bool> get analysis;

  /// Removes the global hook. Safe to call more than once.
  void dispose();
}
