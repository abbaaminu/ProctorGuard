import 'dart:async';

import 'mediapipe_proctoring_service.dart' show GazeSignal;
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
///  * `no_face` and `looking_away` have to hold for [sustain] before they are
///    reported, and each episode reports once - so one look away is one strike,
///    not one per detection, while a blink or a single dropped frame is nothing;
///  * a `centered` message ends the episode and re-arms it, so a *later* look
///    away is reported again;
///  * `multiple_faces` is not sustained (two people need no measuring): it is
///    latched until the student has been alone for [multipleFacesCooldown];
///  * a measured `pose:` turned past [immediateAwayYawDegrees] is reported on the
///    detection itself: that far round, the student is not reading the screen,
///    and waiting out the sustain would only delay a warning they are earning;
///  * nothing is reported during [startupGrace].
///
/// The difference is the unit of "held". The engine counts frames, because it sees
/// several a second and a frame is a millisecond of truth; a page's detector may run
/// at 2 fps or burst ten results from one buffered frame, so the web measures elapsed
/// [sustain] instead - 300 ms, which is about one engine frame plus the poll it was
/// caught in. Same effect - a head that has genuinely turned is reported almost
/// immediately - without assuming a frame rate nothing guarantees, and with the same
/// single exception both sides make for a head that is already unmistakably turned.
class WebFacePresenceMonitor {
  WebFacePresenceMonitor({
    required WebFaceSignalSource source,
    this.sustain = const Duration(milliseconds: 300),
    this.startupGrace = const Duration(seconds: 5),
    this.multipleFacesCooldown = const Duration(seconds: 30),
    this.offCenterYawDegrees = 15.0,
    this.offCenterPitchDegrees = 18.0,
    this.immediateAwayYawDegrees = 30.0,
    DateTime Function()? clock,
  })  : assert(
          sustain > Duration.zero,
          'a zero sustain would flag the first detection of every glance',
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
          immediateAwayYawDegrees >= offCenterYawDegrees,
          'an "unambiguous" turn inside the ordinary tolerance would flag '
          'every glance',
        ),
        _source = source,
        _now = clock ?? DateTime.now {
    _subscription = source.messages.listen(handleMessage);
  }

  /// How long a condition has to hold before it is reported.
  ///
  /// 300 ms: the same order as the on-device engine, where a single frame (~150 ms
  /// at its default interval) past the tolerance is already a strike. The web
  /// measures time rather than counting detections because a page's detector runs at
  /// whatever rate it runs at; 300 ms is two detections at a 150 ms cadence and one
  /// at a 300 ms cadence, so a slow detector is not a quieter one. The audit found
  /// the earlier 1.2 s window let a browser student look away, read something off a
  /// second screen and come back before anything was reported.
  ///
  /// Still not zero: a page's detector can report a single bad pose while a head is
  /// genuinely moving (a turn *to* the screen, a nod), and 300 ms is below the time
  /// it takes to read anything useful elsewhere.
  final Duration sustain;

  /// How long after [start] detections are ignored.
  ///
  /// A student joining an attempt is still adjusting the camera, and the page's
  /// detector may still be reporting frames from before the exam opened.
  final Duration startupGrace;

  /// How long the student must be alone before another person in frame counts as
  /// a new episode. The same 30 s the engine uses.
  final Duration multipleFacesCooldown;

  /// Head-pose tolerances, used only for `pose:` messages (a detector that sends
  /// a verdict has already applied its own). The engine's defaults: ~15 deg yaw and
  /// ~18 deg pitch, tight enough that a face pointed off the screen is one strike.
  final double offCenterYawDegrees;
  final double offCenterPitchDegrees;

  /// Yaw past which a single `pose:` detection is already unambiguous evidence,
  /// instead of [sustain] of it - the engine's
  /// `MediaPipeProctoringService.immediateAwayThresholdDegrees`, for a monitor
  /// that judges messages rather than frames.
  ///
  /// A near-sideways verdict is the one thing a sustain cannot improve on: there
  /// is no reading of the screen at that angle, so the second message only makes
  /// the student wait for a warning they have already earned. Anything between
  /// [offCenterYawDegrees] and this line keeps the full sustain.
  ///
  /// Verdicts (`looking_away`) are deliberately not included: a page that sends
  /// its own verdict may be running a looser threshold than this app's, and its
  /// word alone is worth the sustain. Pitch is excluded for the engine's reason:
  /// looking down at notes and a keyboard is normal exam behaviour.
  ///
  /// Must be at least [offCenterYawDegrees] (asserted): this may only shorten the
  /// wait for a clearly turned head, never flag a glance.
  final double immediateAwayYawDegrees;

  final WebFaceSignalSource _source;
  final DateTime Function() _now;
  final StreamController<GazeSignal> _signals =
      StreamController<GazeSignal>.broadcast();

  StreamSubscription<String>? _subscription;

  DateTime? _startedAt;
  DateTime? _awaySince;
  DateTime? _missingSince;
  DateTime? _secondPersonAt;
  bool _awayFlagged = false;
  bool _missingFlagged = false;
  bool _multipleFacesFlagged = false;
  bool _disposed = false;

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

    if (pose.$1.abs() > immediateAwayYawDegrees) {
      // Past a near-sideways turn nothing is being read off the screen, so this
      // detection is the episode: no sustain to sit through, exactly as the
      // engine treats the same angle.
      _onAway(now, immediate: true);
    } else if (pose.$1.abs() > offCenterYawDegrees ||
        pose.$2.abs() > offCenterPitchDegrees) {
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

    _missingSince ??= now;
    if (_missingFlagged) return;
    if (now.difference(_missingSince!) < sustain) return;
    _missingFlagged = true;
    _emit(GazeSignal.noFace);
  }

  void _onAway(DateTime now, {bool immediate = false}) {
    // A visible head means the absence episode is over, so a later one is
    // reported again - and a second person in frame may have left.
    _missingSince = null;
    _missingFlagged = false;
    _endMultiFaceEpisode(now);

    _awaySince ??= now;
    if (_awayFlagged) return;
    // `immediate` is the near-sideways turn: unambiguous on the first detection,
    // so the sustain window is skipped rather than filled.
    if (!immediate && now.difference(_awaySince!) < sustain) return;
    _awayFlagged = true;
    _emit(GazeSignal.lookingAway);
  }

  void _onCentered(DateTime now) {
    _awaySince = null;
    _missingSince = null;
    _awayFlagged = false;
    _missingFlagged = false;
    _endMultiFaceEpisode(now);
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
