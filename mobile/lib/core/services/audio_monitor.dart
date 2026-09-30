import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:record/record.dart';

/// How far the microphone got in this session.
///
/// The exam chrome renders this directly, so every state has a student-facing
/// [AudioMonitorStateX.label] and a [AudioMonitorStateX.needsAttention] flag: the
/// requirement is that a blocked or disconnected microphone is *visible*, never a
/// silent gap in proctoring.
enum AudioMonitorState {
  /// Not started, or stopped: no microphone is open.
  idle,

  /// Asking for access, opening the recorder, or waiting for the first sample.
  starting,

  /// The microphone is open and levels are flowing.
  monitoring,

  /// Access was refused (the student answered the OS/browser prompt with "no", or
  /// a policy blocks it).
  permissionDenied,

  /// This platform/device cannot give us levels at all (no capture path, no
  /// permission API, or the device reports silence forever).
  unavailable,

  /// The stream stopped mid-session: headset unplugged, permission revoked while
  /// the exam was running, or another app took the input device.
  interrupted,

  /// Turned off on purpose with `--dart-define=AUDIO_MONITORING=false`.
  disabled,
}

extension AudioMonitorStateX on AudioMonitorState {
  /// True while room levels are actually being sampled.
  bool get isMonitoring => this == AudioMonitorState.monitoring;

  /// True when the student has to do something about it (allow access, plug the
  /// microphone back in) or a supervisor does.
  bool get needsAttention =>
      this == AudioMonitorState.permissionDenied ||
      this == AudioMonitorState.interrupted ||
      this == AudioMonitorState.unavailable;

  /// Short text for the indicator chip.
  String get label => switch (this) {
        AudioMonitorState.idle => 'Mic off',
        AudioMonitorState.starting => 'Mic starting',
        AudioMonitorState.monitoring => 'Mic live',
        AudioMonitorState.permissionDenied => 'Mic blocked',
        AudioMonitorState.unavailable => 'Mic unavailable',
        AudioMonitorState.interrupted => 'Mic lost',
        AudioMonitorState.disabled => 'Audio off',
      };
}

/// The raw microphone behind [AudioMonitor].
///
/// Exists as a seam for two reasons: `flutter test` has no microphone worth
/// opening (so the tests drive a fake), and a host that wants a different capture
/// stack (a platform SDK, a pre-recorded fixture, a future on-device VAD) can swap
/// it without touching the detector or the UI.
abstract class AudioLevelSource {
  /// False when this platform has no capture implementation at all.
  bool get isSupported;

  /// Asks for (and reports) microphone access.
  ///
  /// Returns false when access was **refused**. It throws when the platform could
  /// not answer at all - those two need different words for the student, so the
  /// monitor reports them as different states.
  Future<bool> requestAccess();

  /// Opens the capture session. Throws when it cannot (device busy, no input,
  /// unsupported encoder).
  Future<void> begin();

  /// dBFS samples, roughly -90 (silence) to 0 (clipping). An error here means the
  /// device went away, and the monitor reports [AudioMonitorState.interrupted].
  Stream<double> get levels;

  /// Releases the capture session. Never throws.
  Future<void> end();

  /// Final teardown; the source is unusable afterwards.
  void dispose();
}

/// The production source: the `record` package.
///
/// One implementation for every target this app ships to - Android, iOS, web,
/// Windows, macOS and Linux all report amplitude (dBFS) through the same API - so
/// there is no per-platform branching here, only per-device *capability*, which the
/// monitor discovers at runtime instead of assuming.
///
/// The session **streams PCM and writes no file**: nothing records the room, and
/// the bytes are drained (never analysed, never kept) so the platform does not
/// buffer them. Only the decibel numbers travel on.
class RecordAudioLevelSource implements AudioLevelSource {
  RecordAudioLevelSource({
    this.sampleInterval = const Duration(milliseconds: 250),
  });

  /// How often the platform is asked for a level. Four samples a second is enough
  /// for a detector that works on multi-second windows, and it keeps the platform
  /// bridge quiet.
  final Duration sampleInterval;

  final StreamController<double> _levels = StreamController<double>.broadcast();

  AudioRecorder? _recorder;
  StreamSubscription<Amplitude>? _amplitudeSubscription;
  StreamSubscription<Uint8List>? _pcmSubscription;
  bool _disposed = false;

  /// True between a successful [begin] and the [end] that releases it.
  ///
  /// Exists so [begin] can tell "opening the first session" from "reopening one
  /// this source still holds" without asking the platform (a `stop()` on a
  /// recorder that was never started throws, and logging that would be noise).
  bool _sessionOpen = false;

  @override
  bool get isSupported => !_disposed;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<bool> requestAccess() async {
    final recorder = _recorder ??= AudioRecorder();
    // `request` defaults to true, which is what makes this "ask the student" rather
    // than "check": the OS dialog (Android) or the browser prompt (web) appears
    // here, which is exactly the graceful request the exam session needs.
    return recorder.hasPermission();
  }

  @override
  Future<void> begin() async {
    final recorder = _recorder ??= AudioRecorder();

    // A second `begin()` without an `end()` in between used to overwrite the two
    // subscriptions below without cancelling them, i.e. leak a listener per
    // reopen while the recorder still held a session. `AudioMonitor.start()`
    // releases the source before it reopens for exactly this reason, but the
    // source is a public seam and must not depend on a caller remembering to.
    if (_sessionOpen) await end();

    // A `dispose` that landed while a previous session was being released has
    // already torn this source down: opening the device after it would hold the
    // microphone for the rest of the run with no handle left to release it.
    if (_disposed) return;

    final pcm = await recorder.startStream(
      const RecordConfig(
        // Stream, not a file: see the class doc.
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        // Honest levels. Auto-gain and noise suppression would flatten exactly the
        // difference the detector calibrates on (room hum versus a voice), and a
        // suppressed cough would stop looking like a cough.
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
    );
    // The device opened while the session was ending: `dispose` owns the recorder
    // now, so subscribing here would leave two listeners on a stream nothing feeds
    // any more, and `_sessionOpen = true` on a source that is already torn down.
    if (_disposed) return;

    _pcmSubscription = pcm.listen(
      (_) {}, // drained and discarded on purpose
      onError: _reportError,
      cancelOnError: false,
    );

    _amplitudeSubscription = recorder
        .onAmplitudeChanged(sampleInterval)
        .listen((amplitude) => _emit(amplitude.current), onError: _reportError);
    _sessionOpen = true;
  }

  void _emit(double decibels) {
    if (_disposed || _levels.isClosed) return;
    _levels.add(decibels);
  }

  void _reportError(Object error, [StackTrace? stackTrace]) {
    if (_disposed || _levels.isClosed) return;
    // The monitor turns this into `interrupted` and prompts the student; it must
    // never look like a crash.
    _levels.addError(error, stackTrace);
  }

  @override
  Future<void> end() async {
    await _amplitudeSubscription?.cancel();
    _amplitudeSubscription = null;
    await _pcmSubscription?.cancel();
    _pcmSubscription = null;
    _sessionOpen = false;

    final recorder = _recorder;
    if (recorder == null) return;
    try {
      await recorder.stop();
    } catch (error) {
      // Already stopped, or the platform is gone: nothing left to release.
      debugPrint('ProctorGuard audio: stop failed: $error');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionOpen = false;
    unawaited(_amplitudeSubscription?.cancel());
    unawaited(_pcmSubscription?.cancel());
    _amplitudeSubscription = null;
    _pcmSubscription = null;

    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      // Best effort and never awaited: dispose has to be safe during a widget
      // teardown, and the platform releases the input device either way.
      unawaited(recorder.dispose().catchError((Object error) {
        debugPrint('ProctorGuard audio: dispose failed: $error');
      }));
    }
    unawaited(_levels.close());
  }
}

/// Owns one microphone session and its level stream for an exam attempt.
///
/// A thin, explicit state machine rather than a bag of futures, because every way
/// this can fail has to end somewhere the student can act:
///
/// | Situation | State | What the exam chrome does |
/// | --- | --- | --- |
/// | `--dart-define=AUDIO_MONITORING=false` | [AudioMonitorState.disabled] | shows "Audio off", logs nothing |
/// | No capture path on this platform | [AudioMonitorState.unavailable] | says so once, never blocks the exam |
/// | Student/OS refuses access | [AudioMonitorState.permissionDenied] | "Mic blocked" + allow/settings action |
/// | Device cannot be opened (busy, no input) | [AudioMonitorState.unavailable] | "Mic unavailable" + retry |
/// | No levels at all for [levelTimeout] | [AudioMonitorState.unavailable] | never pretends to monitor |
/// | Stream dies mid-session | [AudioMonitorState.interrupted] | "Mic lost" + reconnect prompt |
///
/// Nothing here throws and nothing here blocks: a microphone problem must never
/// take an exam down, it must only be visible.
class AudioMonitor {
  AudioMonitor({
    AudioLevelSource? source,
    bool? enabled,
    this.startTimeout = const Duration(seconds: 8),
    this.levelTimeout = const Duration(seconds: 4),
    this.endTimeout = const Duration(seconds: 3),
  })  : _source = source ?? RecordAudioLevelSource(),
        _enabled = enabled ?? enabledFromEnvironment;

  /// Turns the whole feature off for a build or a demo run:
  /// `flutter run --dart-define=AUDIO_MONITORING=false`.
  ///
  /// The state then reports [AudioMonitorState.disabled] rather than an error, so
  /// a desktop demo without a microphone (or a device farm) is not covered in red
  /// warnings for a feature that was deliberately switched off.
  static bool get enabledFromEnvironment =>
      const String.fromEnvironment('AUDIO_MONITORING', defaultValue: 'true')
          .toLowerCase() !=
      'false';

  /// Upper bound on asking for access and opening the recorder.
  ///
  /// A platform bridge that never answers must not leave the session in
  /// [AudioMonitorState.starting] forever: timing out reports "unavailable", which
  /// is honest and actionable.
  final Duration startTimeout;

  /// How long to wait for the *first* level before concluding the device cannot
  /// report them. Without this a broken microphone would look exactly like a
  /// perfectly quiet room - the one failure mode proctoring must not have.
  final Duration levelTimeout;

  /// Upper bound on *releasing* the capture session.
  ///
  /// `record` sends every platform call through a single global permit, so a call
  /// the device never answered - a microphone pulled out mid-session, a driver that
  /// went away - holds that permit and every later call queues behind it. Waiting
  /// here unbounded would therefore take the reconnect down with the microphone, and
  /// the reconnect is the one action a student in trouble has left. Giving up is
  /// harmless: the next [start] asks the device itself and reports what it finds,
  /// inside [startTimeout].
  final Duration endTimeout;

  final AudioLevelSource _source;
  final bool _enabled;

  final StreamController<AudioMonitorState> _stateChanges =
      StreamController<AudioMonitorState>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();

  StreamSubscription<double>? _levelSubscription;
  Timer? _levelTimer;
  AudioMonitorState _state = AudioMonitorState.idle;
  String? _message;
  double? _currentLevel;
  double? _peakLevel;
  bool _disposed = false;

  /// Where the microphone got to (see [AudioMonitorState]).
  AudioMonitorState get state => _state;

  /// Student-facing explanation for a failure state, if there is one.
  String? get message => _message;

  /// True while levels are flowing.
  bool get isMonitoring => _state == AudioMonitorState.monitoring;

  /// Most recent dBFS sample.
  double? get currentLevel => _currentLevel;

  /// Loudest sample since [start] - what the indicator's tooltip shows, and the
  /// number a supervisor wants when a student asks "why did I get a strike?".
  double? get peakLevel => _peakLevel;

  /// State transitions, including the first `monitoring` once levels arrive.
  Stream<AudioMonitorState> get stateChanges => _stateChanges.stream;

  /// Every dBFS sample, for the detector.
  Stream<double> get levels => _levels.stream;

  /// Asks for access, opens the microphone and starts forwarding levels.
  ///
  /// Safe to call twice (a second call while already monitoring is a no-op) and
  /// safe to call again after a failure - which is exactly what the "reconnect"
  /// action in the UI does through `AudioMonitoringNotifier.retry()`.
  Future<AudioMonitorState> start() async {
    if (_disposed) return _state;
    if (!_enabled) {
      return _transition(
        AudioMonitorState.disabled,
        'Audio monitoring is switched off for this build.',
      );
    }
    if (!_source.isSupported) {
      return _transition(
        AudioMonitorState.unavailable,
        'This platform cannot monitor audio.',
      );
    }
    if (_state == AudioMonitorState.monitoring ||
        _state == AudioMonitorState.starting) {
      return _state;
    }

    // Clean slate. A restart after `interrupted` - or the exam page's
    // re-bootstrap after a failed one - must not inherit the previous listener or
    // capture session: a stale subscription would feed the detector every sample
    // twice, and `record` would be asked to open a session it still holds. The
    // stale *level* goes too, so the indicator cannot show a reading from a
    // microphone that is no longer there.
    //
    // The cancel is deliberately *not* awaited, for the same reason [dispose] does
    // not await it: it is a cleanup signal, and a capture stack whose teardown
    // future never completes must not be able to hang the reconnect - which is the
    // one path a student in trouble has left.
    _levelTimer?.cancel();
    _levelTimer = null;
    unawaited(_levelSubscription?.cancel());
    _levelSubscription = null;
    _currentLevel = null;
    // The peak goes too: it is a claim about *this* capture session, and the
    // indicator shows it next to the live level. Keeping a loud moment from a
    // microphone that has since been replaced would report a room the student is
    // no longer sitting in - and the reconnect path ([retry]) is exactly when the
    // room, the headset or the device changed.
    _peakLevel = null;
    if (_state != AudioMonitorState.idle) {
      await _releaseSource();
    }

    _transition(AudioMonitorState.starting);

    bool granted;
    try {
      granted = await _source.requestAccess().timeout(startTimeout);
    } catch (error) {
      debugPrint('ProctorGuard audio: access could not be requested: $error');
      if (_disposed) return _state;
      return _transition(
        AudioMonitorState.unavailable,
        kIsWeb
            ? 'This browser cannot share the microphone with the exam.'
            : 'This device cannot report microphone state.',
      );
    }

    // `dispose()` may have run while the permission prompt was open. Leaving here
    // is what keeps a torn-down monitor from opening the device (and starting a
    // level timer) for a session nobody is watching - the source guards the same
    // race from the inside, see `RecordAudioLevelSource.begin`.
    if (_disposed) return _state;

    if (!granted) {
      return _transition(
        AudioMonitorState.permissionDenied,
        kIsWeb
            ? 'Microphone access is blocked. Allow it for this site in your '
                'browser settings, then tap the microphone to try again.'
            : 'Microphone access was refused. Allow it for ProctorGuard in '
                'settings, then tap the microphone to try again.',
      );
    }

    try {
      await _source.begin().timeout(startTimeout);
    } catch (error) {
      debugPrint('ProctorGuard audio: could not open the microphone: $error');
      if (_disposed) return _state;
      return _transition(
        AudioMonitorState.unavailable,
        'The microphone could not be opened. It may be in use by another app - '
        'close that app and tap the microphone to try again.',
      );
    }

    // Subscribing is what makes the monitor live: a teardown that landed while the
    // device was opening must not leave a listener, a state transition or a level
    // timer behind on a disposed object.
    if (_disposed) return _state;

    _levelSubscription = _source.levels.listen(
      _onLevel,
      onError: _onStreamError,
      onDone: _onStreamDone,
    );
    // Levels are the proof of life: only the first sample moves the state to
    // `monitoring`.
    _levelTimer = Timer(levelTimeout, () {
      if (_state == AudioMonitorState.monitoring || _disposed) return;
      _transition(
        AudioMonitorState.unavailable,
        'The microphone is not reporting any sound levels on this device, so '
        'audio proctoring is off for this attempt.',
      );
    });

    return _state;
  }

  void _onLevel(double decibels) {
    if (_disposed) return;
    _currentLevel = decibels;
    _peakLevel = _peakLevel == null
        ? decibels
        : (decibels > _peakLevel! ? decibels : _peakLevel);
    _levelTimer?.cancel();
    _levelTimer = null;
    if (_state != AudioMonitorState.monitoring) {
      _transition(AudioMonitorState.monitoring);
    }
    if (!_levels.isClosed) _levels.add(decibels);
  }

  void _onStreamError(Object error, [StackTrace? stackTrace]) {
    // An error from a stream a teardown already cancelled must not move a disposed
    // monitor's state (the cancel is not awaited, so this can still arrive).
    if (_disposed) return;
    debugPrint('ProctorGuard audio: level stream failed: $error');
    if (_state == AudioMonitorState.monitoring ||
        _state == AudioMonitorState.starting) {
      _transition(
        AudioMonitorState.interrupted,
        'The microphone stopped responding. Reconnect it (or answer the browser '
        'prompt) and tap the microphone to resume audio proctoring.',
      );
    }
  }

  void _onStreamDone() {
    // Same as [_onStreamError]: a close that follows a teardown is not an event
    // about this session.
    if (_disposed) return;
    // The stream closing without us asking for it is the "headset unplugged" case.
    if (_state == AudioMonitorState.monitoring ||
        _state == AudioMonitorState.starting) {
      _transition(
        AudioMonitorState.interrupted,
        'The microphone was disconnected. Reconnect it and tap the microphone '
        'to resume audio proctoring.',
      );
    }
  }

  /// Closes the session and releases the device. Never throws.
  ///
  /// The subscription cancel is not awaited (see [start]): the device release is
  /// what matters, and that release is time-boxed as well ([endTimeout]) - a capture
  /// stack whose teardown future never completes must not be able to strand the
  /// reconnect that called this, which is the one action a student in trouble has
  /// left.
  Future<void> stop() async {
    // Nothing left to stop: [dispose] already cancelled the listener and released
    // the source. This is the one path that would otherwise reach into a disposed
    // source while the exam page is being torn down.
    if (_disposed) return;

    _levelTimer?.cancel();
    _levelTimer = null;
    unawaited(_levelSubscription?.cancel());
    _levelSubscription = null;

    if (_state != AudioMonitorState.disabled) {
      await _releaseSource();
      _currentLevel = null;
      _transition(AudioMonitorState.idle);
    }
  }

  /// Releases the capture session, but never waits longer than [endTimeout].
  ///
  /// This sits on the reconnect path ([stop] is what `retry()` calls first), so the
  /// wait is bounded rather than trusted: see [endTimeout]. A release that failed is
  /// not a state the student can act on - the start that follows reports what the
  /// device does now, which is the honest answer.
  Future<void> _releaseSource() async {
    try {
      await _source.end().timeout(endTimeout);
    } on TimeoutException {
      debugPrint(
        'ProctorGuard audio: the session did not release within $endTimeout',
      );
    } catch (error) {
      debugPrint('ProctorGuard audio: release failed: $error');
    }
  }

  /// Tear-down for the session: the monitor is unusable afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _levelTimer?.cancel();
    _levelTimer = null;
    unawaited(_levelSubscription?.cancel());
    _levelSubscription = null;
    _source.dispose();
    unawaited(_stateChanges.close());
    unawaited(_levels.close());
  }

  AudioMonitorState _transition(AudioMonitorState next, [String? message]) {
    _state = next;
    _message = message;
    if (!_stateChanges.isClosed) _stateChanges.add(next);
    return next;
  }
}
