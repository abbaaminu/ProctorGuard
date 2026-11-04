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
///     up or down (pitch is judged separately and a little wider, because reading
///     and typing both lower the chin);
///   * it is a **look-away** only once the head has stayed off screen for
///     [lookAwaySustain] *without a single frame back inside the tolerances* -
///     the sustain is measured on consecutive frames, so a glance and a return
///     never add up to one strike;
///   * one episode is one strike: the engine latches the signal until a frame
///     comes back inside the tolerances.
///
/// Why two seconds and 25 degrees: both numbers moved in opposite directions from
/// the first version of this rule, and the pair is the point. The tolerance was
/// widened (15 -> 25 degrees) because a 15 degree turn flags a student glancing at
/// their own keyboard or at a clock on the wall, and the audit's answer to
/// false positives cannot be "disqualify them anyway". The duration was added
/// because a *single* frame past any tolerance is a guess: at ~7 FPS one frame is
/// 150 ms, which is a blink, a notification, or the detector being wrong. Two
/// seconds is long enough that no reading position explains it and short enough
/// that a student working from a second screen, or a phone in the lap, is caught
/// while they are still doing it.
///
/// These are defaults, not laws: `MediaPipeProctoringService` takes each one as a
/// constructor argument so a device with a noisy Euler estimate can be made
/// looser, and `test/proctoring_thresholds_test.dart` pins the values and the
/// relationship between them.
library;

/// Yaw (left/right head turn) past which a frame counts as looking away, in
/// degrees. Wider than the audit's original 15 on purpose - see the library
/// comment above.
const double lookAwayYawDegrees = 25.0;

/// Pitch (up/down head tilt) past which a frame counts as looking away, in
/// degrees.
///
/// Tighter than [lookAwayYawDegrees] on the down side because a head dropped to a
/// phone in the lap or to notes on the desk is 25-40 degrees, well past this,
/// while a student reading a question on the screen barely moves.
const double lookAwayPitchDegrees = 18.0;

/// How long the head has to stay past [lookAwayYawDegrees] / [lookAwayPitchDegrees],
/// across consecutive frames, before the look-away is reported.
const Duration lookAwaySustain = Duration(seconds: 2);
