/// The numbers behind one sentence: **a look-away is reported only after the
/// student has held their head turned for a while** - and the same idea for the
/// microphone: **a noisy room is reported only after the level has stayed above the
/// room's own threshold for two seconds.**
///
/// They live in one file, as named constants, because the rule used to be spread
/// across the engine's constructor defaults and its frame bookkeeping, where it
/// could only be restated by reading three hundred lines of detection code - and
/// because `web_face_presence.dart` implements the same idea for the browser and
/// has to keep quoting the same numbers. The audio half is quoted by
/// `audio_noise_detector.dart` the same way (its defaults *are* these constants).
///
/// The rule, in full:
///
///   * a frame is *off screen* when the head is turned past
///     [lookAwayYawDegrees] left or right, or tilted past [lookAwayPitchDegrees]
///     up or down - one angle, the same on both axes and in both directions,
///     compared as an absolute value;
///   * it is a **look-away** only once the head has stayed off screen for
///     [lookAwaySustain] *without a single frame back inside the tolerances* -
///     the sustain is measured on consecutive frames, so a glance and a return
///     never add up to one strike;
///   * one episode is one strike: the engine latches the signal until a frame
///     comes back inside the tolerances.
///
/// Why 15 degrees, and why two seconds: the angle is where the head has visibly
/// stopped facing the screen, and the duration is the answer to the false
/// positives that angle lets in. A single frame past any tolerance is a guess -
/// at ~7 FPS one frame is 150 ms, which is a blink, a notification or the
/// detector being wrong - and a turn-and-return is a glance at a keyboard or a
/// clock. Two seconds is long enough that no reading position explains it and
/// short enough that a student working from a second screen, or a phone in the
/// lap, is caught while they are still doing it. An earlier version of this rule
/// tried to buy the same quiet with a wider tolerance instead (25 yaw, 18 pitch);
/// that made the rule asymmetric - a tilt down was a strike where the same tilt
/// up was not - and still flagged a student who simply sat turned for a moment.
/// The duration is the honest lever, so the angle can be strict.
///
/// These are defaults, not laws: `MediaPipeProctoringService` takes each one as a
/// constructor argument so a device with a noisy Euler estimate can be made
/// looser, and `test/proctoring_thresholds_test.dart` pins the values and the
/// relationship between them.
library;

/// Yaw (left/right head turn) past which a frame counts as looking away, in
/// degrees.
///
/// The same angle as [lookAwayPitchDegrees], and applied to `abs(yaw)`: a turn to
/// either side is one rule. 15 degrees is roughly where the head has visibly
/// stopped facing the screen - below it, an ordinary nod or a glance at the
/// keyboard is a strike; above 25, a student is nearly half-turned before
/// anything is reported.
const double lookAwayYawDegrees = 15.0;

/// Pitch (up/down head tilt) past which a frame counts as looking away, in
/// degrees.
///
/// Equal to [lookAwayYawDegrees] on purpose, and also absolute: which direction a
/// detector calls "chin down" differs between ML Kit and the web's
/// FaceLandmarker, so a tolerance that differed by direction would judge the same
/// head differently on a phone and in a browser. The false positives a tight
/// pitch could otherwise cause - reading a question, glancing at the keyboard -
/// are what [lookAwaySustain] is for.
const double lookAwayPitchDegrees = 15.0;

/// How long the head has to stay past [lookAwayYawDegrees] / [lookAwayPitchDegrees],
/// across consecutive frames, before the look-away is reported.
const Duration lookAwaySustain = Duration(seconds: 2);

// ---------------------------------------------------------------------
// The audio rule - the same shape, one sentence:
// **a noisy room is reported only after the level has stayed above the room's
// own measured threshold for two seconds without dropping below it.**
// ---------------------------------------------------------------------
// They live here, next to the look-away numbers, for the same reason: the rule is
// quoted by `AudioNoiseDetector` (its constructor defaults, so the numbers cannot
// drift from the file a reviewer reads), by `audio_monitoring_provider.dart` (the
// log line that says what was judged), by two READMEs and by the tests. The
// threshold itself is *not* a constant - it is measured per room - but the margin
// and the clamp that turn a measurement into a line are, and they are named here
// rather than buried in a constructor call.

/// How long the microphone level must stay above the threshold, without a single
/// sample below it, before the episode is reported as one `audio_noise` strike.
///
/// Two seconds, matching [lookAwaySustain]: the same "sustained, not
/// instantaneous" standard for the two ambient signals, so neither a cough nor a
/// glance can cost a strike on its own. A sample below the threshold ends the
/// episode and the next one has to fill the whole window again - there is no
/// bridging (see [audioNoiseReleaseGrace]).
const Duration audioNoiseSustain = Duration(seconds: 2);

/// How much of a dip below the threshold is bridged instead of ending the episode.
///
/// **Zero**: the rule is "a dip below resets the timer", so the level has to stay
/// above the threshold for [audioNoiseSustain] *continuously*. This costs the
/// between-words tolerance the detector used to have (400 ms), and the trade is
/// deliberate - an honest student in a noisy room can now end an attempt and a
/// human reviews it, which is the accepted cost of catching a student who talks
/// through the paper. `AudioNoiseDetector` still takes `releaseGrace` as an
/// argument, so a deployment that wants the old behaviour can pass it.
const Duration audioNoiseReleaseGrace = Duration.zero;

/// What to do with a sentence's quiet syllables: nothing, since
/// [audioNoiseReleaseGrace] is zero.
///
/// A sample even a decibel under the threshold is a dip that restarts the window.
/// The band the detector used to have (3 dB) is kept as a constructor argument for
/// hosts that want it back; the shipped rule needs none.
const double audioNoiseHysteresisDb = 0.0;

/// How far above the room's own measured floor counts as human noise rather than
/// the room itself.
///
/// 6 dB is a clear, *sustained* step above the hum it is measured against - the
/// median of the room means a fan, a fridge, the microphone's own self-noise and
/// the peak-reading meters a browser hands us stay under the line, while quiet
/// speech and steady background sound (a television, a second voice, traffic)
/// still clear it. This is the number that decides **how loud "noisy" is**, and
/// the 2-second window is what decides *how long* it has to stay there; they are
/// deliberately separate.
const double audioNoiseMarginDb = 6.0;

/// The band the threshold is clamped into, in dBFS.
///
/// [audioNoiseMinThresholdDb] keeps the line above the microphone's own self-noise
/// and above a silent room's flutter (a browser reports "nothing to report" as
/// -160 dBFS, which is a sentinel, not a measurement); [audioNoiseMaxThresholdDb]
/// stops a room that is already loud from raising the bar out of reach - pinned
/// *below* its own floor, that steady background is itself the finding.
const double audioNoiseMinThresholdDb = -50.0;
const double audioNoiseMaxThresholdDb = -32.0;
