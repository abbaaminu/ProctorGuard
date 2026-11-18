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
///   * a frame is *off screen* when the head is turned past [lookAwayYawDegrees]
///     left or right, or tilted past [lookAwayPitchDegrees] up or down - one
///     angle, the same on both axes and in both directions, compared as an
///     absolute value. The browser is the one exception, and only downwards: it
///     allows a chin [lookAwayWebDownwardPitchDegrees] down before a frame counts;
///   * it is a **look-away** when the head has stayed off screen for
///     [lookAwaySustain] *without a single frame back inside the tolerances*;
///   * **unless the turn is near-sideways** - past [lookAwayImmediateYawDegrees]
///     of yaw - where [lookAwayImmediateFrames] consecutive frames are enough.
///     A head that far round is not a reading position, so a student working
///     from a second screen hears about it in a fraction of a second instead of
///     two; the confirmation is what keeps one bad Euler estimate (which can
///     read 60 degrees) from being that strike;
///   * beside that, a **window**: [lookAwayBurstCount] glances of at least
///     [lookAwayMinEpisode] each, or [lookAwayBurstCumulative] of off-screen time
///     in total, inside [lookAwayBurstWindow] are also one look-away - the shape
///     the sustained rule cannot see (a student reading a printed sheet, the
///     screen, the sheet again never holds one unbroken turn);
///   * one episode is one strike: the engine latches the signal until a frame
///     comes back inside the tolerances, and a strike empties the window it came
///     from;
///   * and nothing is judged at all until [cameraStartupGrace] has passed since the
///     sitting's first frame, on either platform - a student is still arranging the
///     camera when the paper opens.
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
/// The browser's downward allowance is not a return to that pair. That one had two
/// different numbers on *both* axes and applied to the phone as well, so one head
/// was judged two ways on one device; this one moves a single direction on a single
/// platform, and the direction it moves is the one a desk explains: a browser
/// student reads a keyboard and a paper that lie below the screen, often on a
/// camera that sits below the screen too. A chin *raised* past 15 degrees is a
/// screen above the monitor, which is the second monitor this rule exists to catch,
/// and it stays at [lookAwayPitchDegrees]. The phone keeps 15 in both directions,
/// so a downward tilt of 18 degrees is a strike there after two seconds and is not
/// one in a browser: that difference is real, it is the price of the browser's
/// slack, and it is stated here rather than left to be discovered in an appeal.
/// The parity that decides an appeal - one platform, one rule, the same head judged
/// the same way every time - is untouched.
///
/// The near-sideways start is the one place where speed beats the hold, and it is
/// bounded twice: past 30 degrees the head is visibly off the screen rather than
/// glancing at a keyboard, and it still has to be seen on two frames, so a single
/// estimate that reads 60 degrees because the detector slipped is not a strike on
/// its own. It is a *yaw* rule: "sideways" is what yaw measures, and the sign of a
/// browser's pitch is the one thing this file cannot state for both detectors.
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
/// degrees - absolute, in both directions, on the phone; on the web the *upward*
/// half only, where [lookAwayWebDownwardPitchDegrees] is the other.
///
/// Equal to [lookAwayYawDegrees] on purpose. The false positives a tight pitch
/// could otherwise cause - reading a question, glancing at the keyboard - are what
/// [lookAwaySustain] is for, and a chin *raised* past this is a screen above the
/// monitor rather than a reading position, which is why the web keeps it there.
/// Which direction ML Kit calls "chin down" is not something this file can state,
/// so the phone goes on comparing the absolute value; the browser knows its own
/// sign, and `web_face_presence.dart` says where it comes from.
const double lookAwayPitchDegrees = 15.0;

/// The browser's tolerance for a *downward* tilt, in degrees: five more than
/// [lookAwayPitchDegrees], and only on that side.
///
/// A browser student reads a keyboard and a paper that lie below the screen, and
/// the camera is often below the screen as well - so a chin a little down is what
/// reading and typing look like - while the same five degrees up is a screen
/// mounted above the monitor, which is the thing the rule exists to catch. 20
/// clears an ordinary glance at the keyboard without clearing a head that has
/// stopped reading: past it the head is angled at the desk rather than at the
/// paper.
///
/// Two things about it are deliberate. It is **web only** - `WebFacePresenceMonitor`
/// reads it and the engine never does - because ML Kit's pitch sign has never been
/// verified, so a signed rule on the phone would be a guess. And it rests on the
/// sign the browser detector reports, which `web/proctor_face_detector.js` states
/// and both of its measurement routes now share: **positive is a chin down**. What
/// a real face produces on a real camera is still unverified (the root README keeps
/// that risk open), which is why the guess, such as it is, points at the direction
/// that *helps* a student: if the sign is the other way round, an 18 degree glance
/// is judged exactly as it is today, at 15.
const double lookAwayWebDownwardPitchDegrees = 20.0;

/// How long the head has to stay past [lookAwayYawDegrees] / [lookAwayPitchDegrees],
/// across consecutive frames, before the look-away is reported.
const Duration lookAwaySustain = Duration(seconds: 2);

/// Yaw past which a turn is *near-sideways*, and so is confirmed by
/// [lookAwayImmediateFrames] consecutive frames instead of by [lookAwaySustain].
///
/// 30 degrees - twice [lookAwayYawDegrees] - is where the head is no longer
/// pointing at the screen at all: a second screen beside the laptop, a phone in the
/// lap, or a person being talked to. Waiting two seconds for that turn is what made
/// the detector feel unresponsive, so this is the shortest honest answer: a student
/// who has actually turned away hears about it in about 0.3 s on the phone (two
/// frames at ~7 FPS) and in about 0.7 s in a browser (two 350 ms ticks).
///
/// It cannot be a *single* frame: one bad Euler estimate can read 60 degrees, and a
/// strike on a detector artefact is worse than one 150 ms later on a real turn. It
/// is *yaw only* - pitch is judged by the sustained rule at every angle - because a
/// deep nod is a student reading the paper or the keyboard, which is the case for a
/// wider tolerance and a full hold (see [lookAwayWebDownwardPitchDegrees]), not for
/// reporting faster.
const double lookAwayImmediateYawDegrees = 30.0;

/// How many consecutive near-sideways detections confirm a turn past
/// [lookAwayImmediateYawDegrees] - two, on both platforms.
///
/// A *count*, not a duration, so it means the same thing to an engine that judges
/// frames (~150 ms apart) and to a browser whose detector ticks every 350 ms; and
/// two, because the rule is "seen twice", not "seen once".
const int lookAwayImmediateFrames = 2;

// ---------------------------------------------------------------------
// The look-away rule, second half - the same question asked in a *window*:
// **a glance that never lasts two seconds is still looking away, when it keeps
// coming back.**
// ---------------------------------------------------------------------
// [lookAwaySustain] needs one unbroken two seconds, so a student who reads a
// printed page, looks up at the screen, and goes back to the page is never
// reported: every return inside the tolerances restarts the window. These four
// numbers are the second way of asking the same question, and they are additive:
// they sit *beside* the two-second rule, which is neither relaxed nor replaced by
// them.
//
// Read the honesty note with them. Measured against a person, a glance at notes
// is not misbehaviour, and this half of the rule is the one that makes natural
// behaviour add up: a third glance inside a minute is a counted strike, and three
// counted strikes stop the attempt for a supervisor. That is deliberate - a
// sitting where the candidate is off screen every few seconds is not a sitting
// where they are working on the paper - but the cost is real, and how often a
// real student glances has not been measured here. See
// `look_away_burst_window.dart` for how the numbers combine.

/// How long a run of off-screen frames has to last before it counts as one
/// glance rather than as detector jitter.
///
/// 500 ms is longer than a blink re-sampled across two frames of a ~7 FPS
/// detector, longer than the wrong Euler estimate a single frame can produce, and
/// shorter than the pause of someone who has actually turned to read something.
/// A shorter run is still *measured* (it counts towards
/// [lookAwayBurstCumulative]), it just cannot be one of the counted glances on its
/// own.
const Duration lookAwayMinEpisode = Duration(milliseconds: 500);

/// The window repeated glances are counted in.
///
/// 60 s, because the rule is about *repeated* glances, not about a whole sitting:
/// a student who looks away once a minute is not working from a second screen, and
/// a glance that has fallen out of the window is no longer evidence for the glance
/// just made. It slides with the clock rather than with frames, so a camera that
/// stops delivering cannot keep old evidence alive.
const Duration lookAwayBurstWindow = Duration(seconds: 60);

/// How many glances inside [lookAwayBurstWindow] are one `looking_away`.
///
/// Three, which is what "repeated" means in practice and is deliberately above the
/// two that a single look at a clock and a look back at the paper can produce.
const int lookAwayBurstCount = 3;

/// How much off-screen time inside [lookAwayBurstWindow] is one `looking_away`,
/// however it was divided up.
///
/// This is the half that catches the shape the count cannot see: glances each too
/// brief to be one of the three, repeated until they are a twentieth of the minute
/// spent with the head off the screen. Five seconds is short enough that no
/// ordinary reading position explains it, long enough that no blink or single bad
/// frame does, and it is reachable without ever producing one counted glance -
/// which is why it exists beside the count rather than instead of it.
const Duration lookAwayBurstCumulative = Duration(seconds: 5);

/// How long after the first frame of a sitting nothing is judged, on either
/// platform.
///
/// A student joining an attempt is still sitting down: moving the camera into
/// place, finding the light, putting a bag on the floor. The engine used to start
/// judging on its very first frame while `web_face_presence.dart` ignored its first
/// five seconds, so the browser was the forgiving one and a phone could log a
/// `looking_away` or a `no_face` while its owner was still adjusting the lens. One
/// of the two start-up behaviours had to go, and the finding is the missing one:
/// Android had no grace at all.
///
/// Five seconds, counted from the **first frame the engine judges** rather than
/// from construction or from the page opening, because that is the moment a camera
/// starts telling anyone anything - a feed that takes three seconds to open must
/// not spend the grace window while it is still black. It is not re-armed by
/// `MediaPipeProctoringService.resetSustained` (a feed that drops out and comes back
/// mid-sitting is examined on the frames it produces next), because a window that
/// could be re-opened on demand would be a way to be unwatched for five seconds at
/// a time. Nothing at all is reported inside it, `multiple_faces` included: the
/// person helping position the camera is not evidence about the student, and
/// whatever the window concealed is still there when it ends.
///
/// The browser *guard* window (`WebExamGuard.startupGrace`) happens to be the same
/// five seconds for a different question - a page still loading its listeners - and
/// is deliberately not this constant.
const Duration cameraStartupGrace = Duration(seconds: 5);

// ---------------------------------------------------------------------
// Absence, where the count is the lever: **an empty frame is only evidence
// once it has been seen three times in a row.**
// ---------------------------------------------------------------------
// The look-away rule forgives a flicker with *time*, because a head that moves
// and comes back is a glance. Absence has no such shape - there is nothing to
// watch move back - so it is forgiven with a count instead: a blink, an encoder
// that drops one frame, a detector whose box slipped for a tick.

/// How many consecutive detections without a face are one `no_face`.
///
/// Three, on both platforms, and both halves of what "consecutive" can mean:
/// the on-device engine counts its own ~150 ms frames, and the browser counts the
/// host detector's `no_face` ticks - which is why this number is quoted by
/// `MediaPipeProctoringService.missingFaceFrameThreshold` *and* by
/// `WebFacePresenceMonitor.missingFrameTolerance` rather than written twice. A
/// student who is genuinely not in front of the lens produces an unbroken run;
/// one who blinked, or whose detector lost the box for a single sample, does not.
///
/// It is a floor *beside* a duration, not a replacement for one. The browser also
/// measures `noFaceSustain`, and both have to be satisfied: a detector that bursts
/// three verdicts inside one instant has not yet been empty long enough, and one
/// that reports once every two seconds still has to report three times.
const int missingFaceFrameThreshold = 3;

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

// ---------------------------------------------------------------------
// The audio rule, second half - the same question asked in a *window*:
// **brief sound that never lasts two seconds is still sound, when it keeps
// coming back.**
// ---------------------------------------------------------------------
// [audioNoiseSustain] needs one unbroken two seconds, so a student reading the
// paper out in phrases - a sentence, a pause, a sentence - is never heard: every
// pause resets the window. These four numbers are the second way of asking the
// same question, and they are additive: they sit *beside* the two-second rule,
// which is neither relaxed nor replaced by them.

/// How long a run of above-threshold sound has to last before it counts as one
/// burst rather than as the room.
///
/// 300 ms is longer than every sound the two-second rule exists to forgive - a
/// cough, a chair, a keystroke, a door - and shorter than a spoken phrase, so the
/// burst count only moves for sound a listener would call talking. A run shorter
/// than this is still measured (it counts towards [audioNoiseBurstTotal]), it just
/// is not counted as a burst on its own.
const Duration audioNoiseMinBurst = Duration(milliseconds: 300);

/// The window repeated bursts are counted in.
///
/// 60 s, because the rule is about *repeated* noise, not about a whole sitting: a
/// student who says one word a minute for three minutes is not holding a
/// conversation, and a burst that has fallen out of the window is no longer
/// evidence for the burst just heard. It slides with the clock rather than with
/// samples, so a microphone that stops delivering frames cannot keep old evidence
/// alive.
const Duration audioNoiseBurstWindow = Duration(seconds: 60);

/// How many bursts inside [audioNoiseBurstWindow] are one `audio_noise`.
///
/// Three, which is what "repeated" means in practice and is deliberately above the
/// two a single word and its echo can produce.
const int audioNoiseBurstCount = 3;

/// How much above-threshold time inside [audioNoiseBurstWindow] is one
/// `audio_noise`, however it was divided up.
///
/// This is the half of the rule that catches the shape the burst count cannot see:
/// syllables or fragments each too short to be a burst on their own. Four seconds
/// inside a sixty-second window is a fifteenth of the minute spent over the line -
/// short enough that no reading position or passing lorry explains it, long enough
/// that it cannot be a single cough - and it is exactly what the two-second rule is
/// blind to. It is also why the count alone is not the rule: someone talking
/// steadily in fragments never produces three 300 ms bursts, and someone who
/// coughs three times a minute never reaches four seconds.
const Duration audioNoiseBurstTotal = Duration(seconds: 4);
