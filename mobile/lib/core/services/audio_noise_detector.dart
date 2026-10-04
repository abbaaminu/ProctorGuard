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
///     ends up much more sensitive than a hall with an air-conditioning hum, with
///     no per-device configuration. Nothing can be logged before calibration
///     finishes, which doubles as the start-of-session grace period.
///  2. **Sustained, not instantaneous.** The level has to add up to [sustain]
///     above the threshold; a dip below it only ends the episode once it has
///     lasted longer than [releaseGrace]. Bridging that single-sample dip is what
///     makes the rule catch *talking* rather than only an unbroken shout: at four
///     samples a second, a real sentence dips below the threshold between words,
///     so a rule that reset on any one low sample never reached its window at all.
///     A cough, a chair creak or the student drawing breath is still far too
///     brief to add up, and a room that has genuinely gone quiet ends the episode
///     within [releaseGrace]. A crescendo shorter than [sustain] is reported
///     through [isNoisy] for the indicator, and never logged.
///  3. **Cooldown.** After a strike the detector ignores the level for [cooldown],
///     so one long outburst is one strike rather than one every sample.
///
/// The median (not the mean) is what calibration reads, so a student who talks
/// through the first seconds of an exam cannot drag the room floor up to their
/// voice - and even if the estimate is skewed, the clamp keeps the threshold
/// usable.
class AudioNoiseDetector {
  AudioNoiseDetector({
    this.calibrationWindow = const Duration(seconds: 4),
    this.sustain = const Duration(seconds: 2),
    this.releaseGrace = const Duration(milliseconds: 400),
    this.cooldown = const Duration(seconds: 5),
    this.speechMarginDb = 12,
    this.minThresholdDb = -45,
    this.maxThresholdDb = -20,
    this.defaultThresholdDb = -30,
    this.minCalibrationSamples = 5,
    DateTime Function()? clock,
  })  : assert(sustain > Duration.zero, 'a zero sustain would log every sample'),
        assert(
          releaseGrace >= Duration.zero,
          'a negative grace would end every episode on the first dip',
        ),
        assert(
          minThresholdDb <= maxThresholdDb,
          'the clamp bounds are the wrong way round',
        ),
        _now = clock ?? DateTime.now,
        _thresholdDb = defaultThresholdDb;

  /// How long the room is measured before any strike can be logged.
  final Duration calibrationWindow;

  /// How long the level must add up to above the threshold before it is a strike.
  ///
  /// Two seconds is roughly one spoken sentence: long enough that a cough, a
  /// chair creak or a door cannot reach it, short enough that a student who
  /// answers their phone or talks a neighbour through a question is caught while
  /// they are still doing it.
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

  /// How long after a strike the level is ignored.
  final Duration cooldown;

  /// How far above the measured room floor counts as human noise rather than the
  /// room itself. ~12 dB over the floor is roughly the jump from a hum to a voice
  /// at normal speaking volume.
  final double speechMarginDb;

  /// Sensitivity bounds. Without the floor clamp a silent room would produce a
  /// threshold so low that the microphone's own noise floor reads as "talking".
  final double minThresholdDb;
  final double maxThresholdDb;

  /// Used until calibration has enough samples (and if it never gets any).
  final double defaultThresholdDb;

  /// How many samples calibration needs before it will trust its median.
  final int minCalibrationSamples;

  final DateTime Function() _now;

  final List<double> _calibrationSamples = <double>[];
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

    _samples++;
    _firstSampleAt ??= now;
    _peakDb = _peakDb == null ? decibels : math.max(_peakDb!, decibels);

    if (!isCalibrated) {
      _collectCalibration(decibels, now);
      return false;
    }

    if (isCoolingDown) {
      // Dead zone: the strike for this outburst has already been logged.
      _aboveSince = null;
      _belowSince = null;
      _noisy = false;
      return false;
    }

    if (decibels < _thresholdDb) {
      // Back under the threshold. Whether this *ends* the episode is decided by
      // the next sample that comes back above it: a dip shorter than
      // [releaseGrace] - the gap between two words - is bridged, a longer quiet
      // stretch restarts the window from scratch. Either way the amber "something
      // is building" state is off: this sample is not the noise.
      _belowSince ??= now;
      _noisy = false;
      return false;
    }

    // Above the threshold again. Bridge the dip if it was short enough, so that
    // talking (which is not one unbroken tone) still adds up to [sustain].
    final belowSince = _belowSince;
    if (belowSince != null) {
      if (now.difference(belowSince) >= releaseGrace) _aboveSince = null;
      _belowSince = null;
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
    _calibrationSamples.add(decibels);

    final started = _firstSampleAt;
    final elapsed = started == null ? Duration.zero : now.difference(started);
    if (elapsed < calibrationWindow) return;
    // The source may be slower than expected; waiting for a few real samples beats
    // calibrating off one or two readings.
    if (_calibrationSamples.length < minCalibrationSamples) return;

    _roomFloorDb = _median(_calibrationSamples);
    _thresholdDb = (_roomFloorDb! + speechMarginDb)
        .clamp(minThresholdDb, maxThresholdDb)
        .toDouble();
  }

  /// Median of a copy, so calibration cannot see a partially sorted list.
  static double _median(List<double> values) {
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
