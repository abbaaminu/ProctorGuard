import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Raw result of one inference pass over a camera frame.
class FaceFrameResult {
  final int faceCount;
  final double? yawDegrees;   // left/right head turn
  final double? pitchDegrees; // up/down head turn
  const FaceFrameResult({required this.faceCount, this.yawDegrees, this.pitchDegrees});
}

/// High-level signal the BLoC/Riverpod layer reacts to.
enum GazeSignal { centered, lookingAway, noFace, multipleFaces }

/// Detects faces on-device with Google ML Kit's Face Detection plugin and
/// exposes a throttled stream of high-level proctoring signals instead of raw
/// detections, so the presentation layer stays framework-agnostic.
///
/// A note on the name: the project was originally scoped around MediaPipe's
/// Face Landmarker, but the package it referenced
/// (`google_mediapipe_tasks_flutter`) is not published on pub.dev, so the
/// engine is backed by `google_mlkit_face_detection` instead. The class/file
/// name is kept so the existing wiring and README references stay valid.
///
/// Swapping in a different on-device model (e.g. a TFLite head-pose
/// regressor) only means replacing [_runInference]; the throttling, angle
/// math and escalation contract below stay the same.
class MediaPipeProctoringService {
  MediaPipeProctoringService({
    this.inferenceInterval = const Duration(milliseconds: 150), // ~6-7 FPS
    this.offCenterThresholdDegrees = 28.0,
    this.pitchThresholdDegrees = 30.0,
    this.lookAwayGraceDuration = const Duration(seconds: 3),
    this.noFaceGraceDuration = const Duration(seconds: 3),
    this.sensorOrientation = 90,
    this.lensDirection = CameraLensDirection.front,
    this.mockCamera = mockCameraFromEnvironment,
    this.mockInterval = const Duration(seconds: 12),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (mockCamera) _startMockFeed();
  }

  /// `--dart-define=MOCK_CAMERA=true` swaps real detection for a simulated
  /// feed, for emulators, desktop targets and CI machines that have no usable
  /// front camera. The exam page reads this flag too, so it skips opening the
  /// camera at all in mock mode.
  static const bool mockCameraFromEnvironment =
      bool.fromEnvironment('MOCK_CAMERA');

  final Duration inferenceInterval;

  /// Yaw (left/right head turn) tolerance in degrees. Relaxed to ~28 so a quick
  /// glance sideways, or turning toward a second screen, is not an instant
  /// violation - only a turn that stays past this for [lookAwayGraceDuration] is.
  final double offCenterThresholdDegrees;

  /// Pitch (up/down head tilt) tolerance in degrees. Deliberately a little wider
  /// than [offCenterThresholdDegrees]: looking down at a keyboard or notes while
  /// reading and typing is normal exam behaviour, not cheating.
  final double pitchThresholdDegrees;

  /// How long the head must stay past the yaw/pitch tolerances before a
  /// [GazeSignal.lookingAway] is emitted (once per episode).
  final Duration lookAwayGraceDuration;

  /// How long the face must stay missing before a [GazeSignal.noFace] is
  /// emitted (once per episode). This is the time grace period: a blink, a
  /// dropped frame or a hand sweeping past the lens no longer burns a strike.
  final Duration noFaceGraceDuration;

  /// Injectable time source, so the grace windows can be exercised in tests
  /// without waiting wall-clock seconds.
  final DateTime Function() _clock;

  /// Whether this instance drives [signals] from the simulated feed instead of
  /// ML Kit inference. Injectable so tests can switch it on without a
  /// dart-define.
  final bool mockCamera;

  /// How often the simulated feed emits a violation (12 seconds by default).
  final Duration mockInterval;

  /// Orientation of the physical camera producing the frames, used to upright
  /// each buffer before detection. Set from the chosen [CameraDescription] via
  /// [attachCamera]; the defaults match a typical front camera in portrait.
  int sensorOrientation;
  CameraLensDirection lensDirection;

  FaceDetector? _faceDetector;

  /// Built on first use, so constructing the service (and unit-testing the
  /// pure [estimateHeadPose] helper) never touches a platform channel.
  FaceDetector get _detector => _faceDetector ??= FaceDetector(
        options: FaceDetectorOptions(
          // ML Kit only reports head-pose Euler angles in ACCURATE mode —
          // FAST mode leaves them null. Frames are already throttled to
          // ~6-7 FPS and captured at ResolutionPreset.low, so the extra
          // native cost is acceptable for proctoring.
          performanceMode: FaceDetectorMode.accurate,
          minFaceSize: 0.15,
        ),
      );

  DateTime _lastInferenceAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Sustained-window bookkeeping. Each condition gets its own "since" stamp
  /// plus an "already flagged" latch, so one long episode yields exactly one
  /// signal - the student has to come back before the same condition can be
  /// reported again. That is what stops a sustained absence or head turn from
  /// stacking up disqualification flags.
  DateTime? _offCenterSince;
  DateTime? _faceMissingSince;
  bool _lookAwayFlagged = false;
  bool _noFaceFlagged = false;

  /// Whether the camera stream is actually delivering frames. Flipped by the
  /// exam page through [setStreamActive], so frames that arrive before the
  /// stream is live (or after it has been lost) are ignored instead of being
  /// read as "no face".
  bool _streamActive = true;

  bool _busy = false;
  bool _disposed = false;

  /// Simulated-feed state (mock mode only).
  Timer? _mockTimer;
  int _mockTick = 0;

  final _signalController = StreamController<GazeSignal>.broadcast();
  Stream<GazeSignal> get signals => _signalController.stream;

  /// Emits alternating `noFace` / `lookingAway` signals on a timer. Kept
  /// deliberately dumb — no grace period, no angle math — because its only job
  /// is to drive the escalation ladder (3 strikes → disqualified) so the
  /// overlay, the log rows, Storage upload and the supervisor's live feed can
  /// all be exercised without a camera.
  void _startMockFeed() {
    _mockTimer = Timer.periodic(mockInterval, (_) {
      if (_disposed) return;
      _mockTick++;
      _signalController.add(
        _mockTick.isOdd ? GazeSignal.noFace : GazeSignal.lookingAway,
      );
    });
  }

  /// True while the simulated feed is ticking (always false in normal mode).
  bool get isMockFeedActive => _mockTimer?.isActive ?? false;

  /// Records which physical camera produced the frames, so each buffer can be
  /// rotated upright before detection. Call once, right after the front camera
  /// has been selected.
  void attachCamera(CameraDescription camera) {
    sensorOrientation = camera.sensorOrientation;
    lensDirection = camera.lensDirection;
  }

  /// Tells the engine whether the camera stream is live.
  ///
  /// While `false` - the controller is initialising, was blocked, or the feed
  /// was lost - [onCameraFrame] ignores incoming frames and every sustained
  /// window is cleared, so an offline camera can never be mistaken for a missing
  /// face. Turning it back on restarts the grace windows from scratch.
  void setStreamActive(bool active) {
    _streamActive = active;
    if (!active) resetSustained();
  }

  /// Clears every sustained-window timer and latch. Called when the camera goes
  /// offline (see [setStreamActive]) and whenever the notifier pauses tracking,
  /// so resuming never inherits a half-elapsed grace window.
  void resetSustained() {
    _offCenterSince = null;
    _faceMissingSince = null;
    _lookAwayFlagged = false;
    _noFaceFlagged = false;
  }

  /// Feed every camera frame here; internal throttling decides whether it
  /// actually runs inference. Call from `CameraController.startImageStream`
  /// and pass `CameraController.value.deviceOrientation` so frames can be
  /// uprighted before detection.
  void onCameraFrame(
    CameraImage image, {
    DeviceOrientation deviceOrientation = DeviceOrientation.portraitUp,
  }) {
    // A simulated session never feeds frames (the exam page doesn't open a
    // camera in mock mode); ignore any stragglers so that testing stays
    // deterministic.
    if (mockCamera) return;

    // Initialising / offline camera: ignore frames rather than reporting a
    // phantom "no face". The exam page flips this with [setStreamActive].
    if (!_streamActive) return;

    // The injected clock, the same one the grace windows below are measured
    // against: one time base for the whole engine, so a host (or a test) that
    // supplies its own cannot have the throttle and the escalation rules
    // disagree about how much time has passed.
    final now = _clock();
    if (_busy || now.difference(_lastInferenceAt) < inferenceInterval) return;

    _busy = true;
    _lastInferenceAt = now;

    // Detection runs natively behind an async platform channel, so we
    // fire-and-forget with error containment: a single bad frame must never
    // crash the exam session or leave `_busy` stuck.
    _runInference(image, deviceOrientation).then((result) {
      // `null` means the frame couldn't be handed to ML Kit (unsupported
      // format/orientation) — skip it rather than reporting a phantom
      // `noFace` signal, which would otherwise burn one of the 3 strikes.
      if (result != null) _handleResult(result);
    }).catchError((_) {
      // Swallow transient inference errors (e.g. malformed frame); the next
      // throttled frame will retry.
    }).whenComplete(() => _busy = false);
  }

  /// Runs one detection pass over a frame.
  ///
  /// Returns `null` (rather than a zero-face result) when the frame cannot be
  /// converted for the detector at all, so callers can tell "unusable buffer"
  /// apart from "nobody in frame".
  Future<FaceFrameResult?> _runInference(
    CameraImage image,
    DeviceOrientation deviceOrientation,
  ) async {
    final inputImage = _toInputImage(image, deviceOrientation);
    if (inputImage == null) return null;

    final faces = await _detector.processImage(inputImage);
    if (faces.isEmpty) return const FaceFrameResult(faceCount: 0);
    if (faces.length > 1) return FaceFrameResult(faceCount: faces.length);

    final face = faces.first;
    // headEulerAngleY is the left/right turn (yaw) and headEulerAngleX the
    // up/down tilt (pitch). Both are null when ML Kit can't estimate the
    // pose; `_handleResult` then treats the face as centered, so the engine
    // only ever escalates on actual evidence.
    return FaceFrameResult(
      faceCount: 1,
      yawDegrees: face.headEulerAngleY,
      pitchDegrees: face.headEulerAngleX,
    );
  }

  /// Converts a camera frame into the single-plane NV21 (Android) /
  /// BGRA8888 (iOS) buffer ML Kit expects, tagged with the rotation needed to
  /// upright it.
  InputImage? _toInputImage(
    CameraImage image,
    DeviceOrientation deviceOrientation,
  ) {
    final format = _mlKitFormat(image);
    if (format == null) return null;

    final rotation = _mlKitRotation(deviceOrientation);
    if (rotation == null) return null;

    // Both supported formats live in a single plane; ML Kit's byte-buffer API
    // cannot consume a multi-plane frame.
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation, // used only on Android
        format: format, // used only on iOS
        bytesPerRow: plane.bytesPerRow, // used only on iOS
      ),
    );
  }

  /// Picks the ML Kit format for the streamed buffer, or `null` when the frame
  /// is in a format the detector cannot read.
  InputImageFormat? _mlKitFormat(CameraImage image) {
    final raw = InputImageFormatValue.fromRawValue(image.format.raw);

    // ML Kit has no web implementation (`dart:io`'s Platform would throw in a
    // browser anyway), so a web session produces no face signals — run it with
    // MOCK_CAMERA=true or accept camera-only monitoring.
    if (kIsWeb) return null;

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return raw == InputImageFormat.bgra8888
          ? InputImageFormat.bgra8888
          : null;
    }
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null; // ML Kit's detector is a mobile-only plugin
    }

    // The exam page requests ImageFormatGroup.nv21 on Android. CameraX
    // delivers those bytes as NV21 but can still report the stream as yuv420,
    // while the older camera_android implementation reports nv21 — normalise
    // both to NV21 for ML Kit.
    if (raw == InputImageFormat.nv21 || raw == InputImageFormat.yuv_420_888) {
      return InputImageFormat.nv21;
    }
    return null;
  }

  /// Maps the current device orientation + camera sensor orientation onto the
  /// rotation ML Kit must apply to upright the frame.
  InputImageRotation? _mlKitRotation(DeviceOrientation deviceOrientation) {
    if (kIsWeb) return null;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }
    if (defaultTargetPlatform != TargetPlatform.android) return null;

    final compensation = _deviceOrientationDegrees[deviceOrientation];
    if (compensation == null) return null;

    // Front cameras are mirrored, so their sensor rotation adds to the display
    // rotation instead of subtracting from it.
    final degrees = lensDirection == CameraLensDirection.front
        ? (sensorOrientation + compensation) % 360
        : (sensorOrientation - compensation + 360) % 360;
    return InputImageRotationValue.fromRawValue(degrees);
  }

  static const _deviceOrientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Estimates yaw/pitch from 3D face-mesh landmarks using the nose tip and
  /// the outer corners of both eyes as a stable triangle.
  ///
  /// The shipped engine uses ML Kit's own head-pose output
  /// ([Face.headEulerAngleY] / [Face.headEulerAngleX]) instead, because this
  /// geometric approximation needs 3D landmarks (z != 0) and ML Kit only
  /// reports 2D landmark points. It remains for the documented fallback path:
  /// a custom on-device model — MediaPipe Face Mesh or a TFLite landmarker —
  /// whose output includes full x/y/z landmarks. It is a lightweight
  /// geometric approximation (not a full 3D solvePnP), sufficient for a
  /// binary "looking at screen vs. not" decision.
  (double yaw, double pitch) estimateHeadPose({
    required List<double> noseTip,      // [x, y, z]
    required List<double> leftEyeOuter,
    required List<double> rightEyeOuter,
  }) {
    final eyeMidX = (leftEyeOuter[0] + rightEyeOuter[0]) / 2;
    final eyeMidY = (leftEyeOuter[1] + rightEyeOuter[1]) / 2;
    final eyeMidZ = (leftEyeOuter[2] + rightEyeOuter[2]) / 2;

    final dx = noseTip[0] - eyeMidX;
    final dy = noseTip[1] - eyeMidY;
    final dz = noseTip[2] - eyeMidZ;

    // Eye-line vector gives us a scale reference for normalizing the offset.
    final eyeDist = math.sqrt(
      math.pow(rightEyeOuter[0] - leftEyeOuter[0], 2) +
          math.pow(rightEyeOuter[1] - leftEyeOuter[1], 2),
    );
    if (eyeDist == 0) return (0, 0);

    final yaw = math.atan2(dx, dz.abs() + 1e-6) * (180 / math.pi);
    final pitch = math.atan2(dy, dz.abs() + 1e-6) * (180 / math.pi);
    return (yaw, pitch);
  }

  /// Feeds one inference result through the grace/debounce logic.
  ///
  /// Exposed beyond [onCameraFrame] so the sustained-threshold behaviour can be
  /// unit-tested without a camera or ML Kit.
  @visibleForTesting
  void handleResult(FaceFrameResult result) => _handleResult(result);

  /// Applies the time grace period to one detection result.
  ///
  /// A single frame is never enough to flag the student: [GazeSignal.noFace]
  /// and [GazeSignal.lookingAway] are only emitted once the condition has held
  /// for [noFaceGraceDuration] / [lookAwayGraceDuration] respectively, and each
  /// episode emits at most once. The student has to return (a `centered` result
  /// or a visible face) before the same condition can be reported again, so a
  /// blink, a dropped frame, or one glance at the keyboard cannot accumulate
  /// multiple disqualification flags.
  void _handleResult(FaceFrameResult result) {
    // An inference that was already on the wire when the session ended still
    // lands here: `onCameraFrame` fire-and-forgets it (`.then(_handleResult)`), so
    // a frame captured before the page was popped can arrive after [dispose] ran.
    // Adding to the closed controller throws into that detached chain, and the
    // grace windows underneath measure a session that no longer exists.
    if (_disposed || _signalController.isClosed) return;

    final now = _clock();

    if (result.faceCount == 0) {
      // Face missing: a *sustained* absence becomes noFace. Without a face the
      // head can no longer be "off centre", so close that window.
      _offCenterSince = null;
      _lookAwayFlagged = false;

      _faceMissingSince ??= now;
      if (!_noFaceFlagged &&
          now.difference(_faceMissingSince!) >= noFaceGraceDuration) {
        _noFaceFlagged = true;
        _signalController.add(GazeSignal.noFace);
      }
      return;
    }

    // A face is visible again: close the missing-face episode so a later
    // absence is measured (and reported) from scratch.
    _faceMissingSince = null;
    _noFaceFlagged = false;

    if (result.faceCount > 1) {
      // Two people in frame is unambiguous, so it is reported immediately.
      _offCenterSince = null;
      _lookAwayFlagged = false;
      _signalController.add(GazeSignal.multipleFaces);
      return;
    }

    final yaw = result.yawDegrees ?? 0;
    final pitch = result.pitchDegrees ?? 0;
    final isOffCenter = yaw.abs() > offCenterThresholdDegrees ||
        pitch.abs() > pitchThresholdDegrees;

    if (!isOffCenter) {
      _offCenterSince = null;
      _lookAwayFlagged = false;
      _signalController.add(GazeSignal.centered);
      return;
    }

    _offCenterSince ??= now;
    if (!_lookAwayFlagged &&
        now.difference(_offCenterSince!) >= lookAwayGraceDuration) {
      _lookAwayFlagged = true;
      _signalController.add(GazeSignal.lookingAway);
    }
  }

  /// Releases the native detector (no-op when inference never ran) and closes
  /// the signal stream. Safe to call more than once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _mockTimer?.cancel();
    _mockTimer = null;
    _faceDetector?.close();
    _faceDetector = null;
    _signalController.close();
  }
}
