import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/audio_monitor.dart';
import '../../../../core/services/audio_noise_detector.dart';
import '../../../../core/utils/proctor_log.dart';
import 'proctoring_provider.dart';

/// Everything the exam chrome needs to render the microphone indicator: the
/// transport state, the live level, the calibrated threshold, and how many
/// `audio_noise` strikes this attempt has already logged.
class AudioMonitoringState {
  const AudioMonitoringState({
    this.monitor = AudioMonitorState.idle,
    this.message,
    this.levelDb,
    this.peakDb,
    this.thresholdDb,
    this.calibrated = false,
    this.noisy = false,
    this.coolingDown = false,
    this.violations = 0,
    this.lastViolationAt,
  });

  /// Where the microphone itself got to (permission, device, interruption).
  final AudioMonitorState monitor;

  /// Student-facing explanation for [monitor]'s failure states.
  final String? message;

  /// Latest dBFS sample.
  final double? levelDb;

  /// Loudest sample of the session.
  final double? peakDb;

  /// What "too loud for this room" currently means (null until calibration).
  final double? thresholdDb;

  /// True once the room's own noise floor has been measured.
  final bool calibrated;

  /// True while the level is above the threshold but the sustain window has not
  /// elapsed - the "something is building" state the chip shows in amber.
  final bool noisy;

  /// True inside the post-strike cooldown, when the detector deliberately ignores
  /// the level.
  final bool coolingDown;

  /// How many `audio_noise` violations this session has logged.
  final int violations;

  final DateTime? lastViolationAt;

  /// True while room levels are actually being judged.
  bool get isActive => monitor.isMonitoring;

  /// True when the student (or a supervisor) has to do something.
  bool get needsAttention => monitor.needsAttention;

  /// True while the detector is measuring the room.
  bool get isCalibrating => isActive && !calibrated;

  /// True when the last sample was loud enough to be suspicious.
  bool get isAboveThreshold =>
      levelDb != null && thresholdDb != null && levelDb! >= thresholdDb!;

  /// The level as a 0..1 fraction of a -60..0 dBFS meter, for the chip's meter.
  ///
  /// -60 dBFS is a whisper in a quiet room, 0 is clipping: showing anything below
  /// that window would be a permanently empty bar for a normal exam room.
  double get levelFraction {
    final level = levelDb;
    if (level == null) return 0;
    return ((level + 60) / 60).clamp(0.0, 1.0).toDouble();
  }

  /// The same fraction for the threshold, so the chip can draw the line the level
  /// has to cross.
  double get thresholdFraction {
    final threshold = thresholdDb;
    if (threshold == null) return 0;
    return ((threshold + 60) / 60).clamp(0.0, 1.0).toDouble();
  }

  AudioMonitoringState copyWith({
    AudioMonitorState? monitor,
    String? message,
    double? levelDb,
    double? peakDb,
    double? thresholdDb,
    bool? calibrated,
    bool? noisy,
    bool? coolingDown,
    int? violations,
    DateTime? lastViolationAt,
  }) =>
      AudioMonitoringState(
        monitor: monitor ?? this.monitor,
        message: message ?? this.message,
        levelDb: levelDb ?? this.levelDb,
        peakDb: peakDb ?? this.peakDb,
        thresholdDb: thresholdDb ?? this.thresholdDb,
        calibrated: calibrated ?? this.calibrated,
        noisy: noisy ?? this.noisy,
        coolingDown: coolingDown ?? this.coolingDown,
        violations: violations ?? this.violations,
        lastViolationAt: lastViolationAt ?? this.lastViolationAt,
      );

  @override
  String toString() => 'AudioMonitoringState(${monitor.name}, '
      'level: ${levelDb?.toStringAsFixed(1)}, '
      'threshold: ${thresholdDb?.toStringAsFixed(1)}, '
      'calibrated: $calibrated, violations: $violations)';
}

/// One microphone session per exam attempt: owns the [AudioMonitor] (the device)
/// and the [AudioNoiseDetector] (the rules), and reports a strike through
/// [onNoiseDetected] when the detector says the room has been loud for long enough.
///
/// The division of labour is the point:
///
///  * the monitor answers *"can we hear the room, and how loud is it?"*;
///  * the detector answers *"is this a cough or is this the student talking?"*;
///  * the notifier answers *"does that cost a strike?"* - through
///    [ProctoringNotifier.reportAudioNoise], so an audio strike takes exactly the
///    same path as `no_face` or `app_minimized`: overlay, server-side count,
///    3-strike escalation, offline queue and all.
class AudioMonitoringNotifier extends StateNotifier<AudioMonitoringState> {
  AudioMonitoringNotifier({
    required this.onNoiseDetected,
    AudioMonitor? monitor,
    AudioNoiseDetector? detector,
  })  : _monitor = monitor ?? AudioMonitor(),
        _detector = detector ?? AudioNoiseDetector(),
        super(const AudioMonitoringState()) {
    _stateSubscription = _monitor.stateChanges.listen((_) => _publish());
    _levelSubscription = _monitor.levels.listen(_onLevel);
  }

  /// Called once per confirmed audio violation. The exam page binds this to
  /// `ProctoringNotifier.reportAudioNoise`.
  final void Function() onNoiseDetected;

  final AudioMonitor _monitor;
  final AudioNoiseDetector _detector;

  StreamSubscription<AudioMonitorState>? _stateSubscription;
  StreamSubscription<double>? _levelSubscription;

  int _violations = 0;
  DateTime? _lastViolationAt;
  bool _disposed = false;

  /// The live monitor, for callers that want levels/peaks without the state.
  AudioMonitor get monitor => _monitor;

  /// Starts monitoring. Safe to call once per session (a second call is a no-op)
  /// and it never throws: a microphone failure becomes a state, and the exam
  /// continues.
  Future<void> start() async {
    if (_disposed) return;
    await _monitor.start();
    _publish();
  }

  /// The student's "reconnect" action after access was refused or the device
  /// went away.
  ///
  /// Recalibrates from scratch, because a new microphone (a headset, another
  /// room, the phone picked back up) is a new noise floor - reusing the old one
  /// would either deafen or over-sensitise the detector.
  Future<void> retry() async {
    if (_disposed) return;
    await _monitor.stop();
    _detector.reset();
    await _monitor.start();
    _publish();
  }

  /// Releases the microphone (called when the attempt ends).
  Future<void> stop() async {
    if (_disposed) return;
    await _monitor.stop();
    _publish();
  }

  void _onLevel(double decibels) {
    if (_disposed) return;

    if (_detector.add(decibels)) {
      _violations++;
      _lastViolationAt = DateTime.now();
      // The one line that makes this feature auditable from a debug console: what
      // the microphone heard, what the room's own floor made the threshold, and
      // how long the level had to hold. Without it, "audio never flagged
      // anything" is indistinguishable from "the room was quiet".
      proctorLog(
        'ProctorGuard audio: audio_noise classified at '
        '${decibels.toStringAsFixed(1)} dBFS (threshold '
        '${_detector.thresholdDb.toStringAsFixed(1)} dBFS, floor '
        '${_detector.roomFloorDb?.toStringAsFixed(1) ?? 'n/a'} dBFS, '
        'sustain ${_detector.sustain.inMilliseconds} ms).',
      );
      // Hand it to the proctoring notifier: same ladder, same server-side count,
      // same offline queue as every other violation.
      onNoiseDetected();
    }
    _publish();
  }

  void _publish() {
    if (_disposed) return;
    state = AudioMonitoringState(
      monitor: _monitor.state,
      message: _monitor.message,
      levelDb: _monitor.currentLevel,
      peakDb: _monitor.peakLevel,
      thresholdDb: _detector.thresholdDb,
      calibrated: _detector.isCalibrated,
      noisy: _detector.isNoisy,
      coolingDown: _detector.isCoolingDown,
      violations: _violations,
      lastViolationAt: _lastViolationAt,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stateSubscription?.cancel());
    unawaited(_levelSubscription?.cancel());
    _stateSubscription = null;
    _levelSubscription = null;
    _monitor.dispose();
    super.dispose();
  }
}

/// Where the microphone samples come from, and the seam that swaps the capture
/// stack: `null` means "the real `record` plugin" ([RecordAudioLevelSource]).
///
/// `flutter test` runs on the Dart VM, where no audio plugin is registered, so the
/// real source resolves straight to [AudioMonitorState.unavailable]. A widget test
/// (or a desktop demo) therefore injects a source of its own, the same way it
/// injects the browser guards - so it can drive a *working* microphone, one that
/// refuses, or one that is unplugged mid-session, instead of asserting on a chip
/// that can only ever say "unavailable".
final audioLevelSourceProvider = Provider<AudioLevelSource?>((ref) => null);

/// Audio monitoring for one attempt, keyed by `submissionId` so it is created when
/// the exam screen mounts and released when it goes away (which is what closes the
/// microphone).
///
/// No `ref.onDispose(notifier.dispose)` on purpose: Riverpod's
/// `StateNotifierProvider` already disposes the notifier it created, and
/// registering it twice made every teardown try to use a disposed object (the same
/// note as in `proctoringProvider`).
final audioMonitoringProvider = StateNotifierProvider.autoDispose
    .family<AudioMonitoringNotifier, AudioMonitoringState, String>(
        (ref, submissionId) {
  final source = ref.watch(audioLevelSourceProvider);
  return AudioMonitoringNotifier(
    monitor: source == null ? null : AudioMonitor(source: source),
    onNoiseDetected: () => ref
        .read(proctoringProvider(submissionId).notifier)
        .reportAudioNoise(),
  );
});
