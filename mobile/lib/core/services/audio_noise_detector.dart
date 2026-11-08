import 'dart:collection';
import 'dart:math' as math;

import 'proctoring_thresholds.dart';

/// Turns a stream of loudness samples (dBFS) into `audio_noise` rulings.
///
/// This is the *rules* half of audio proctoring and it is deliberately pure Dart:
/// no microphone, no timers, no plugin - one [add] per sample, one `true` when the
/// student should be warned. The platform half lives in `audio_monitor.dart`, and
/// the two are joined by `AudioMonitoringNotifier`.
///
/// Four rules keep a cough from costing a strike:
///
///  1. **Calibration.** The first [calibrationWindow] of the session measures the
///     room, and the threshold becomes *that room's* floor plus [speechMarginDb]
///     (clamped to [minThresholdDb]..[maxThresholdDb]). A quiet exam room therefore
///     ends up far more sensitive than one with an air-conditioning hum, with no
///     per-device configuration. The margin and the clamps sit *between* the room
///     and a voice rather than at the bottom of the scale: wide enough that the
///     room's own flutter - a fan, a fridge, a keyboard, the microphone's own
///     self-noise, and the peak-reading meters a browser hands us - never clears
///     the line, and low enough that quiet speech and steady background sound (a
///     television, a second voice, traffic, a generator) still do. Nothing can be
///     logged before calibration finishes, which doubles as the start-of-session
///     grace period.
///  2. **Sustained, not instantaneous.** The level has to stay above the threshold
///     for [sustain] - **two seconds, continuously**. A single sample below the
///     threshold ends the episode and the next over-threshold sample starts the
///     window again from zero; the shipped [releaseGrace] and [hysteresisDb] are
///     both zero, so there is no bridging of the gaps between words. This is the
///     rule the product asked for ("sustained for 2 seconds; a dip resets the
///     timer"), and the price is the one it accepts: a student talking in short
///     bursts may never fill the window, and a room that is loud in spikes rather
///     than steadily is not reported. A cough, a chair creak or a keystroke is far
///     too brief to fill it either. A crescendo shorter than [sustain] is still
///     reported through [isNoisy] for the indicator, and never logged.
///  3. **One episode, one strike.** The first sample that fills the window is the
///     strike, and the detector then *latches*: nothing is reported again until a
///     sample comes back below the threshold. A room that stays loud for a minute
///     is one `audio_noise`, not one every couple of seconds. The latch is released
///     by a real dip, so a genuine second episode - talk, quiet, talk again - is a
///     second strike.
///  4. **Cooldown.** After a strike the detector ignores the level for [cooldown]
///     as well, so two episodes a second apart (a door slamming, then a voice) do
///     not stack. It is the minimum interval; the latch is what bounds an episode.
///
/// The median (not the mean) is what calibration reads, so a student who talks
/// through the first seconds of an exam cannot drag the room floor up to their
/// voice - and even if the estimate is skewed, the clamp keeps the threshold
/// usable. It is measured **once**: the floor is a fact about this microphone and
/// room, so a medians-of-the-whole-session estimate would chase every sound the
/// student made instead of describing the room; [reset] is the one way to ask for
/// a fresh measurement (it is called when the microphone comes back after an
/// interruption).
class AudioNoiseDetector {
  AudioNoiseDetector({
    this.calibrationWindow = const Duration(seconds: 3),
    this.sustain = audioNoiseSustain,
    this.releaseGrace = audioNoiseReleaseGrace,
    this.hysteresisDb = audioNoiseHysteresisDb,
    this.cooldown = const Duration(seconds: 10),
    this.speechMarginDb = audioNoiseMarginDb,
    this.minThresholdDb = audioNoiseMinThresholdDb,
    this.maxThresholdDb = audioNoiseMaxThresholdDb,
    this.defaultThresholdDb = -30,
    this.minCalibrationSamples = 5,
    this.maxCalibrationSamples = 128,
    this.silenceFloorDb = -100,
    DateTime Function()? clock,
  })  : assert(sustain > Duration.zero, 'a zero sustain would log every sample'),
        assert(
          releaseGrace >= Duration.zero,
          'a negative grace would end every episode on the first dip',
        ),
        assert(
          hysteresisDb >= 0,
          'a negative band would make every dip start the release clock',
        ),
        assert(
          minThresholdDb <= maxThresholdDb,
          'the clamp bounds are the wrong way round',
        ),
        assert(
          maxCalibrationSamples > 0,
          'a zero cap would leave calibration with no samples at all',
        ),
        assert(
          silenceFloorDb < minThresholdDb,
          'a silence floor at or above the threshold would make silence a strike',
        ),
        _now = clock ?? DateTime.now,
        _thresholdDb = defaultThresholdDb;

  /// How long the room is measured before any strike can be logged.
  ///
  /// Three seconds - twelve of `AudioMonitor`'s 250 ms samples, well over
  /// [minCalibrationSamples] - is enough for the median to describe a room. It was
  /// five, and five seconds is a long time to wait at the start of an attempt for a
  /// detector that is otherwise ready: the calibration window *is* the whole
  /// start-of-session delay, because nothing can be judged before the floor is
  /// known. A student who starts talking at 0:01 with a five-second window was not
  /// heard until 0:06; with three it is 0:04 (see [sustain] for the rest of it).
  ///
  /// The median is what makes the shorter window safe: one loud syllable inside it
  /// does not move the floor, and the floor is only ever read once.
  final Duration calibrationWindow;

  /// How long the level must stay **continuously** above the threshold before it
  /// is a strike.
  ///
  /// Two seconds ([audioNoiseSustain]), matching the look-away rule: an ambient
  /// signal gets the same "sustained, not instantaneous" standard on both senses,
  /// so neither a glance nor a cough can cost a strike on its own.
  ///
  /// It was 750 ms, chosen against `AudioMonitor`'s 250 ms sampling interval to
  /// fire one sample after four consecutive over-threshold samples, and it was
  /// bridged across the gaps between words by [releaseGrace] and [hysteresisDb].
  /// The rule is now "two seconds of continuous level": a single sample under the
  /// threshold restarts the window from zero, because that is what the product
  /// asked for and because the "reading a question aloud" case it used to protect
  /// is indistinguishable from "talking the paper through with somebody in the
  /// room". The cost is written down where a reviewer will find it: speech that
  /// dips between words may never fill the window, and an honest student in a
  /// genuinely noisy room can reach the threshold - which is why reaching it ends
  /// the *sitting* for a human to decide, never an automatic disqualification.
  ///
  /// Kept as a constructor argument, so a deployment that wants the old window
  /// back can pass one.
  final Duration sustain;

  /// How much of a dip below the threshold is bridged instead of ending the
  /// episode.
  ///
  /// **Zero by default** ([audioNoiseReleaseGrace]): a dip resets the timer.
  /// Anything quieter than the threshold, for any length of time, restarts the
  /// window - which is the strict form of "sustained for two seconds" and the
  /// reason one cough cannot be added to the next one.
  ///
  /// The knob is kept for hosts that want the tolerant rule back: with a grace
  /// longer than the sampling interval (`AudioMonitor` asks for a level every
  /// 250 ms) a single low sample in the middle of a sentence is bridged, and
  /// anything quieter for longer than the grace restarts the window.
  final Duration releaseGrace;

  /// What to do with a sentence's quiet syllables.
  ///
  /// **Zero by default** ([audioNoiseHysteresisDb]): a sample even a fraction of a
  /// decibel under the threshold is a dip, so the window only fills on a level that
  /// never leaves the line. That is the strict reading of the rule, and it is
  /// deliberate.
  ///
  /// Larger values restore the old tolerance: a sample within this many decibels
  /// *below* the threshold is treated as part of the episode rather than as a dip.
  /// It never adds to [sustain] and it keeps the amber indicator on. 3 dB is about
  /// the smallest change a listener hears as "half as loud", which is enough to
  /// cover syllable-to-syllable swing and far too small to mistake a room that
  /// actually went quiet (typically 10-20 dB under the room floor) for speech.
  final double hysteresisDb;

  /// How long after a strike the level is ignored entirely.
  ///
  /// Ten seconds, so two episodes a moment apart (a raised voice, then a door)
  /// cannot stack into two strikes. It is a *minimum interval*; the latch
  /// ([_latched]) is what bounds one episode, and it is what keeps a room that
  /// stays loud for half a minute from climbing the strike ladder on its own. A
  /// student who genuinely talks twice, ten seconds apart, with the room quiet in
  /// between, still earns two strikes.
  final Duration cooldown;

  /// How far above the measured room floor counts as human noise rather than the
  /// room itself. 6 dB is a clear, *sustained* step above the hum it is measured
  /// against, so the room's own level - and the flutter of a peak-reading browser
  /// meter, a fan, a fridge, a keyboard - does not trip it, while quiet speech and
  /// steady background sound are still caught, not just a raised voice.
  ///
  /// Raised from 4 dB after live testing: at 4 dB a normal-volume conversation and
  /// a quiet room were only a syllable apart, so ordinary room sound cleared the
  /// line on web and desktop, where `record` measures the **peak** of a short
  /// analyser window rather than a smoothed envelope (a peak meter reads several
  /// decibels hotter and spikier than the same room on a phone). The
  /// [minThresholdDb] clamp is what still keeps a microphone's own self-noise from
  /// reading as speech.
  final double speechMarginDb;

  /// Sensitivity bounds. Without the clamp a silent room would produce a threshold
  /// so low that the microphone's own noise floor reads as "talking", and a noisy
  /// room one so high that only a shout counts.
  ///
  /// [minThresholdDb] keeps the threshold above the microphone's own self-noise and
  /// above the room's own flutter; [maxThresholdDb] stops a noisy room raising the
  /// bar out of reach, so its steady background is itself the finding.
  ///
  /// The lower bound is the one that matters on web and desktop. A silent room
  /// there calibrates to the metering sentinel (`record` reports -160 dBFS for
  /// "nothing to report"), which clamps the threshold to the bottom of the band -
  /// and a bottom of -55 dBFS made a mouse click, a chair or the fan in a quiet
  /// classroom a violation. -50 dBFS is still below a normal speaking level for the
  /// same room, so speech is caught, but the room's own noise no longer is.
  final double minThresholdDb;
  final double maxThresholdDb;

  /// Used until calibration has enough samples (and if it never gets any).
  final double defaultThresholdDb;

  /// The quietest level a reading is allowed to claim.
  ///
  /// `record` reports -160 dBFS when it has nothing to report - silence, a capture
  /// session that has not started, a browser whose analyser buffer is exactly zero
  /// - and that number is a *sentinel*, not a measurement of the room. Left alone
  /// it becomes the room's floor through the calibration median, which pins the
  /// threshold to [minThresholdDb] and makes every tiny sound clear the line: the
  /// false-positive `audio_noise` strikes seen in live testing. Clamping it to
  /// -100 dBFS keeps the sentinel far below any threshold (so it still ends an
  /// episode and still reads as silence) without letting it *be* the room.
  final double silenceFloorDb;

  /// How many samples calibration needs before it will trust its median.
  final int minCalibrationSamples;

  /// The most readings the calibration median is built from.
  ///
  /// The window is five seconds and [AudioMonitor] samples every 250 ms, so the
  /// shipped defaults only ever collect about sixteen - but a source with a
  /// different rate (a test, a host feeding frames) must not be able to turn a
  /// once-per-session calculation into an unbounded buffer. Once the cap is
  /// reached the oldest reading is dropped, so the median describes the *recent*
  /// room, which is the one the student is sitting in.
  ///
  /// A cap below [minCalibrationSamples] is honoured, but the minimum is clamped
  /// down to it: calibration then takes the whole [calibrationWindow] and every
  /// reading it can keep, instead of waiting forever for samples it is deleting.
  final int maxCalibrationSamples;

  final DateTime Function() _now;

  final ListQueue<double> _calibrationSamples = ListQueue<double>();
  DateTime? _firstSampleAt;
  DateTime? _aboveSince;

  /// When the level first dropped back under the threshold during an open
  /// episode, so the dip can be measured against [releaseGrace].
  DateTime? _belowSince;
  DateTime? _lastStrikeAt;
  double? _roomFloorDb;
  double? _peakDb;
  double _thresholdDb;
  bool _noisy = false;

  /// True from the sample that fills [sustain] until a sample comes back under the
  /// threshold: one episode is one strike, however long the room stays loud.
  ///
  /// This is the rule the release asked for ("one episode = one strike, latch until
  /// the level drops back below"). It is a separate flag rather than a consequence
  /// of [cooldown], because a cooldown bounds how *often* a strike can land while
  /// this bounds how many a single episode can produce.
  bool _latched = false;

  int _samples = 0;

  /// True once the room floor has been measured: before that the detector is
  /// listening, not judging (and the indicator says "calibrating").
  bool get isCalibrated => _roomFloorDb != null;

  /// The measured room floor, or null while calibrating.
  double? get roomFloorDb => _roomFloorDb;

  /// The level a sample has to beat to count as suspicious, right now.
  double get thresholdDb => _thresholdDb;

  /// Loudest sample seen since the last [reset].
  double? get peakDb => _peakDb;

  /// How many samples have been fed in.
  int get samples => _samples;

  /// How many readings the calibration median currently holds.
  ///
  /// Non-zero only while the room is being measured, capped at
  /// [maxCalibrationSamples], and zero again once calibration is done (the
  /// readings have no further use). Exposed for the diagnostics the audio
  /// indicator and the tests read, the same way [peakDb] and [samples] are.
  int get calibrationSampleCount => _calibrationSamples.length;

  /// True when the last sample was above the threshold but the [sustain] window
  /// has not filled yet - the difference between "the indicator glows amber" and
  /// "the student is warned".
  bool get isNoisy => _noisy;

  /// Whether the detector would ignore a sample right now ([cooldown] after the
  /// last strike). Exposed so the indicator can explain the dead zone instead of
  /// looking broken.
  bool get isCoolingDown {
    final lastStrike = _lastStrikeAt;
    if (lastStrike == null) return false;
    return _now().difference(lastStrike) < cooldown;
  }

  /// Feeds one loudness sample (dBFS, negative; 0 is full scale).
  ///
  /// Returns true when *this* sample is the one that fills the [sustain] window
  /// and should therefore be logged as a violation. Callers log once per `true`,
  /// which is what keeps one episode to one strike.
  bool add(double decibels, {DateTime? at}) {
    final now = at ?? _now();
    // A misbehaving source (NaN, ±inf) must not corrupt the calibration median.
    if (decibels.isNaN || decibels.isInfinite) return false;

    // A reading is a measurement of the room; the sentinel is not. Clamping it is
    // what stops a browser that reports "nothing to report" from calibrating the
    // room at -160 dBFS - see [silenceFloorDb].
    final level = math.max(decibels, silenceFloorDb);

    _samples++;
    _firstSampleAt ??= now;
    _peakDb = _peakDb == null ? level : math.max(_peakDb!, level);

    if (!isCalibrated) {
      _collectCalibration(level, now);
      return false;
    }

    // Where a sample has to be to count as speech. Anything under this is a real
    // dip; the band between it and the threshold is a quiet syllable (an empty band
    // with the shipped [hysteresisDb] of zero).
    final dipFloor = _thresholdDb - hysteresisDb;

    // A genuine dip - under the threshold with the shipped settings - ends the
    // episode for good: it releases the one-strike latch and, once it has lasted
    // longer than [releaseGrace], restarts the window. The amber "something is
    // building" state goes off with it, because this sample is not the noise.
    if (level < dipFloor) {
      _latched = false;
      _belowSince ??= now;
      _noisy = false;
      return false;
    }

    if (isCoolingDown) {
      // Dead zone: the strike for this episode has already been logged, and two
      // episodes a moment apart must not stack into two strikes.
      _aboveSince = null;
      _belowSince = null;
      _noisy = false;
      return false;
    }

    // One episode, one strike. Nothing reports again until a sample comes back under
    // the threshold (above), so a room that stays loud for a minute is one
    // `audio_noise` rather than one every [cooldown].
    if (_latched) return false;

    // Over the threshold, or close enough under it to be the same utterance. A dip
    // that was already open is bridged if it was short enough (never, with the
    // shipped zero grace), so that a level that only wobbles still fills [sustain].
    final belowSince = _belowSince;
    if (belowSince != null) {
      if (now.difference(belowSince) >= releaseGrace) _aboveSince = null;
      _belowSince = null;
    }

    if (level < _thresholdDb) {
      // Inside the hysteresis band: no new above-threshold sample to count, but
      // the episode is still open (and the indicator stays amber), so the window
      // keeps running from where it started.
      return false;
    }

    _aboveSince ??= now;
    _noisy = true;

    if (now.difference(_aboveSince!) < sustain) return false;

    _aboveSince = null;
    _noisy = false;
    _lastStrikeAt = now;
    // Latched: one episode, one strike (rule 3 in the class docs).
    _latched = true;
    return true;
  }

  void _collectCalibration(double decibels, DateTime now) {
    _calibrationSamples.addLast(decibels);
    // Bounded, so a source that samples far faster than `AudioMonitor` cannot grow
    // the median's working set for the whole session. Old readings are the ones a
    // room can have changed away from, so they go first.
    while (_calibrationSamples.length > maxCalibrationSamples) {
      _calibrationSamples.removeFirst();
    }

    final started = _firstSampleAt;
    final elapsed = started == null ? Duration.zero : now.difference(started);
    if (elapsed < calibrationWindow) return;
    // The source may be slower than expected; waiting for a few real samples beats
    // calibrating off one or two readings. The requirement is clamped to the cap:
    // a host that tunes the cap below [minCalibrationSamples] has said it keeps
    // fewer readings than the default minimum, and calibration has to still
    // *finish* rather than wait for samples it is deleting.
    final required = math.min(minCalibrationSamples, maxCalibrationSamples);
    if (_calibrationSamples.length < required) return;

    _roomFloorDb = _median(_calibrationSamples);
    _thresholdDb = (_roomFloorDb! + speechMarginDb)
        .clamp(minThresholdDb, maxThresholdDb)
        .toDouble();
    // Measurement is over for this microphone: nothing reads the readings again
    // (the floor is a fact now), and keeping them would be the one part of this
    // detector that grows with session length.
    _calibrationSamples.clear();
  }

  /// Median of a copy, so calibration cannot see a partially sorted queue.
  static double _median(Iterable<double> values) {
    final sorted = List<double>.of(values)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[middle];
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }

  /// Forgets the room, the episode, the latch and the cooldown.
  ///
  /// Called when the microphone comes back after an interruption: the student may
  /// have moved rooms, plugged in a headset or changed device, so the old floor is
  /// no longer a fact about this microphone.
  void reset() {
    _calibrationSamples.clear();
    _firstSampleAt = null;
    _aboveSince = null;
    _belowSince = null;
    _lastStrikeAt = null;
    _roomFloorDb = null;
    _peakDb = null;
    _noisy = false;
    _latched = false;
    _samples = 0;
    _thresholdDb = defaultThresholdDb;
  }
}
