import 'dart:async';

import 'look_away_burst_window.dart';
import 'mediapipe_proctoring_service.dart' show GazeSignal;
import 'proctoring_thresholds.dart' as thresholds;
import 'web_face_signal_source.dart';

/// The words a host detector speaks.
///
/// Strings rather than an enum because the speaker is JavaScript: a host has to
/// be able to say `window.proctorGuardFaceSignal('looking_away')` without
/// importing anything from this app's Dart. The four verdicts are exactly the
/// on-device engine's `GazeSignal`s, so a browser episode and a phone episode
/// enter the notifier through the same door.
abstract final class WebFaceMessages {
  /// A face is visible and within the head-pose tolerances.
  static const String centered = 'centered';

  /// A face is visible but the head is turned far enough away to be a
  /// `looking_away` episode if it stays there.
  static const String lookingAway = 'looking_away';

  /// No face in frame: `no_face` if it lasts.
  static const String noFace = 'no_face';

  /// More than one face in frame. Reported at once (see
  /// [WebFacePresenceMonitor.handleMessage]).
  static const String multipleFaces = 'multiple_faces';

  /// Optional head pose instead of a verdict: `pose:<yaw>,<pitch>` in degrees.
  /// A detector that measures angles lets this class apply the same tolerances
  /// the on-device engine does, instead of trusting the page's own threshold.
  ///
  /// The sign is part of the message, because the browser's tolerances are not
  /// symmetric: **positive pitch is a chin down**, the convention the shipped
  /// `web/proctor_face_detector.js` reports on both of its measurement routes, and
  /// [WebFacePresenceMonitor.downwardPitchDegrees] is the wider side. Yaw's sign is
  /// unused - it is judged on the absolute angle - so a host may pick either
  /// handedness there.
  static const String posePrefix = 'pose:';
}

/// Turns a host page's face detections into the same sustained [GazeSignal]s the
/// on-device engine emits, so a browser look-away is worth the same strike as a
/// phone's.
///
/// The web build cannot run ML Kit ([WebFaceSignalSource] explains why), so the
/// *detection* is the page's job and this class is the *judgement*: which
/// detections are worth a violation. That split is what keeps the rules in the
/// app rather than in whatever JavaScript a host happens to ship.
///
/// The rules mirror `MediaPipeProctoringService`:
///
///  * `looking_away` has to hold for [lookAwaySustain] before it is reported, and
///    each episode reports once - so one look away is one strike, not one per
///    detection, while a blink or a single dropped frame is nothing;
///  * **unless the turn is near-sideways** (yaw past [immediateYawDegrees]): two
///    consecutive detections are enough there, the same count the engine uses -
///    a head that far round is not a reading position, so the strike lands while
///    the student is still turned instead of two seconds later;
///  * `looking_away` is *also* reported by the rolling window beside that rule
///    ([thresholds.lookAwayBurstCount] separate glances, or
///    [thresholds.lookAwayBurstCumulative] of off-screen time, inside
///    [thresholds.lookAwayBurstWindow]) - the same `LookAwayBurstWindow` the
///    on-device engine runs, so a student reading paper and screen in turn is
///    judged the same way on either platform. A held two seconds is the sustained
///    rule's and is not banked by the window, and a strike empties the window;
///  * `no_face` has to hold for [noFaceSustain], on the same one-report-per-episode
///    rule;
///  * a `centered` message ends the episode and re-arms it, so a *later* look
///    away is reported again;
///  * `multiple_faces` is not sustained (two people need no measuring): it is
///    latched until the student has been alone for [multipleFacesCooldown];
///  * nothing is reported during [startupGrace] - the engine's
///    [thresholds.cameraStartupGrace], shared, so a browser and a phone start judging
///    five seconds in rather than one of them on its first detection.
///
/// The tolerances, the look-away window and the start-up window are the engine's own,
/// shared rather than copied (`proctoring_thresholds.dart`): "turned" means 15 degrees
/// of yaw, "held" the same two seconds, and "starting" the same five, on both
/// platforms - or a browser session and a phone session judge the same head
/// differently, and an appeal is decided by which device the student happened to sit
/// in front of.
///
/// One tolerance is deliberately not shared: [downwardPitchDegrees]. A browser allows
/// a chin five degrees further down than a phone does, because the keyboard a browser
/// student reads lies below the screen while a screen *above* the monitor does not.
/// Yaw and the upward half of the pitch are the engine's numbers exactly, and the
/// phone still compares the absolute pitch in both directions.
///
/// Only the *anchor* of the start-up window has to differ, and it does: a page knows
/// when the attempt opened ([start]), while the engine sees nothing until a camera
/// hands it a frame. Both windows end five seconds after the first thing the platform
/// could judge.
///
/// The difference is the unit of "held", not its length. The engine counts *frames*
/// for the tick of evidence and then requires [thresholds.lookAwaySustain] of them,
/// because a single frame past a tolerance is a detector artefact; a page's detector
/// may run at 2 fps or burst ten results from one buffered frame, so the web measures
/// *elapsed time* against the same window instead. A verdict (`looking_away` as a
/// word) is therefore only filled by a host that keeps sending it, which is what the
/// shipped `web/proctor_face_detector.js` does on every tick.
///
/// **The near-sideways start is shared, and bounded twice.** A `pose:` past
/// [immediateYawDegrees] of yaw is reported after [immediateConfirmations]
/// consecutive detections instead of after [lookAwaySustain]: this is the speed the
/// web used to get from a 30 degree exemption that reported on the *first*
/// detection, which made a browser several times quicker than the phone for the same
/// head. Two confirmations keep the responsiveness and drop the guess - one bad
/// Euler estimate can read 60 degrees, and one detection is a frame, not a student.
/// Below the line nothing changes: the angle says how far, and the hold is still the
/// whole of the finding, with a turn that is not held counted as a glance in the
/// shared rolling window. The rule is yaw only, like the engine's, because a deep nod
/// is reading rather than another screen - which is the case for a wider tolerance
/// and a full hold (see [downwardPitchDegrees]), not for reporting faster.

class WebFacePresenceMonitor {
  WebFacePresenceMonitor({
    required WebFaceSignalSource source,
    this.lookAwaySustain = thresholds.lookAwaySustain,
    this.noFaceSustain = const Duration(milliseconds: 300),
    this.startupGrace = thresholds.cameraStartupGrace,
    this.multipleFacesCooldown = const Duration(seconds: 30),
    // The engine's tolerances, from the one file that states the rule: 15 degrees of
    // yaw, judged absolute, so `pose:15,0` and `pose:-15,0` are both a glance and
    // `pose:16,0` is not. Shared rather than restated - a browser that judged a head
    // differently from the phone would make the platform decide the appeal.
    this.offCenterYawDegrees = thresholds.lookAwayYawDegrees,
    // Pitch's upward half: the engine's 15 degrees, kept exactly, because a chin
    // raised past it is a screen mounted above the monitor. The downward half is the
    // next parameter, and it is the only number here the phone does not share.
    this.offCenterPitchDegrees = thresholds.lookAwayPitchDegrees,
    // The one number a browser does not share with the phone: a chin this far down
    // is still reading, because the keyboard and the paper are below the screen.
    // Web-only by design - the engine keeps 15 in both directions, where ML Kit's
    // pitch sign is unverified - and read from the same file, so it has one home.
    this.downwardPitchDegrees = thresholds.lookAwayWebDownwardPitchDegrees,
    // The near-sideways start, from the same file: past 30 degrees of yaw two
    // consecutive detections are enough. Shared rather than restated, for the same
    // reason as the tolerances - a browser that was quicker than the phone for the
    // same head is the drift this file exists to stop.
    this.immediateYawDegrees = thresholds.lookAwayImmediateYawDegrees,
    this.immediateConfirmations = thresholds.lookAwayImmediateFrames,
    DateTime Function()? clock,
  })  : assert(
          lookAwaySustain > Duration.zero,
          'a zero sustain would flag the first detection of every glance',
        ),
        assert(
          noFaceSustain > Duration.zero,
          'a zero sustain would flag the first empty frame',
        ),
        assert(
          startupGrace >= Duration.zero,
          'a negative grace would time out before the session starts',
        ),
        assert(
          multipleFacesCooldown >= Duration.zero,
          'a negative cooldown would re-arm before it was ever latched',
        ),
        assert(
          offCenterYawDegrees > 0 && offCenterPitchDegrees > 0,
          'a zero tolerance would call every head position off centre',
        ),
        assert(
          downwardPitchDegrees >= offCenterPitchDegrees,
          'a tighter downward tolerance would judge a desk glance harder than a look up',
        ),
        assert(
          immediateYawDegrees >= offCenterYawDegrees,
          'a fast path inside the tolerance would report every off-centre detection',
        ),
        assert(
          immediateConfirmations > 1,
          'a single near-sideways detection is what this path exists to confirm',
        ),
        _source = source,
        _awayBurst = LookAwayBurstWindow(sustain: lookAwaySustain),
        _now = clock ?? DateTime.now {
    _subscription = source.messages.listen(handleMessage);
  }

  /// How long an off-centre head has to hold before it is reported.
  ///
  /// `thresholds.lookAwaySustain` - the engine's own two seconds - because the
  /// finding is the strike: a browser that reported a glance after 300 ms closed a
  /// sitting three times faster than the phone for the same behaviour, which is what
  /// the audit found and called the web's largest false-positive risk. The audit's
  /// own numbers make the case: at the detector's 350 ms tick, a 300 ms window is
  /// filled by the *second* detection, so one glance, one nod or one bad Euler
  /// estimate that happened to be sampled twice was a counted strike.
  ///
  /// Two seconds also survives the thing a browser detector is worst at - a pose that
  /// flickers across the 15 degree line while a head is genuinely moving - because
  /// any detection back inside the tolerance resets the window, exactly as a
  /// `centered` frame does in the engine. Only an unbroken run counts.
  ///
  /// A run that ends early is not lost, though: it is one glance in [_awayBurst],
  /// and the window is what makes repeated glances add up. Resetting this clock is
  /// what keeps two seconds meaning "held", not "wandering".
  final Duration lookAwaySustain;

  /// How long an empty frame has to hold before it is reported as `no_face`.
  ///
  /// Deliberately *not* [lookAwaySustain]: absence is a different question from where
  /// a head is pointing, and the engine confirms it over three consecutive frames
  /// (~0.45 s at its 150 ms interval) rather than waiting two seconds. 300 ms is that
  /// order of magnitude for a detector polled at 350 ms - the second tick is already
  /// past it - and it is unchanged by the parity fix because the audit found nothing
  /// wrong with it: a camera that is covered, muted, unplugged or pointed at an empty
  /// chair should say so at once, and no student earns `no_face` by moving.
  final Duration noFaceSustain;

  /// How long after [start] detections are ignored.
  ///
  /// [thresholds.cameraStartupGrace] - the engine's own five seconds, shared rather
  /// than restated, so a browser and a phone use one window instead of two that
  /// happen to be equal. A student joining an attempt is still adjusting the camera,
  /// and the page's detector may still be reporting frames from before the exam
  /// opened.
  final Duration startupGrace;

  /// How long the student must be alone before another person in frame counts as
  /// a new episode. The same 30 s the engine uses.
  final Duration multipleFacesCooldown;

  /// Head-pose tolerances, used only for `pose:` messages (a detector that sends
  /// a verdict has already applied its own). The engine's numbers - 15 deg of yaw,
  /// 15 deg of pitch up - from `proctoring_thresholds.dart`, so the same head is
  /// judged the same way on either platform apart from the one documented
  /// difference below.
  ///
  /// Yaw is absolute: a turn to either side is one rule. Pitch is *signed* on the
  /// browser, because the two directions do not mean the same thing at a desk: down
  /// is the keyboard and the paper ([downwardPitchDegrees]), up is a screen mounted
  /// above the monitor, which is the second monitor this rule exists to catch. The
  /// sign is stated by the detector that measures it - **positive is a chin down**,
  /// on both routes of `web/proctor_face_detector.js` (its `matrixPose` docblock has
  /// the derivation from MediaPipe's canonical face and its column-major matrix, and
  /// `measurePose` is aligned to it) - and a host page that speaks `pose:` has to
  /// use the same convention. What a *real* face produces is still unverified on
  /// hardware (the root README keeps that risk open), and this rule is shaped so
  /// that being wrong about it costs the five degrees of slack rather than the rule:
  /// the desk glance would then be judged at [offCenterPitchDegrees], exactly as it
  /// is today.
  final double offCenterYawDegrees;
  final double offCenterPitchDegrees;

  /// How far the chin may drop before a browser counts it as looking away:
  /// [thresholds.lookAwayWebDownwardPitchDegrees], five degrees more than
  /// [offCenterPitchDegrees] and only on that side.
  ///
  /// The phone keeps 15 in both directions, so this is the one place where the same
  /// head is judged differently by the two builds - deliberately, and only in the
  /// direction a desk explains. A browser student looks down at a keyboard that lies
  /// below the screen, often on a camera that sits below it too, and the rule that
  /// catches a second screen does not need to catch that; 20 still catches a head
  /// that has stopped reading the paper. The upward half stays at
  /// [offCenterPitchDegrees], and the near-sideways start
  /// ([immediateYawDegrees]) is untouched.
  final double downwardPitchDegrees;

  /// Yaw past which a turn is *near-sideways*: [immediateConfirmations] consecutive
  /// detections report it instead of [lookAwaySustain].
  ///
  /// [thresholds.lookAwayImmediateYawDegrees]: 30 degrees, twice the gate - the head
  /// is no longer facing the screen at all, so making the student wait two seconds
  /// is what made a browser feel unjudged. Yaw only, absolute, and shared with the
  /// engine, so the same head costs the same strike on either platform.
  final double immediateYawDegrees;

  /// How many consecutive detections past [immediateYawDegrees] confirm the turn -
  /// two, the same count `MediaPipeProctoringService.immediateFrameThreshold` uses.
  ///
  /// A detection is not a unit of time here (a page's detector may burst or stall),
  /// which is why the sustained rule measures a duration and this one counts
  /// evidence: "seen twice" means the same thing on both platforms, and it is what
  /// keeps a single bad Euler estimate from being a strike.
  final int immediateConfirmations;

  final WebFaceSignalSource _source;
  final DateTime Function() _now;
  final StreamController<GazeSignal> _signals =
      StreamController<GazeSignal>.broadcast();

  /// The rolling half of the look-away rule, the same `LookAwayBurstWindow` the
  /// on-device engine runs: [thresholds.lookAwayBurstCount] separate glances, or
  /// [thresholds.lookAwayBurstCumulative] of off-screen time, inside
  /// [thresholds.lookAwayBurstWindow].
  ///
  /// It has to be the same object, not a copy of the arithmetic: this class and
  /// `MediaPipeProctoringService` judge one head from two different detections, and
  /// a browser that counted a browser's glances differently would decide the appeal
  /// by platform. A run that reaches [lookAwaySustain] is the sustained rule's and is
  /// not banked here, and a strike from either rule empties the window.
  final LookAwayBurstWindow _awayBurst;

  StreamSubscription<String>? _subscription;

  DateTime? _startedAt;
  DateTime? _awaySince;
  DateTime? _missingSince;
  DateTime? _secondPersonAt;
  bool _awayFlagged = false;
  bool _missingFlagged = false;
  bool _multipleFacesFlagged = false;
  bool _disposed = false;

  /// Consecutive `pose:` detections past [immediateYawDegrees] - the near-sideways
  /// evidence, reset by any detection that is not past that line (including a
  /// centered one, a missing face and a second person).
  int _immediateDetections = 0;

  /// True once the host hook exists and the monitor is listening.
  bool get isSupported => _source.isSupported;

  /// Whether [start] has run. Detections before it are dropped: there would be
  /// no grace window to measure them against.
  bool get isStarted => _startedAt != null;

  /// The upstream source, for the diagnostics the page and the tests read.
  WebFaceSignalSource get source => _source;

  /// Sustained verdicts, in the same vocabulary as the on-device engine.
  Stream<GazeSignal> get signals => _signals.stream;

  /// Opens the session's grace window and starts judging. Idempotent.
  void start({DateTime? at}) {
    if (_disposed || _startedAt != null) return;
    _startedAt = at ?? _now();
  }

  /// Feeds one host detection.
  ///
  /// The conversion from a source message to a [GazeSignal] lives here rather
  /// than in the web-only source so the rules are testable on the VM, which is
  /// where `flutter test` runs - and so the vocabulary is checked in one place
  /// whether the message came from JavaScript or from Dart.
  void handleMessage(String message, {DateTime? at}) {
    if (_disposed) return;
    final startedAt = _startedAt;
    if (startedAt == null) return;

    final text = message.trim().toLowerCase();
    if (text.isEmpty) return;

    final now = at ?? _now();
    // Inside the grace window nothing can be an accusation yet - and there is no
    // episode to keep alive either, so skipping the whole message loses nothing.
    if (now.difference(startedAt) < startupGrace) return;

    if (text == WebFaceMessages.multipleFaces) {
      _secondPersonAt = now;
      if (_multipleFacesFlagged) return;
      _multipleFacesFlagged = true;
      // One face is no longer the subject: the single-face episodes start over,
      // exactly as they do in the engine.
      _awaySince = null;
      _missingSince = null;
      _awayFlagged = false;
      _missingFlagged = false;
      _immediateDetections = 0;
      _awayBurst.abandonEpisode();
      _emit(GazeSignal.multipleFaces);
      return;
    }

    if (text == WebFaceMessages.noFace) {
      _onMissing(now);
      return;
    }

    if (text == WebFaceMessages.lookingAway) {
      _onAway(now);
      return;
    }

    if (text == WebFaceMessages.centered) {
      _onCentered(now);
      return;
    }

    final pose = text.startsWith(WebFaceMessages.posePrefix)
        ? _parsePose(text.substring(WebFaceMessages.posePrefix.length))
        : null;
    // An unrecognised message is a detector speaking a language this app does
    // not know. Ignoring it is the only honest reading: it is not evidence.
    if (pose == null) return;

    // One rule for a measured head, with two ways to have enough evidence. The
    // angle says how far; past [immediateYawDegrees] the head is near-sideways and
    // [immediateConfirmations] detections in a row are enough, which is the speed the
    // old 30 degree exemption had without its single-detection guess. Everywhere else
    // the hold is the whole of the finding: the angle decides whether the rule applies,
    // and [lookAwaySustain] decides whether it has been earned.
    //
    // Pitch is *signed* here, and only here: negative is a chin up, judged at
    // [offCenterPitchDegrees] because a screen mounted above the monitor is the second
    // screen this rule exists to catch; positive is a chin down, judged at the wider
    // [downwardPitchDegrees] because the keyboard and the paper are down there. Which
    // way round the sign runs is the detector's to state - see
    // [WebFaceMessages.posePrefix] - and it is the one thing this class cannot check.
    final nearSideways = pose.$1.abs() > immediateYawDegrees;
    final pitchedAway = pose.$2 < -offCenterPitchDegrees ||
        pose.$2 > downwardPitchDegrees;
    _immediateDetections = nearSideways ? _immediateDetections + 1 : 0;

    if (nearSideways && _immediateDetections >= immediateConfirmations) {
      _onAway(now, confirmed: true);
      return;
    }
    if (nearSideways || pose.$1.abs() > offCenterYawDegrees || pitchedAway) {
      _onAway(now);
    } else {
      _onCentered(now);
    }
  }

  void _onMissing(DateTime now) {
    // Without a face there is no head pose to judge, so an away episode is over
    // (and re-armable) rather than paused.
    _awaySince = null;
    _awayFlagged = false;
    // Nor is there a near-sideways run: the next frame that finds a turned head
    // starts its confirmation again rather than completing one begun before the gap.
    _immediateDetections = 0;
    // ...and the open glance is over too: it is not evidence of anything, so it is
    // abandoned rather than closed. The glances already recorded stay - they are
    // about the student, not about the frame that happened to be empty.
    _awayBurst.abandonEpisode();

    _missingSince ??= now;
    if (_missingFlagged) return;
    if (now.difference(_missingSince!) < noFaceSustain) return;
    _missingFlagged = true;
    _emit(GazeSignal.noFace);
  }

  /// Judges one off-centre detection.
  ///
  /// [confirmed] is the near-sideways path: the caller has already seen the head past
  /// [immediateYawDegrees] on [immediateConfirmations] consecutive detections, so the
  /// hold is satisfied by that count rather than by the clock. Everything else about
  /// the episode - the latch, the emptied burst window, the open glance - is the same,
  /// because it is the same strike.
  void _onAway(DateTime now, {bool confirmed = false}) {
    // A visible head means the absence episode is over, so a later one is
    // reported again - and a second person in frame may have left.
    _missingSince = null;
    _missingFlagged = false;
    _endMultiFaceEpisode(now);

    _awaySince ??= now;
    if (_awayFlagged) return;
    if (confirmed || now.difference(_awaySince!) >= lookAwaySustain) {
      _awayFlagged = true;
      // The sustained rule's strike: this run is not also banked as a glance.
      _awayBurst.clear();
      _emit(GazeSignal.lookingAway);
      return;
    }
    // The rolling half. The glance is still open, and its off-screen seconds may
    // already be the fifth - which is why the total is judged while the head is
    // still turned, not only once it comes back.
    if (_awayBurst.observeOffScreen(now)) {
      _awayFlagged = true;
      _awayBurst.clear();
      _emit(GazeSignal.lookingAway);
    }
  }

  void _onCentered(DateTime now) {
    _awaySince = null;
    _missingSince = null;
    _awayFlagged = false;
    _missingFlagged = false;
    // The head is back inside the tolerances, so any near-sideways run is over: a
    // later turn has to be confirmed twice of its own.
    _immediateDetections = 0;
    _endMultiFaceEpisode(now);
    // A return inside the tolerances ends the glance, which is what the rolling
    // window needs to know to count it - and the closing message is the one that
    // carries a burst strike, so a rule about a minute's worth of glances is not
    // reported on a detection that shows the head facing the screen.
    //
    // The strike consumes the glances it came from, and the latch stays clear
    // because this message also says the head is back: the episode is over, so the
    // very next glance is a new one rather than a repeat.
    if (_awayBurst.closeEpisode(now)) {
      _awayBurst.clear();
      _emit(GazeSignal.lookingAway);
      return;
    }
    // Emitted like the engine's per-frame `centered`: the notifier ignores it,
    // and it is the observable "the episode is over" for anything that wants to
    // show the student they are being seen.
    _emit(GazeSignal.centered);
  }

  /// Ends a latched `multiple_faces` episode once the student has been alone for
  /// [multipleFacesCooldown].
  ///
  /// Measured from the *last* second-person message, so a detector flickering
  /// between one and two faces at the edge of frame keeps pushing the re-arm out
  /// instead of reopening the episode.
  void _endMultiFaceEpisode(DateTime now) {
    if (!_multipleFacesFlagged) return;
    final seenAt = _secondPersonAt;
    if (seenAt != null && now.difference(seenAt) < multipleFacesCooldown) return;
    _multipleFacesFlagged = false;
    _secondPersonAt = null;
  }

  /// `yaw,pitch` in degrees, or null when the numbers are not numbers.
  ///
  /// Null is deliberate rather than `(0, 0)`: a malformed pose read as "centred"
  /// would quietly end a real looking-away episode.
  static (double, double)? _parsePose(String body) {
    final parts = body.split(',');
    if (parts.length != 2) return null;
    final yaw = double.tryParse(parts[0].trim());
    final pitch = double.tryParse(parts[1].trim());
    if (yaw == null || pitch == null) return null;
    if (!yaw.isFinite || !pitch.isFinite) return null;
    // Clamped rather than rejected: a detector reporting ±180 is describing a
    // head that is definitely not facing the screen, and turning the video off
    // sideways should not read as "no evidence".
    return (
      yaw.clamp(-180.0, 180.0).toDouble(),
      pitch.clamp(-180.0, 180.0).toDouble(),
    );
  }

  void _emit(GazeSignal signal) {
    if (_signals.isClosed) return;
    _signals.add(signal);
  }

  /// Releases the subscription, the stream, and the host hook behind [source].
  ///
  /// The source goes with it because it exists for this monitor: leaving it
  /// installed would let a page-level detector report into an attempt that has
  /// already been submitted. Safe to call more than once, and a source's own
  /// `dispose` is idempotent too, so a caller that also holds it does no harm.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(_signals.close());
    _source.dispose();
  }
}
