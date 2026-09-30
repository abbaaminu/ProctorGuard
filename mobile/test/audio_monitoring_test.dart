import 'dart:async';

import 'package:exam_proctor/core/services/audio_monitor.dart';
import 'package:exam_proctor/core/services/audio_noise_detector.dart';
import 'package:exam_proctor/features/proctoring/presentation/providers/audio_monitoring_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The audio half of proctoring, in the three layers it is built from:
///
///  * [AudioNoiseDetector] - the **rules** (calibration, sustain, cooldown), pure
///    Dart and driven by an injected clock, so no test waits on real time;
///  * [AudioMonitor] - the **device** (permission, capture session, and the way
///    each failure becomes a state the student can act on), driven by a fake
///    source because a Dart VM test has no audio plugin;
///  * [AudioMonitoringNotifier] - the **join**: samples in, one
///    `onNoiseDetected` per episode out, and the state the indicator renders.
void main() {
  group('AudioNoiseDetector', () {
    late DateTime now;

    setUp(() => now = DateTime.utc(2026, 6, 1, 9));

    AudioNoiseDetector detector({
      Duration calibrationWindow = Duration.zero,
      Duration sustain = const Duration(seconds: 4),
      Duration cooldown = const Duration(seconds: 5),
      int minCalibrationSamples = 1,
    }) =>
        AudioNoiseDetector(
          calibrationWindow: calibrationWindow,
          sustain: sustain,
          cooldown: cooldown,
          minCalibrationSamples: minCalibrationSamples,
          clock: () => now,
        );

    test('the room is measured with a median, so a cough cannot skew it', () {
      final sensor = detector(
        calibrationWindow: const Duration(seconds: 4),
        minCalibrationSamples: 5,
      );

      // Four quiet seconds...
      for (var i = 0; i < 4; i++) {
        expect(sensor.add(-60), isFalse);
        now = now.add(const Duration(seconds: 1));
      }
      // ...and one loud sample, which the median must ignore.
      expect(sensor.add(-20), isFalse); // this sample completes calibration

      expect(sensor.isCalibrated, isTrue);
      expect(sensor.roomFloorDb, -60);
      // Floor + 12 dB of speech margin, clamped into the usable band: a -48 dBFS
      // threshold would be so low that the microphone's own noise floor reads as
      // talking.
      expect(sensor.thresholdDb, -45);
    });

    test('the threshold follows the room, clamped so neither end is silly', () {
      final quietRoom = detector();
      quietRoom.add(-62);
      expect(quietRoom.thresholdDb, -45); // -50 clamped up

      final hummingRoom = detector();
      hummingRoom.add(-38);
      expect(hummingRoom.thresholdDb, -26); // -38 + 12, inside the band

      final loudHall = detector();
      loudHall.add(-15);
      expect(loudHall.thresholdDb, -20); // +12 clamped down
    });

    test('a level held above the threshold is one strike', () {
      final sensor = detector(sustain: const Duration(seconds: 4));
      sensor.add(-60); // calibrates in one sample: threshold -45

      expect(sensor.add(-30), isFalse); // opens the window
      expect(sensor.isNoisy, isTrue); // amber on the chip, no strike yet

      now = now.add(const Duration(seconds: 3));
      expect(sensor.add(-30), isFalse); // still inside the sustain window

      now = now.add(const Duration(seconds: 2));
      expect(sensor.add(-30), isTrue); // five seconds of continuous noise
      expect(sensor.isNoisy, isFalse); // the episode is closed
    });

    test('one dip below the threshold restarts the window', () {
      final sensor = detector(sustain: const Duration(seconds: 4));
      sensor.add(-60);

      sensor.add(-30);
      now = now.add(const Duration(seconds: 3));
      sensor.add(-30);

      // A breath, a chair creak, a cough: whatever was building is over.
      expect(sensor.add(-70), isFalse);
      expect(sensor.isNoisy, isFalse);

      now = now.add(const Duration(seconds: 3));
      expect(sensor.add(-30), isFalse); // a fresh window starts from here
      now = now.add(const Duration(seconds: 4));
      expect(sensor.add(-30), isTrue); // four unbroken seconds: counted once
    });

    test('the cooldown keeps one long outburst to one strike', () {
      final sensor = detector(
        sustain: const Duration(seconds: 1),
        cooldown: const Duration(seconds: 5),
      );
      sensor.add(-60);

      sensor.add(-10);
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-10), isTrue);
      expect(sensor.isCoolingDown, isTrue);

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-10), isFalse); // still shouting, already counted

      now = now.add(const Duration(seconds: 10));
      sensor.add(-10);
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-10), isTrue); // a new outburst is a new strike
    });

    test('a misbehaving source cannot corrupt the calibration', () {
      final sensor = detector();

      expect(sensor.add(double.nan), isFalse);
      expect(sensor.add(double.infinity), isFalse);
      expect(sensor.add(double.negativeInfinity), isFalse);
      expect(sensor.samples, 0);
      expect(sensor.isCalibrated, isFalse);
    });

    test('reset() forgets the room, the episode and the cooldown', () {
      final sensor = detector(sustain: const Duration(seconds: 1));
      sensor.add(-60);
      sensor.add(-10);
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-10), isTrue);

      // What a reconnect does: a new microphone (or a new room) is a new noise
      // floor, so the old one must not be reused.
      sensor.reset();

      expect(sensor.isCalibrated, isFalse);
      expect(sensor.isCoolingDown, isFalse);
      expect(sensor.isNoisy, isFalse);
      expect(sensor.thresholdDb, -30); // back to the default until recalibrated
      expect(sensor.add(-10), isFalse); // and nothing is judged yet
    });
  });

  group('AudioMonitor', () {
    /// Short timeouts: the real ones exist so a plugin that never answers cannot
    /// strand a session, and the states they produce are what these tests assert.
    const startTimeout = Duration(milliseconds: 60);
    const levelTimeout = Duration(milliseconds: 40);

    AudioMonitor monitorWith(_FakeSource source, {bool enabled = true}) =>
        AudioMonitor(
          source: source,
          enabled: enabled,
          startTimeout: startTimeout,
          levelTimeout: levelTimeout,
        );

    test('a refused microphone is a state, not an exception', () async {
      final source = _FakeSource(granted: false);
      final monitor = monitorWith(source);
      addTearDown(monitor.dispose);

      expect(await monitor.start(), AudioMonitorState.permissionDenied);
      expect(monitor.message, contains('refused'));
      expect(monitor.isMonitoring, isFalse);
      // Nothing was opened: the refusal happened before the capture session, so the
      // device is still free for whatever the student does next.
      expect(source.begins, 0);
    });

    test('a device that will not open is reported as unavailable', () async {
      final monitor = monitorWith(_FakeSource(beginFails: true));
      addTearDown(monitor.dispose);

      expect(await monitor.start(), AudioMonitorState.unavailable);
      expect(monitor.message, contains('could not be opened'));
    });

    test('a platform with no capture path says so instead of pretending',
        () async {
      final monitor = monitorWith(_FakeSource(supported: false));
      addTearDown(monitor.dispose);

      expect(await monitor.start(), AudioMonitorState.unavailable);
      expect(monitor.isMonitoring, isFalse);
    });

    test('a build with AUDIO_MONITORING=false never opens the device', () async {
      final source = _FakeSource();
      final monitor = monitorWith(source, enabled: false);
      addTearDown(monitor.dispose);

      expect(await monitor.start(), AudioMonitorState.disabled);
      expect(monitor.message, contains('switched off'));
      expect(source.begins, 0);
    });

    test('levels are the proof of life: monitoring only once one arrives',
        () async {
      final monitor = monitorWith(_FakeSource());
      addTearDown(monitor.dispose);

      await monitor.start();
      expect(monitor.state, AudioMonitorState.starting);
      expect(monitor.isMonitoring, isFalse);

      await pumpEventQueue();
      expect(monitor.state, AudioMonitorState.monitoring);
      expect(monitor.currentLevel, isNotNull);
      expect(monitor.peakLevel, isNotNull);
    });

    test('a restart clears the peak of the session that just ended', () async {
      // The peak is what the indicator's tooltip shows and what a supervisor reads
      // when a student asks "why did I get a strike?". Carrying it across a restart
      // would report a loud moment from a microphone that is no longer there - and
      // the restart is exactly the reconnect path, where the headset, the room or
      // the device may have changed.
      final source = _FakeSource();
      final monitor = monitorWith(source);
      addTearDown(monitor.dispose);

      await monitor.start();
      await pumpEventQueue();
      source.emit(-8); // a shout
      await pumpEventQueue();
      expect(monitor.peakLevel, -8);

      await monitor.stop();
      await monitor.start(); // the student reconnected
      await pumpEventQueue();

      // The shout belongs to the session that ended; what the peak reports now is
      // the room this microphone is actually in.
      expect(
        monitor.peakLevel,
        _FakeSource.quiet,
        reason: 'a restart measures the new session, not the old one',
      );
    });

    test('a device that never reports a level is not called monitoring',
        () async {
      // The one failure mode proctoring must not have: a dead microphone that looks
      // exactly like a perfectly quiet room.
      final monitor = monitorWith(_FakeSource(emitOnListen: false));
      addTearDown(monitor.dispose);

      await monitor.start();
      await Future<void>.delayed(levelTimeout * 3);

      expect(monitor.state, AudioMonitorState.unavailable);
      expect(monitor.message, contains('not reporting any sound levels'));
    });

    test('a capture stream that fails mid-session is interrupted', () async {
      final source = _FakeSource();
      final monitor = monitorWith(source);
      addTearDown(monitor.dispose);

      await monitor.start();
      await pumpEventQueue();
      expect(monitor.state, AudioMonitorState.monitoring);

      source.fail();
      await pumpEventQueue();

      expect(monitor.state, AudioMonitorState.interrupted);
      expect(monitor.message, contains('stopped responding'));
    });

    test('the stream ending is the headset-unplugged case', () async {
      final source = _FakeSource();
      final monitor = monitorWith(source);
      addTearDown(monitor.dispose);

      await monitor.start();
      await pumpEventQueue();

      source.finish();
      await pumpEventQueue();

      expect(monitor.state, AudioMonitorState.interrupted);
      expect(monitor.message, contains('disconnected'));
    });

    test('a source that never releases cannot strand the reconnect', () async {
      // A capture stack whose teardown future never completes - the reason the
      // reconnect exists - must not hold up the reconnect itself. `stop()` is what
      // `retry()` calls first, so it has to come back on its own.
      final source = _FakeSource(endStops: true);
      final monitor = AudioMonitor(
        source: source,
        startTimeout: startTimeout,
        levelTimeout: levelTimeout,
        endTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(monitor.dispose);

      await monitor.start();
      await pumpEventQueue();
      expect(monitor.state, AudioMonitorState.monitoring);

      // Bounded by the test as well, so a regression fails here in a second rather
      // than hanging the suite.
      await monitor.stop().timeout(const Duration(seconds: 1));

      expect(source.ends, 1); // the release was attempted, not skipped
      expect(monitor.state, AudioMonitorState.idle);
      expect(monitor.currentLevel, isNull);

      // And the start that follows is a start, not another wait: the device itself
      // is what decides whether the microphone is usable now.
      expect(await monitor.start(), AudioMonitorState.starting);
      expect(source.begins, 2);
    });

    test('a restart does not leave a second listener behind', () async {
      final source = _FakeSource(emitOnListen: false);
      final monitor = monitorWith(source);
      addTearDown(monitor.dispose);

      var received = 0;
      final readings = monitor.levels.listen((_) => received++);

      await monitor.start();
      await pumpEventQueue();
      source.fail();
      await pumpEventQueue();
      expect(monitor.state, AudioMonitorState.interrupted);

      // What the exam page does on a re-bootstrap, and what the chip's reconnect
      // does: start again.
      await monitor.start();
      await pumpEventQueue();
      expect(source.begins, 2);

      source.emit(-40);
      await pumpEventQueue();

      // One sample, one reading. A stale subscription would make this two, and the
      // detector - which measures *time* above a threshold - would then see every
      // sample twice.
      expect(received, 1);
      await readings.cancel();
    });

    test('a teardown during the permission prompt never opens the device',
        () async {
      // The OS dialog is the longest wait on the start path, and it is exactly where a
      // popped exam page lands: the student leaves the app to answer it, so the page is
      // gone by the time they tap Allow. Opening the microphone there takes the device
      // for a session nobody is watching.
      final source = _FakeSource(accessGate: Completer<void>());
      final monitor = monitorWith(source);

      final pending = monitor.start();
      monitor.dispose();
      source.accessGate!.complete();

      // The answer to a start nobody is waiting for: no throw, no state of its own.
      expect(await pending, AudioMonitorState.starting);
      await pumpEventQueue();

      expect(source.begins, 0, reason: 'the device was never opened');
      expect(monitor.message, isNull);
      expect(monitor.isMonitoring, isFalse);
    });

    test('a teardown while the device is opening leaves no session behind',
        () async {
      // The same race one step later: `begin()` is the platform call that actually takes
      // the microphone. A listener created after the teardown reads a capture session
      // that was already released, and it outlives the handle that could cancel it -
      // nothing else would ever close it.
      final source =
          _FakeSource(beginGate: Completer<void>(), closeOnDispose: false);
      final monitor = monitorWith(source);

      final pending = monitor.start();
      await pumpEventQueue(); // the start is now inside `begin()`
      monitor.dispose();
      source.beginGate!.complete();

      expect(await pending, AudioMonitorState.starting);
      await pumpEventQueue();

      expect(source.begins, 1, reason: 'the open was already on the wire');
      expect(
        source.hasListener,
        isFalse,
        reason: 'a subscription created here is never cancelled by anyone',
      );
      expect(
        monitor.state,
        AudioMonitorState.starting,
        reason: 'a torn-down start reports nothing, not a disconnection',
      );
      expect(monitor.message, isNull);
      expect(monitor.isMonitoring, isFalse);
      source.finish();
    });

    test('a stop after teardown does not reach into the released source',
        () async {
      // `dispose()` (the page was popped) followed by `stop()` (a reconnect control that
      // is on screen for one more frame) would otherwise ask a disposed source to release
      // a capture session that is already gone.
      final source = _FakeSource(emitOnListen: false);
      final monitor = monitorWith(source);
      await monitor.start();
      await pumpEventQueue();

      monitor.dispose();
      monitor.dispose(); // idempotent
      await monitor.stop();

      expect(source.ends, 0, reason: 'dispose released the device, not stop');
      expect(monitor.state, AudioMonitorState.starting);
    });
  });

  group('AudioMonitoringNotifier', () {
    test('a sustained loud room reports one violation; a blip reports none',
        () async {
      var now = DateTime.utc(2026, 6, 1, 9);
      final source = _FakeSource(emitOnListen: false);
      var noises = 0;
      final notifier = AudioMonitoringNotifier(
        onNoiseDetected: () => noises++,
        monitor: AudioMonitor(
          source: source,
          levelTimeout: const Duration(seconds: 30),
        ),
        detector: AudioNoiseDetector(
          // The room is measured on the first sample and the strike follows the
          // injected clock, so the test never waits on real time.
          calibrationWindow: Duration.zero,
          minCalibrationSamples: 1,
          sustain: const Duration(milliseconds: 100),
          cooldown: const Duration(minutes: 5),
          clock: () => now,
        ),
      );
      addTearDown(notifier.dispose);

      await notifier.start();
      source.emit(-70); // the room reports its own level
      await pumpEventQueue();

      expect(notifier.state.monitor, AudioMonitorState.monitoring);
      expect(notifier.state.calibrated, isTrue);
      expect(notifier.state.thresholdDb, isNotNull);

      // A cough: loud, but over before the sustain window closes.
      source.emit(-10);
      await pumpEventQueue();
      expect(notifier.state.noisy, isTrue);
      source.emit(-70);
      await pumpEventQueue();
      expect(notifier.state.noisy, isFalse);
      expect(noises, 0);

      // Then the student actually talks: the level stays up past the window.
      now = now.add(const Duration(milliseconds: 200));
      source.emit(-10);
      await pumpEventQueue();
      now = now.add(const Duration(milliseconds: 200));
      source.emit(-10);
      await pumpEventQueue();

      expect(noises, 1);
      expect(notifier.state.violations, 1);
      expect(notifier.state.lastViolationAt, isNotNull);
      // The microphone is still live afterwards: an audio strike warns the student,
      // it does not end audio proctoring.
      expect(notifier.state.monitor, AudioMonitorState.monitoring);
    });

    test('the rendered state tracks the device, and a retry reopens it',
        () async {
      final source = _FakeSource();
      final notifier = AudioMonitoringNotifier(
        onNoiseDetected: () {},
        monitor: AudioMonitor(
          source: source,
          levelTimeout: const Duration(seconds: 30),
        ),
      );
      addTearDown(notifier.dispose);

      expect(notifier.state.monitor, AudioMonitorState.idle);
      expect(notifier.state.isActive, isFalse);
      expect(notifier.state.levelFraction, 0);

      await notifier.start();
      await pumpEventQueue();

      expect(notifier.state.monitor, AudioMonitorState.monitoring);
      expect(notifier.state.isActive, isTrue);
      expect(notifier.state.levelDb, isNotNull);
      expect(notifier.state.peakDb, isNotNull);
      expect(notifier.state.levelFraction, inInclusiveRange(0, 1));

      await notifier.retry();
      await pumpEventQueue();

      expect(source.begins, 2);
      expect(notifier.state.monitor, AudioMonitorState.monitoring);
      // The reconnect forgets the room: a different microphone is a different noise
      // floor, and reusing the old one would either deafen or over-sensitise it.
      expect(notifier.state.calibrated, isFalse);
    });

    test('a blocked microphone reaches the UI as a state, not a crash', () async {
      final source = _FakeSource(granted: false);
      final notifier = AudioMonitoringNotifier(
        onNoiseDetected: () {},
        monitor: AudioMonitor(source: source),
      );
      addTearDown(notifier.dispose);

      await notifier.start();
      await pumpEventQueue();

      expect(notifier.state.monitor, AudioMonitorState.permissionDenied);
      expect(notifier.state.needsAttention, isTrue);
      expect(notifier.state.message, isNotNull);
      expect(notifier.state.violations, 0);
    });
  });
}

/// A microphone with no platform plugin behind it, plus the controls to reproduce
/// every way the real one misbehaves.
///
/// [AudioMonitor] subscribes to [levels] *after* `begin()` returns, and a broadcast
/// controller drops events with no listener - so a level emitted from `begin()`
/// would be lost and a perfectly good microphone would look dead. The fake reports
/// its first level from `onListen` instead, exactly as a real capture session starts
/// producing samples as soon as it is being read.
class _FakeSource implements AudioLevelSource {
  _FakeSource({
    this.granted = true,
    this.supported = true,
    this.beginFails = false,
    this.emitOnListen = true,
    this.endStops = false,
    this.accessGate,
    this.beginGate,
    this.closeOnDispose = true,
  });

  /// What [requestAccess] answers. False is the "student tapped Don't allow" path.
  bool granted;

  /// False stands for a platform with no capture implementation at all.
  bool supported;

  /// True is the "another app is holding the microphone" case.
  bool beginFails;

  /// When set, [requestAccess] waits for it: stands for the OS permission dialog,
  /// which is the longest wait on the start path - the app is backgrounded to answer
  /// it, so it is also where a popped exam page lands.
  Completer<void>? accessGate;

  /// When set, [begin] waits for it: a capture device that is slow to open.
  Completer<void>? beginGate;

  /// Whether the capture session reports a level once someone is reading it.
  ///
  /// The sample it reports is [quiet] - below every threshold the detector can
  /// settle on, so merely opening the microphone is never a strike.
  bool emitOnListen;

  /// True makes the release hang: a capture stack whose teardown future never
  /// completes. `AudioMonitor` has to time that wait out rather than queue behind
  /// it, because the release runs on the reconnect path.
  bool endStops;

  /// Whether [dispose] closes the capture stream, as the real source does.
  ///
  /// A test that needs to *see* whether a listener was attached after the teardown
  /// needs this false - the fake filters every event once closed, so a late `listen`
  /// would leave no trace at all and the leak would be invisible.
  bool closeOnDispose;

  /// What a real capture session reports in a quiet room.
  static const double quiet = -60;

  /// How many capture sessions were opened - the first start, plus every reconnect.
  int begins = 0;

  /// How many times the capture session was released.
  int ends = 0;

  late final StreamController<double> _levels =
      StreamController<double>.broadcast(onListen: _reportFirstLevel);

  void _reportFirstLevel() {
    if (!emitOnListen) return;
    // Deferred, so the `_levelSubscription = ...listen(...)` this callback is
    // running inside has finished assigning before the sample arrives.
    scheduleMicrotask(() => emit(quiet));
  }

  /// Pushes one dBFS sample, as the platform would.
  void emit(double decibels) {
    if (!_levels.isClosed) _levels.add(decibels);
  }

  /// The device goes away mid-session: an error on the capture stream, which the
  /// monitor reads as `interrupted` rather than as silence.
  void fail() {
    if (!_levels.isClosed) _levels.addError(StateError('device gone'));
  }

  /// The stream ends, as it does when a headset is unplugged.
  void finish() => _levels.close();

  @override
  bool get isSupported => supported;

  @override
  Stream<double> get levels => _levels.stream;

  /// Whether anything is reading the capture stream: the leak the teardown tests
  /// look for, since a subscription created after the release outlives every handle
  /// that could cancel it.
  bool get hasListener => _levels.hasListener;

  @override
  Future<bool> requestAccess() async {
    if (accessGate != null) await accessGate!.future;
    return granted;
  }

  @override
  Future<void> begin() async {
    // Counted before the gate: the open was attempted even when it is torn down
    // mid-flight, which is exactly what the teardown tests assert on.
    begins++;
    if (beginGate != null) await beginGate!.future;
    if (beginFails) throw StateError('device busy');
  }

  @override
  Future<void> end() async {
    ends++;
    // Never completes, as a wedged capture stack does not.
    if (endStops) await Completer<void>().future;
  }

  @override
  void dispose() {
    if (closeOnDispose && !_levels.isClosed) _levels.close();
  }
}
