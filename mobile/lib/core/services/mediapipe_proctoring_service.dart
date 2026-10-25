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
    this.offCenterThresholdDegrees = 15.0,
    this.pitchThresholdDegrees = 18.0,
    this.immediateAwayThresholdDegrees = 30.0,
    this.consecutiveFrameThreshold = 1,
    this.missingFaceFrameThreshold = 3,
    this.multipleFacesCooldown = const Duration(seconds: 30),
    this.sensorOrientation = 90,
    this.lensDirection = CameraLensDirection.front,
    this.mockCamera = mockCameraFromEnvironment,
    this.mockInterval = const Duration(seconds: 12),
    DateTime Function()? clock,
  })  : assert(
          consecutiveFrameThreshold > 0,
          'a zero frame threshold would flag every single frame',
        ),
        assert(
          missingFaceFrameThreshold > 0,
          'a zero frame threshold would flag every single dropped frame',
        ),
        assert(
          immediateAwayThresholdDegrees >= offCenterThresholdDegrees,
          'an "unambiguous" turn inside the ordinary tolerance would flag '
          'every glance',
        ),
        _clock = clock ?? DateTime.now {
    if (mockCamera) _startMockFeed();
  }

  /// `--dart-define=MOCK_CAMERA=true` swaps real detection for a simulated
  /// feed, for emulators, desktop targets and CI machines that have no usable
  /// front camera. The exam page reads this flag too, so it skips opening the
  /// camera at all in mock mode.
  static const bool mockCameraFromEnvironment =
      bool.fromEnvironment('MOCK_CAMERA');

  final Duration inferenceInterval;

  /// Yaw (left/right head turn) tolerance in degrees.
  ///
  /// Tightened to 15 by the audit: an exam screen is the only thing the student is
  /// meant to be looking at, and at a normal viewing distance a 15 deg turn already
  /// points the face - and the eyes - off it, which is how a second screen, a phone
  /// flat on the desk or a person standing beside them gets read. The earlier 28 deg
  /// tolerance let a student work from a second display at the edge of the camera's
  /// view for the whole sitting without ever being flagged.
  ///
  /// A single frame past this is reported ([consecutiveFrameThreshold] is one), so
  /// the windows that keep a one-off out are elsewhere: the angle has to be a real
  /// turn, and `pitchThresholdDegrees` is judged separately because reading and
  /// typing look down.
  final double offCenterThresholdDegrees;

  /// Pitch (up/down head tilt) tolerance in degrees.
  ///
  /// A little wider than [offCenterThresholdDegrees] (18 against 15) and no wider:
  /// a few degrees of droop while reading the question on screen is normal, but a
  /// head down at a phone in the lap or notes on the desk is 25-40 deg, so the
  /// earlier 30 deg tolerance was set above the thing it was meant to catch.
  final double pitchThresholdDegrees;

  /// Yaw past which a turn is unambiguous, and the [consecutiveFrameThreshold]
  /// wait is bypassed.
  ///
  /// It is the line past which a student cannot be reading the screen at all, so
  /// no amount of extra confirmation is worth delaying the warning for. With the
  /// one-frame threshold (see [consecutiveFrameThreshold]) every turn past the
  /// ordinary tolerance is already immediate, so this no longer changes the
  /// timing; it stays as the documented unambiguous line, and as the rule that
  /// keeps a near-sideways turn immediate if the frame count is ever raised to
  /// absorb a noisier detector.
  ///
  /// Must be at least [offCenterThresholdDegrees] (asserted): this may only
  /// shorten the wait for a clearly turned head, never flag a glance.
  final double immediateAwayThresholdDegrees;

  /// How many **consecutive frames** have to show a head past the yaw/pitch
  /// tolerances before [GazeSignal.lookingAway] is reported.
  ///
  /// One: a single frame past the tolerance is a strike, matching the browser
  /// monitor's ~300 ms look-away rule (`web_face_presence.dart`). The audit's
  /// finding was that the old three-frame count (~0.45 s at the default ~7 FPS)
  /// let a student read a question off a second screen, or glance down at a phone,
  /// and be back before the camera ever said anything - the detector saw it and
  /// threw it away.
  ///
  /// Kept configurable and frame-counted rather than timed so the strictness is a
  /// property of the evidence (what the detector saw) and not of the throttle:
  /// raising it to 2-3 is the knob for a device whose Euler estimates are noisy.
  /// A frame back inside the tolerances resets the count, and the episode flag is
  /// what keeps one sustained look-away to one strike.
  final int consecutiveFrameThreshold;

  /// How many **consecutive frames** without a face before [GazeSignal.noFace] is
  /// reported.
  ///
  /// Three, unlike [consecutiveFrameThreshold]: a missing *face* is the one signal
  /// a working detector also produces by accident - a blink behind glasses, a hand
  /// passing the lens, one frame of motion blur - so it is worth confirming, and
  /// three frames is ~0.45 s at the default rate, far short of the time it takes to
  /// actually leave the camera's view. Any frame with a face in it resets the
  /// count, so only an unbroken absence is reported.
  final int missingFaceFrameThreshold;

  /// How long the student has to be *alone* in frame before a second person can
  /// be reported again.
  ///
  /// The other end of a multi-face episode: the signal itself is immediate (two
  /// faces is not something to wait on), and this is what decides that the
  /// episode is over. See [_multipleFacesFlagged] for why the latch needs a
  /// boundary at all.
  final Duration multipleFacesCooldown;

  /// Injectable time source. Only the multi-face cooldown and the frame throttle
  /// below read it, but they read it directly, so a test can exercise either
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

  /// Consecutive-frame bookkeeping. Each condition gets its own counter plus an
  /// "already flagged" latch, so one long episode yields exactly one signal - the
  /// student has to come back before the same condition can be reported again.
  /// That is what stops a sustained absence or head turn from stacking up
  /// disqualification flags.
  int _offCenterFrames = 0;
  int _faceMissingFrames = 0;
  bool _lookAwayFlagged = false;
  bool _noFaceFlagged = false;

  /// When the most recent two-face frame was seen, and whether the multi-face
  /// signal has already been reported for the current episode.
  ///
  /// [GazeSignal.multipleFaces] has no frame threshold - two people in frame is
  /// unambiguous the moment it is seen, and making the student wait would be
  /// worse. The episode boundary is the opposite condition instead: the latch
  /// re-arms only after [multipleFacesCooldown] with a single face in frame,
  /// measured from the *last* two-face frame, so a detector flickering between
  /// one and two faces at the edge of the frame keeps pushing that boundary out.
  /// Without the latch the signal was emitted once per inference (~7 a second at
  /// [inferenceInterval]) and the server's three-strike rule closed the attempt
  /// within a second of a guest leaning into shot.
  DateTime? _multipleFacesAt;
  bool _multipleFacesFlagged = false;

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
  /// deliberately dumb — no frame counting, no angle math — because its only job
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
  /// was lost - [onCameraFrame] ignores incoming frames and every counter is
  /// cleared, so an offline camera can never be mistaken for a missing
  /// face. Turning it back on restarts the counting from scratch.
  void setStreamActive(bool active) {
    _streamActive = active;
    if (!active) resetSustained();
  }

  /// Clears every consecutive-frame counter and latch. Called when the camera
  /// goes offline (see [setStreamActive]) and whenever the notifier pauses
  /// tracking, so resuming never inherits a half-counted episode.
  ///
  /// The multi-face latch goes with them: a feed that comes back with two people
  /// in front of it is a fresh episode, and carrying the cooldown across the gap
  /// would hide the guest who arrived while the camera was down.
  void resetSustained() {
    _offCenterFrames = 0;
    _faceMissingFrames = 0;
    _multipleFacesAt = null;
    _lookAwayFlagged = false;
    _noFaceFlagged = false;
    _multipleFacesFlagged = false;
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

    // The injected clock, the same one the multi-face cooldown below is measured
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
    // ML Kit has no web implementation (`dart:io`'s Platform would throw in a
    // browser anyway), so a web session produces no face signals — run it with
    // MOCK_CAMERA=true or accept camera-only monitoring.
    if (kIsWeb) return null;

    // ML Kit's detector is a mobile-only plugin.
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return null;
    }

    // `ImageFormat.raw` is the platform's own constant: an int on both mobile
    // backends (NV21/YUV420 on the CameraX side, BGRA8888 on AVFoundation).
    // Anything else is a buffer ML Kit has no format for, so the frame reads as
    // unreadable rather than being forced into an int.
    final rawValue = image.format.raw;
    if (rawValue is! int) return null;
    final raw = InputImageFormatValue.fromRawValue(rawValue);

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return raw == InputImageFormat.bgra8888
          ? InputImageFormat.bgra8888
          : null;
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

  /// Feeds one inference result through the frame-count/debounce logic.
  ///
  /// Exposed beyond [onCameraFrame] so the consecutive-frame threshold can be
  /// unit-tested without a camera or ML Kit.
  @visibleForTesting
  void handleResult(FaceFrameResult result) => _handleResult(result);

  /// Applies the consecutive-frame rules to one detection result.
  ///
  /// [GazeSignal.lookingAway] is reported from the **first** frame past the yaw or
  /// pitch tolerance ([consecutiveFrameThreshold] is one): a head turned that far
  /// is not something a student does by accident, and waiting for more frames only
  /// gives a glance at a second screen somewhere to hide. [GazeSignal.noFace]
  /// still waits for [missingFaceFrameThreshold] frames without a face, because a
  /// working detector drops a single frame (a blink behind glasses, a hand across
  /// the lens) on its own. Each episode emits at most once, so a sustained
  /// look-away or a face that stays out of frame is one strike, not one per
  /// inference.
  ///
  /// The first exception is a head turned past [immediateAwayThresholdDegrees]:
  /// that cannot be a glance, so it bypasses the frame count even if that count is
  /// raised for a noisier detector. Any frame back in the tolerated state - a
  /// visible face, a centered head - resets the counters, so nothing accumulates
  /// across separate glances.
  ///
  /// [GazeSignal.multipleFaces] is the other condition with no frame threshold
  /// (two people in frame needs no measuring), so it is latched instead: one
  /// episode, and the episode ends only once the student has been alone in frame
  /// for [multipleFacesCooldown].
  void _handleResult(FaceFrameResult result) {
    // An inference that was already on the wire when the session ended still
    // lands here: `onCameraFrame` fire-and-forgets it (`.then(_handleResult)`), so
    // a frame captured before the page was popped can arrive after [dispose] ran.
    // Adding to the closed controller throws into that detached chain, and the
    // counters underneath measure a session that no longer exists.
    if (_disposed || _signalController.isClosed) return;

    final now = _clock();

    if (result.faceCount == 0) {
      // Face missing: [missingFaceFrameThreshold] frames in a row without one
      // becomes noFace. Without a face the head can no longer be "off centre", so
      // those counters start over.
      _offCenterFrames = 0;
      _lookAwayFlagged = false;

      _faceMissingFrames++;
      if (!_noFaceFlagged &&
          _faceMissingFrames >= missingFaceFrameThreshold) {
        _noFaceFlagged = true;
        _signalController.add(GazeSignal.noFace);
      }
      return;
    }

    // A face is visible again: close the missing-face episode so a later
    // absence is counted (and reported) from scratch.
    _faceMissingFrames = 0;
    _noFaceFlagged = false;

    if (result.faceCount > 1) {
      // Two people in frame is unambiguous, so it is reported immediately
      // rather than after a frame count - but once per episode, like the
      // counted conditions above. One guest leaning into shot is one
      // violation; the latch is what stops it being one *per inference*, which
      // is how a single second of it used to reach the server's three-strike
      // limit and disqualify the attempt.
      _offCenterFrames = 0;
      _lookAwayFlagged = false;
      _multipleFacesAt = now;
      if (_multipleFacesFlagged) return;
      _multipleFacesFlagged = true;
      _signalController.add(GazeSignal.multipleFaces);
      return;
    }

    // Exactly one face: the state that *ends* a multi-face episode, once
    // [multipleFacesCooldown] has passed since the last two-face frame. A
    // detector flickering between one and two faces at the frame edge keeps
    // resetting that clock, so it cannot re-arm the latch and re-open the burst.
    final lastMultipleFaces = _multipleFacesAt;
    if (_multipleFacesFlagged &&
        (lastMultipleFaces == null ||
            now.difference(lastMultipleFaces) >= multipleFacesCooldown)) {
      _multipleFacesFlagged = false;
      _multipleFacesAt = null;
    }

    final yaw = result.yawDegrees ?? 0;
    final pitch = result.pitchDegrees ?? 0;
    final isOffCenter = yaw.abs() > offCenterThresholdDegrees ||
        pitch.abs() > pitchThresholdDegrees;

    if (!isOffCenter) {
      // Back inside the tolerances: whatever was building is off, and this is
      // also the signal that re-arms looking_away for a later episode.
      _offCenterFrames = 0;
      _lookAwayFlagged = false;
      _signalController.add(GazeSignal.centered);
      return;
    }

    _offCenterFrames++;
    // A single frame past the tolerance is a strike ([consecutiveFrameThreshold]),
    // and a near-sideways turn past [immediateAwayThresholdDegrees] is reported
    // even if that count is raised for a noisier detector: there is no reading of
    // the screen either could still be.
    final isUnambiguousTurn = yaw.abs() > immediateAwayThresholdDegrees;
    if (!_lookAwayFlagged &&
        (isUnambiguousTurn ||
            _offCenterFrames >= consecutiveFrameThreshold)) {
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
