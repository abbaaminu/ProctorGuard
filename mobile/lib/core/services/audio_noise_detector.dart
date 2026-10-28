import 'dart:collection';
import 'dart:math' as math;

/// Turns a stream of loudness samples (dBFS) into `audio_noise` rulings.
///
/// This is the *rules* half of audio proctoring and it is deliberately pure Dart:
/// no microphone, no timers, no plugin - one [add] per sample, one `true` when the
/// student should be warned. The platform half lives in `audio_monitor.dart`, and
/// the two are joined by `AudioMonitoringNotifier`.
///
/// Three rules keep a cough from costing a strike:
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
///  2. **Sustained, not instantaneous.** The level has to add up to [sustain]
///     above the threshold; a dip only ends the episode once it has lasted longer
///     than [releaseGrace] *and* gone more than [hysteresisDb] under the
///     threshold. Bridging that dip is what makes the rule catch *talking* rather
///     than only an unbroken shout: at four samples a second, a real sentence dips
///     below the threshold between words, so a rule that reset on any one low
///     sample never reached its window at all. The hysteresis band is the second
///     half of that: a quietly spoken syllable two or three decibels under the
///     threshold is the middle of the same sentence, not a room that went quiet,
///     so it must not start the [releaseGrace] clock at all. A cough, a chair
///     creak or the student drawing breath is still far too brief to add up, and
///     a room that has genuinely gone quiet ends the episode within
///     [releaseGrace]. A crescendo shorter than [sustain] is reported through
///     [isNoisy] for the indicator, and never logged.
///  3. **Cooldown.** After a strike the detector ignores the level for [cooldown],
///     so one long outburst is one strike rather than one every sample.
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
    this.calibrationWindow = const Duration(seconds: 5),
    this.sustain = const Duration(seconds: 1),
    this.releaseGrace = const Duration(milliseconds: 400),
    this.hysteresisDb = 3,
    this.cooldown = const Duration(seconds: 10),
    this.speechMarginDb = 6,
    this.minThresholdDb = -50,
    this.maxThresholdDb = -32,
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
  final Duration calibrationWindow;

  /// How long the level must add up to above the threshold before it is a strike.
  ///
  /// One second - four or five of `AudioMonitor`'s 250 ms samples in a row - is a
  /// spoken phrase, which is the shortest thing that is *speech* rather than an
  /// accident: "hey you", "stop that", a name called across the room, a question
  /// read aloud. It was 500 ms, on the strength of an audit finding against an
  /// earlier 1.5 s window that needed most of a sentence; live testing on web and
  /// desktop showed the other end of that trade - the browsers' peak-reading
  /// meters make a keyboard, a mouse click, a chair or a single cough land over
  /// the line for several samples in a row, so a half-second window logged
  /// `audio_noise` for noise that was not a voice at all. A full second is the
  /// balance: still a *phrase* rather than a paragraph, but long enough that only
  /// something which keeps going gets counted.
  ///
  /// A cough, a chair creak, a door or a keystroke is shorter than this. At four
  /// samples a second a 300 ms one-off can contribute at most one over-threshold
  /// sample, which cannot fill a one-second window; the burst has to keep crossing
  /// the line across four sampling intervals. [releaseGrace] and [hysteresisDb]
  /// are what keep the gap *between* two words from restarting the window, so a
  /// sentence is one episode rather than none.
  ///
  /// Kept below the length of the noise it is meant to catch on purpose: the
  /// samples are a meter, not a recording, so a burst that starts just after one
  /// only contributes its remainder. A short window is what makes that offset
  /// harmless instead of hiding half a sentence.
  final Duration sustain;

  /// How much of a dip below the threshold is bridged instead of ending the
  /// episode.
  ///
  /// Must be longer than the sampling interval (`AudioMonitor` asks for a level
  /// every 250 ms): the point is that one low sample in the middle of a sentence
  /// is not evidence that the room went quiet. Anything quieter for longer than
  /// this restarts the window from scratch, which is what keeps one cough from
  /// being added to the next one.
  final Duration releaseGrace;

  /// What to do with a sentence's quiet syllables.
  ///
  /// The threshold is a line a *sustained* level has to cross, not a line every
  /// single sample has to stay above. Speech at conversation volume swings several
  /// decibels between syllables, and a sample taken mid-syllable can land just
  /// under the threshold even though the student is still talking. Counting that
  /// as a dip starts [releaseGrace] early, and a second quiet syllable a few
  /// hundred milliseconds later is then enough to throw away the part of the
  /// sentence that had already accumulated.
  ///
  /// So a sample within this many decibels *below* the threshold is treated as
  /// part of the episode rather than as a dip. It does not add to [sustain] (only a
  /// sample over the line does), and it keeps the amber indicator on. 3 dB is
  /// about the smallest change a listener hears as "half as loud", which is large
  /// enough to cover syllable-to-syllable swing and far too small to mistake a
  /// room that actually went quiet (typically 10-20 dB under the room floor) for
  /// speech.
  ///
  /// Zero restores the strict rule - every sample under the threshold starts the
  /// release clock - and is what a host that wants the old behaviour can pass.
  final double hysteresisDb;

  /// How long after a strike the level is ignored.
  ///
  /// Ten seconds, so one continued outburst is one strike. It was five, which was
  /// long enough to stop one *sample* being one strike but not long enough to stop
  /// a room that stays loud for half a minute from climbing the strike ladder on
  /// its own - and the third strike escalates (`ProctoringNotifier`). A student who
  /// genuinely talks twice, ten seconds apart, still earns two strikes.
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

    if (isCoolingDown) {
      // Dead zone: the strike for this outburst has already been logged.
      _aboveSince = null;
      _belowSince = null;
      _noisy = false;
      return false;
    }

    // Where a sample has to be to count as speech. Anything under this is a real
    // dip; the band between it and the threshold is a quiet syllable.
    final dipFloor = _thresholdDb - hysteresisDb;

    if (level < dipFloor) {
      // Genuinely quiet: more than [hysteresisDb] under the line, so this really
      // is a break in the sound rather than a soft syllable. Whether it *ends* the
      // episode is decided by the next sample that comes back over the line: a dip
      // shorter than [releaseGrace] - the gap between two words - is bridged, a
      // longer quiet stretch restarts the window from scratch. Either way the amber
      // "something is building" state is off: this sample is not the noise.
      _belowSince ??= now;
      _noisy = false;
      return false;
    }

    // Over the threshold, or close enough under it to be the same sentence. A dip
    // that was already open is bridged if it was short enough, so that talking
    // (which is not one unbroken tone) still adds up to [sustain].
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

  /// Forgets the room, the episode and the cooldown.
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
    _samples = 0;
    _thresholdDb = defaultThresholdDb;
  }
}
