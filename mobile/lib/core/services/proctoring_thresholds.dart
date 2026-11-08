/// The numbers behind one sentence: **a look-away is reported only after the
/// student has held their head turned for a while.**
///
/// They live in one file, as named constants, because the rule used to be spread
/// across the engine's constructor defaults and its frame bookkeeping, where it
/// could only be restated by reading three hundred lines of detection code - and
/// because `web_face_presence.dart` implements the same idea for the browser and
/// has to keep quoting the same numbers.
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
