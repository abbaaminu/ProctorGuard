import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'look_away_burst_window.dart';
import 'proctoring_thresholds.dart' as thresholds;

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
    this.offCenterThresholdDegrees = thresholds.lookAwayYawDegrees,
    this.pitchThresholdDegrees = thresholds.lookAwayPitchDegrees,
    this.lookAwaySustain = thresholds.lookAwaySustain,
    this.returnDwell = thresholds.lookAwayNativeReturnDwell,
    this.immediateYawDegrees = thresholds.lookAwayImmediateYawDegrees,
    this.immediateFrameThreshold = thresholds.lookAwayImmediateFrames,
    this.startupGrace = thresholds.cameraStartupGrace,
    this.consecutiveFrameThreshold = 1,
    this.missingFaceFrameThreshold = thresholds.missingFaceFrameThreshold,
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
          !lookAwaySustain.isNegative,
          'a negative sustain would report a look-away it has not seen yet',
        ),
        assert(
          immediateYawDegrees >= offCenterThresholdDegrees,
          'a fast path inside the tolerance would report every off-centre frame',
        ),
        assert(
          immediateFrameThreshold > 1,
          'a single near-sideways frame is what this path exists to confirm',
        ),
        assert(
          !startupGrace.isNegative,
          'a negative grace would time out before the sitting starts',
        ),
        assert(
          !returnDwell.isNegative,
          'a negative dwell would end a look-away before it was seen',
        ),
        assert(
          returnDwell < lookAwaySustain,
          'a dwell as long as the sustain would end every episode before it '
          'could be reported',
        ),
        _lookAwayBurst = LookAwayBurstWindow(sustain: lookAwaySustain),
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

  /// Yaw (left/right head turn) tolerance in degrees - [thresholds.lookAwayYawDegrees]
  /// (15) unless a device needs its own.
  ///
  /// 15 degrees is where the head has visibly stopped facing the screen, and it is
  /// what stops a second screen beside the laptop from being free (that is a 25-45
  /// degree turn at a normal viewing distance, comfortably past this). The false
  /// positives that a strict angle brings in - a glance at the keyboard, a nod - are
  /// answered by the *duration*, not by loosening the angle: anything past this has
  /// to be *held* for [lookAwaySustain] before it is reported, unless it is
  /// near-sideways ([immediateYawDegrees]), where two frames are enough. An earlier
  /// version widened the angle to 25 instead while keeping a single frame as a
  /// strike, which flagged turns a student could not explain and taught them to
  /// ignore the warning.
  ///
  /// Judged on the absolute angle, so a turn to either side is one rule.
  final double offCenterThresholdDegrees;

  /// Pitch (up/down head tilt) tolerance in degrees -
  /// [thresholds.lookAwayPitchDegrees] (15), the same angle as the yaw.
  ///
  /// Equal to the yaw on purpose, and absolute in both directions. Reading the
  /// question on screen and typing both lower the chin a few degrees, so a 15
  /// degree tilt down is ordinary exam behaviour - which is exactly what
  /// [lookAwaySustain] is for. The asymmetric pair this replaced (25 yaw, 18 pitch)
  /// judged a tilt down differently from a tilt up, and which direction a detector
  /// calls "down" differs between ML Kit and the web's FaceLandmarker, so two
  /// tolerances also meant two verdicts for one head.
  final double pitchThresholdDegrees;

  /// How long a head has to stay past [offCenterThresholdDegrees] /
  /// [pitchThresholdDegrees] - across consecutive frames, with no frame back
  /// inside the tolerances - before [GazeSignal.lookingAway] is reported.
  ///
  /// [thresholds.lookAwaySustain]: two seconds. This is the rule the audit's
  /// "single frame is a strike" version got wrong in the other direction. One frame
  /// at ~7 FPS is 150 ms: a blink, a notification sliding in, or the detector
  /// itself being wrong. Two seconds of an unbroken turn is not a reading position,
  /// and it is still short enough to catch somebody working from a second screen
  /// while they are doing it.
  ///
  /// A frame back inside the tolerances ends the episode and restarts the clock,
  /// once the return has been confirmed for [returnDwell] - so a head that merely
  /// flickers across the line does not clear the clock, and a turn that sits a
  /// degree over the tolerance is still measured. That does **not** make repeated
  /// glances free: [_lookAwayBurst] counts them separately (three glances, or five
  /// seconds off screen, inside a minute), so this rule catches the turn that is
  /// held and the window catches the student who keeps returning to the same
  /// off-screen place.
  ///
  /// The hold is not the *only* route to a strike: a turn past [immediateYawDegrees]
  /// is near-sideways and is confirmed in [immediateFrameThreshold] frames, which is
  /// what keeps the detector feeling immediate for the turns that have no innocent
  /// reading. Everything below that angle still has to earn this duration.
  final Duration lookAwaySustain;

  /// How long the head has to be *back inside* the tolerances before the look-away
  /// episode is judged over.
  ///
  /// [thresholds.lookAwayNativeReturnDwell]: 300 ms, two frames. The mirror image of
  /// [thresholds.lookAwayWebReturnDwell] on the browser, and for the same reason: a
  /// single frame inside the tolerances is a sample, not a return. ML Kit's Euler
  /// estimates wobble by a degree or two, so a head held just past
  /// [thresholds.lookAwayYawDegrees] reads inside the tolerances now and then, and if
  /// one such frame ended the episode the hold could never be completed - the browser
  /// reported that student and the phone did not.
  ///
  /// Confirmed, not assumed: the head is seen inside and then not seen outside for
  /// this long, and the episode is still measured to the *first* frame back inside, so
  /// the flicker is not added to anyone's time away and the glance banked by
  /// [_lookAwayBurst] is the time the head was actually turned. A frame back outside
  /// before the dwell is satisfied simply continues the same episode.
  ///
  /// Asserted to be shorter than [lookAwaySustain]: a dwell that long would end every
  /// episode before it could ever be reported.
  final Duration returnDwell;

  /// Yaw past which a turn is *near-sideways*, and so is confirmed in
  /// [immediateFrameThreshold] consecutive frames instead of being held for
  /// [lookAwaySustain].
  ///
  /// [thresholds.lookAwayImmediateYawDegrees]: 30 degrees. This is the responsiveness
  /// half of the rule. At 30 degrees the head is no longer pointing at the screen at
  /// all - a second screen beside the laptop, a phone in the lap, someone being
  /// spoken to - and making that student wait two seconds is what made the detection
  /// feel asleep; waiting two frames (~0.3 s at the default frame rate) is enough to
  /// know it is not a single bad estimate.
  ///
  /// Yaw only. "Sideways" is what yaw measures, pitch is where the two detectors
  /// disagree about sign, and a 30 degree *nod* is not evidence of another screen.
  /// Judged on the absolute angle, so either side is the same rule.
  final double immediateYawDegrees;

  /// How many consecutive frames past [immediateYawDegrees] confirm the turn - two.
  ///
  /// A count rather than a duration, so the same number means the same thing to this
  /// engine (~150 ms apart) and to `WebFacePresenceMonitor` (a 350 ms tick), and
  /// asserted above to be more than one: the whole point of the path is that one
  /// frame is never enough. Unlike [consecutiveFrameThreshold] it is *not* a floor
  /// under a duration - it is the complete evidence for a near-sideways turn.
  final int immediateFrameThreshold;

  /// How long after the sitting's first frame nothing is judged at all.
  ///
  /// [thresholds.cameraStartupGrace]: five seconds, from the first frame the engine
  /// judges. A student is still moving the camera into place when the paper opens,
  /// and a phone used to log a `looking_away` or a `no_face` while its owner was
  /// doing exactly that - the browser was the forgiving platform, by accident, and
  /// this is the engine catching up with it rather than the other way round.
  ///
  /// Counted from [_firstFrameAt] rather than from construction, so a camera that
  /// takes a while to open does not spend the window while it is still black; and
  /// not restarted by [resetSustained], so a feed that drops out and returns
  /// mid-sitting is examined on the frames it produces next instead of handing out
  /// another five unwatched seconds. Nothing is reported inside the window,
  /// [GazeSignal.multipleFaces] included, and nothing is missed by it: whatever was
  /// happening is still happening when it ends.
  final Duration startupGrace;

  /// How many **consecutive frames** must also be off-centre before
  /// [GazeSignal.lookingAway] is reported.
  ///
  /// A floor under [lookAwaySustain], not the timing rule: at the default frame
  /// rate two seconds is a dozen frames, so this only matters for a device whose
  /// clock barely advances between frames (a stalled feed, a test). Raising it is
  /// the knob for a detector that produces a burst of identical estimates.
  final int consecutiveFrameThreshold;


  /// How many **consecutive frames** without a face before [GazeSignal.noFace] is
  /// reported.
  ///
  /// `thresholds.missingFaceFrameThreshold` - three, unlike
  /// [consecutiveFrameThreshold]: a missing *face* is the one signal a working
  /// detector also produces by accident - a blink behind glasses, a hand passing the
  /// lens, one frame of motion blur - so it is worth confirming, and three frames is
  /// ~0.45 s at the default rate, far short of the time it takes to actually leave
  /// the camera's view. Any frame with a face in it resets the count, so only an
  /// unbroken absence is reported. The browser bridge quotes the same constant (see
  /// [WebFacePresenceMonitor.missingFrameTolerance] in `web_face_presence.dart`), so
  /// the two platforms cannot drift apart on the count.
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

  /// Consecutive frames past [immediateYawDegrees] - the evidence for the
  /// near-sideways fast path, counted separately from [_offCenterFrames] because it
  /// is confirmed by a count rather than by [_lookAwaySince], and reset wherever
  /// the head is no longer near-sideways (or is no longer there at all).
  int _immediateFrames = 0;

  /// When the current off-centre episode began - the first frame in the unbroken
  /// run whose head was past the tolerances.
  ///
  /// This is what [lookAwaySustain] is measured against. Null outside an episode;
  /// a frame back inside the tolerances for [returnDwell] (or one without a face,
  /// or with two) ends the episode and sets it back to null, so the clock only ever
  /// covers *consecutive* off-centre frames - with a flicker across the line
  /// forgiven, never a gap of more than [returnDwell].
  DateTime? _lookAwaySince;

  /// When the head was first seen back inside the tolerances in the current
  /// episode, or null when it is not currently inside them.
  ///
  /// The phone's version of `WebFacePresenceMonitor._insideSince`: the first frame
  /// back is a question rather than an answer, [returnDwell] is measured from it and
  /// checked again on every later frame inside the tolerances. Cleared by any
  /// off-centre frame, so a flicker across the tolerance continues the same episode;
  /// cleared with the episode, so a later return starts its own dwell.
  DateTime? _insideSince;

  /// The rolling half of the look-away rule, beside [_lookAwaySince]:
  /// [thresholds.lookAwayBurstCount] glances of at least
  /// [thresholds.lookAwayMinEpisode] each, or
  /// [thresholds.lookAwayBurstCumulative] of off-screen time in total, inside
  /// [thresholds.lookAwayBurstWindow] are also one `lookingAway`.
  ///
  /// Shared with `WebFacePresenceMonitor` (`LookAwayBurstWindow`) rather than
  /// reimplemented, so a browser and a phone count the same glances the same way.
  /// The sustained rule is untouched by it: an episode that reaches
  /// [lookAwaySustain] belongs to that rule and is not recorded here, and a strike
  /// from either rule empties this window.
  final LookAwayBurstWindow _lookAwayBurst;

  /// When the first frame of the sitting reached the engine - the anchor for
  /// [startupGrace], set once and never cleared (see [resetSustained]).
  DateTime? _firstFrameAt;

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
  /// goes offline (see [setStreamActive]), whenever the notifier pauses tracking,
  /// and on every frame inside [startupGrace], so resuming never inherits a
  /// half-counted episode.
  ///
  /// The multi-face latch goes with them: a feed that comes back with two people
  /// in front of it is a fresh episode, and carrying the cooldown across the gap
  /// would hide the guest who arrived while the camera was down.
  ///
  /// The rolling look-away window goes too ([_lookAwayBurst]): a camera that was
  /// not delivering saw no glances, so the evidence behind a burst strike must not
  /// survive the gap and be spent on the first frame that comes back.
  ///
  /// The start-up anchor ([_firstFrameAt]) is deliberately *not* cleared: a
  /// sitting's grace window is spent once, and a counter reset that re-armed it
  /// would make five unwatched seconds available on demand.
  void resetSustained() {
    _offCenterFrames = 0;
    _faceMissingFrames = 0;
    _multipleFacesAt = null;
    _lookAwayFlagged = false;
    _noFaceFlagged = false;
    _multipleFacesFlagged = false;
    // The near-sideways count is evidence about frames that were seen, so it goes
    // with the counters: a feed that comes back must not inherit half a confirmation.
    _immediateFrames = 0;
    // The episode clock goes with the counters: a feed that comes back has seen
    // nothing for the whole gap, so a turn it finds on the next frame must start
    // its two seconds there rather than inherit the seconds before the drop.
    _lookAwaySince = null;
    // ...and so does the pending return: whether the head was back at the screen
    // before the gap is not evidence about the frames after it.
    _insideSince = null;
    // ...and so does the rolling window: a camera that was not delivering saw no
    // glances, so the evidence behind a burst strike must not survive the gap.
    _lookAwayBurst.clear();
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

  /// Applies the look-away and missing-face rules to one detection result.
  ///
  /// [GazeSignal.lookingAway] is reported once the head has stayed past
  /// [offCenterThresholdDegrees] / [pitchThresholdDegrees] for [lookAwaySustain]
  /// *and* [consecutiveFrameThreshold] frames, with no confirmed return to the
  /// tolerances in between (`_lookAwaySince`, ended only by [returnDwell] of frames
  /// back inside them). A single glance, a blink and a notification therefore
  /// produce nothing, which is the point: the old single-frame rule turned every one
  /// of them into a strike, and a student warned for glancing at their own keyboard
  /// learns to ignore the warning.
  ///
  /// The angles are judged as the detector reports them, with no median or moving
  /// average of its own. The browser does filter - `smoothedPose` in
  /// `web/proctor_face_detector.js` medians the last three readings - because its
  /// angle is derived from landmark geometry, where one landmark's jitter moves the
  /// answer. ML Kit hands back a fitted head pose, and filtering it again would buy
  /// a little stillness for a frame or two of latency on every turn, including the
  /// near-sideways ones the fast path exists to make immediate. What a fitted pose
  /// still does is wobble *across the tolerance line*, and that is what [returnDwell]
  /// is for.
  ///
  /// [GazeSignal.lookingAway] is *also* reported from the rolling window beside
  /// that rule ([_lookAwayBurst]): [thresholds.lookAwayBurstCount] separate glances
  /// of at least [thresholds.lookAwayMinEpisode], or
  /// [thresholds.lookAwayBurstCumulative] of off-screen time in total, inside
  /// [thresholds.lookAwayBurstWindow]. A student reading a printed sheet, the
  /// screen, and the sheet again never holds one unbroken turn, so the sustained
  /// rule alone cannot see them; the window is what makes the repeated glance
  /// count - once, not once per glance, because the strike empties it. A run long
  /// enough for [lookAwaySustain] is not banked by it, so a held turn is still one
  /// strike rather than two.
  ///
  /// A turn past [immediateYawDegrees] is the one exception, and it is a *confirmation*
  /// rather than an exemption: the head is far enough round that no reading position
  /// explains it, so [immediateFrameThreshold] consecutive frames past that line report
  /// it without waiting for [lookAwaySustain] - about 0.3 s on a phone, instead of the
  /// two seconds that made an obviously turned head look unjudged. Two frames rather
  /// than one, because the detector can put a face 60 degrees off from one bad estimate;
  /// and yaw only, because a deep nod is reading, not another screen. Below the line
  /// nothing changes: the hold is what separates a glance from a look-away.
  ///
  /// [GazeSignal.noFace] still waits for [missingFaceFrameThreshold] frames without
  /// a face, because a working detector drops a single frame (a blink behind
  /// glasses, a hand across the lens) on its own. Each episode emits at most once,
  /// so a sustained look-away or a face that stays out of frame is one strike, not
  /// one per inference. Any frame back in the tolerated state - a visible face, a
  /// head that is not the student's alone - resets the counters and the episode
  /// clock, and so does a centred head, but only once it has *stayed* inside the
  /// tolerances for [returnDwell]: one frame back is a sample, and letting it clear
  /// the clock is what made the phone miss turns the browser reported. The episode
  /// clock is what the two-second rule measures, and it is the window, not the clock,
  /// that remembers a glance that has ended.
  ///
  /// [GazeSignal.multipleFaces] is the other condition with no threshold (two
  /// people in frame needs no measuring), so it is latched instead: one episode,
  /// and the episode ends only once the student has been alone in frame for
  /// [multipleFacesCooldown].
  ///
  /// Nothing at all is reported during [startupGrace], which is measured from the
  /// sitting's first frame: a student is still arranging the camera when the paper
  /// opens, and every one of those frames clears the counters instead of counting
  /// towards a strike (`multiple_faces` included - the person helping position the
  /// lens is not evidence about the student).

  void _handleResult(FaceFrameResult result) {
    // An inference that was already on the wire when the session ended still
    // lands here: `onCameraFrame` fire-and-forgets it (`.then(_handleResult)`), so
    // a frame captured before the page was popped can arrive after [dispose] ran.
    // Adding to the closed controller throws into that detached chain, and the
    // counters underneath measure a session that no longer exists.
    if (_disposed || _signalController.isClosed) return;

    final now = _clock();

    // The start-up window. Anchored on the first frame the engine is asked to
    // judge - not on construction, and not on `setStreamActive`, which flips with
    // the camera - so the five seconds are spent watching a camera that works
    // rather than a preview that has not opened yet.
    final firstFrameAt = _firstFrameAt ??= now;
    if (now.difference(firstFrameAt) < startupGrace) {
      // Cleared rather than banked: the first frame judged after the window starts
      // its own episode, so a head that happened to be turned while the student was
      // setting up is not already 4.9 seconds into a strike.
      resetSustained();
      return;
    }

    if (result.faceCount == 0) {
      // Face missing: [missingFaceFrameThreshold] frames in a row without one
      // becomes noFace. Without a face the head can no longer be "off centre", so
      // those counters - and the look-away episode clock - start over.
      _offCenterFrames = 0;
      _immediateFrames = 0;
      _lookAwaySince = null;
      _insideSince = null;
      _lookAwayFlagged = false;
      _lookAwayBurst.abandonEpisode();

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
      _immediateFrames = 0;
      _lookAwaySince = null;
      _insideSince = null;
      _lookAwayFlagged = false;
      _lookAwayBurst.abandonEpisode();
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
      // Back inside the tolerances.
      //
      // A single frame inside them is a sample, not a return. ML Kit's Euler
      // estimates wobble by a degree or two, so a head held just past
      // [offCenterThresholdDegrees] reads inside it every few frames - and if one
      // such frame ended the episode, the clock [lookAwaySustain] is measured
      // against would never survive two seconds and the phone would report nothing
      // for a turn the browser reports. So the return is *confirmed*: the head is
      // seen inside the tolerances, and then not seen outside them for [returnDwell].
      //
      // Nothing is charged for the flicker, and nothing is lost by it either: the
      // episode keeps its clock, and when the return is confirmed it is closed at
      // the *first* frame back inside, so the time it took to be sure is not part of
      // anyone's glance.
      var returnedAt = now;
      final insideSince = _insideSince;
      if (_lookAwaySince != null && returnDwell > Duration.zero) {
        if (insideSince == null) {
          // The first frame back: the near-sideways run is over (a later turn has to
          // be confirmed twice of its own), but the episode clock is left where it
          // is - whether this is a return or a flicker is the question the dwell
          // asks. Silent for the same reason: the episode is not over yet.
          _offCenterFrames = 0;
          _immediateFrames = 0;
          _insideSince = now;
          return;
        }
        if (now.difference(insideSince) < returnDwell) return;
        returnedAt = insideSince;
      }

      // Whatever was building is off, and this is also the signal that re-arms
      // looking_away for a later episode. The episode clock restarts from the next
      // off-centre frame, which is what makes the sustain "consecutive frames"
      // rather than "total time in the sitting".
      _offCenterFrames = 0;
      _immediateFrames = 0;
      _lookAwaySince = null;
      _insideSince = null;
      _lookAwayFlagged = false;
      // A return inside the tolerances *ends* a glance rather than pausing it,
      // which is where the rolling window learns how long that glance lasted. It
      // is also the last moment at which the third glance of the minute can be
      // counted, so the frame that closes it is the one that carries the signal -
      // emitting a frame later would make a rule about a minute's behaviour look
      // like a rule about the head that happens to be on screen at that instant.
      //
      // The strike consumes the glances it came from, and the latch stays clear
      // because this frame also says the head is back: the episode is over, so
      // the very next glance is a new one rather than a repeat.
      if (_lookAwayBurst.closeEpisode(returnedAt)) {
        _lookAwayBurst.clear();
        _signalController.add(GazeSignal.lookingAway);
        return;
      }
      _signalController.add(GazeSignal.centered);
      return;
    }

    _offCenterFrames++;
    // The head is past the tolerances again, so whatever return was being proved is
    // not one: the episode carries on with the clock it already had, which is what
    // lets a run that flickers over the line still accumulate
    // [lookAwaySustain]'s worth of looking away.
    _insideSince = null;
    // The near-sideways path's own evidence: consecutive frames past
    // [immediateYawDegrees], broken by any frame that is not (which is also every
    // frame inside the tolerances, so the reset above covers the common case).
    final nearSideways = yaw.abs() > immediateYawDegrees;
    _immediateFrames = nearSideways ? _immediateFrames + 1 : 0;

    // The first frame of the run starts the clock; every later frame in the same
    // run leaves it alone.
    final since = _lookAwaySince ??= now;
    final sustained = now.difference(since) >= lookAwaySustain;

    // Two ways to have enough evidence: held for [lookAwaySustain] on at least
    // [consecutiveFrameThreshold] frames, or near-sideways on
    // [immediateFrameThreshold] frames in a row. Both are "seen more than once",
    // which is the line between a person and a detector artefact. One episode is
    // one strike - the latch keeps a held turn from becoming one violation per
    // inference, whichever route confirmed it.
    final confirmed = nearSideways
        ? _immediateFrames >= immediateFrameThreshold
        : sustained && _offCenterFrames >= consecutiveFrameThreshold;
    if (!_lookAwayFlagged && confirmed) {
      _lookAwayFlagged = true;
      // This turn is the sustained rule's strike, so it stops being counted in the
      // rolling window: one turn is one strike, not two, and the next burst has to
      // earn its own evidence.
      _lookAwayBurst.clear();
      _signalController.add(GazeSignal.lookingAway);
      return;
    }

    // The rolling half. This frame is still off screen, so the glance is still
    // open and the off-screen total it contributes may already be the fifth
    // second - which is why the total is judged here and not only when the glance
    // ends. Guarded by the same latch as the sustained rule, so a turn that has
    // already been reported cannot report again a few frames later.
    if (!_lookAwayFlagged && _lookAwayBurst.observeOffScreen(now)) {
      _lookAwayFlagged = true;
      _lookAwayBurst.clear();
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
