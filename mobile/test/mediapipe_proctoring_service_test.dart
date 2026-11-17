import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart';
import 'package:proctorguard/core/services/proctoring_thresholds.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the pure geometry of the proctoring engine.
///
/// The camera + ML Kit pipeline needs a device, but [estimateHeadPose] — the
/// fallback used with 3D-landmark models — is plain math and it is what turns
/// landmarks into the "looking away" decision, so it is worth pinning down.
/// Note that these tests also prove the service can be constructed and
/// disposed without touching a platform channel (the ML Kit [FaceDetector] is
/// created lazily).
void main() {
  late MediaPipeProctoringService engine;

  setUp(() => engine = MediaPipeProctoringService());
  tearDown(() => engine.dispose());

  group('estimateHeadPose', () {
    test('returns ~0/0 when the nose sits centred between the eyes', () {
      final (yaw, pitch) = engine.estimateHeadPose(
        noseTip: [0.0, 0.0, 0.0],
        leftEyeOuter: [-0.5, 0.0, 0.0],
        rightEyeOuter: [0.5, 0.0, 0.0],
      );

      expect(yaw, closeTo(0, 0.001));
      expect(pitch, closeTo(0, 0.001));
    });

    test('reports a yaw past the off-centre threshold when the head turns',
        () {
      final (yaw, _) = engine.estimateHeadPose(
        noseTip: [0.4, 0.0, 0.0],
        leftEyeOuter: [-0.5, 0.0, 0.0],
        rightEyeOuter: [0.5, 0.0, 0.0],
      );

      expect(yaw.abs(), greaterThan(engine.offCenterThresholdDegrees));
    });

    test('signs yaw positive when the nose moves toward the image right', () {
      final (yaw, _) = engine.estimateHeadPose(
        noseTip: [0.4, 0.0, 0.0],
        leftEyeOuter: [-0.5, 0.0, 0.0],
        rightEyeOuter: [0.5, 0.0, 0.0],
      );

      expect(yaw, greaterThan(0));
    });

    test('keeps yaw/pitch near zero when the nose is offset in depth only', () {
      final (yaw, pitch) = engine.estimateHeadPose(
        noseTip: [0.0, 0.0, -0.3],
        leftEyeOuter: [-0.5, 0.0, 0.0],
        rightEyeOuter: [0.5, 0.0, 0.0],
      );

      expect(yaw, closeTo(0, 0.001));
      expect(pitch, closeTo(0, 0.001));
    });

    test('signs pitch positive when the nose drops below the eye line', () {
      // Image coordinates grow downward, so "below" means a larger y.
      final (_, pitch) = engine.estimateHeadPose(
        noseTip: [0.0, 0.4, 0.0],
        leftEyeOuter: [-0.5, 0.0, 0.0],
        rightEyeOuter: [0.5, 0.0, 0.0],
      );

      expect(pitch, greaterThan(0));
    });

    test('degrades to 0/0 instead of dividing by zero on a collapsed eye line',
        () {
      final (yaw, pitch) = engine.estimateHeadPose(
        noseTip: [0.1, 0.1, 0.0],
        leftEyeOuter: [0.5, 0.0, 0.0],
        rightEyeOuter: [0.5, 0.0, 0.0],
      );

      expect(yaw, 0);
      expect(pitch, 0);
    });
  });

  group('look-away sustain and frame floor', () {
    late DateTime now;

    setUp(() => now = DateTime(2026, 1, 1, 12));

    /// An engine on a clock the test owns. The counted conditions below never
    /// read it — they count *frames*, which is the whole point — while the
    /// multi-face cooldown does, so a 30-second cooldown can be exercised
    /// instantly.
    ///
    /// [MediaPipeProctoringService.startupGrace] is switched *off* here: these tests
    /// start a sitting at `t0` and expect the first frames to count, and the shipped
    /// five-second window would swallow every one of them. The window itself has its
    /// own group below, on an engine that keeps the default.
    MediaPipeProctoringService clocked() {
      final engine = MediaPipeProctoringService(
        clock: () => now,
        startupGrace: Duration.zero,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    /// Feeds [count] identical results through the engine, as the camera stream
    /// would.
    void feed(
      MediaPipeProctoringService engine,
      FaceFrameResult result,
      int count,
    ) {
      for (var i = 0; i < count; i++) {
        engine.handleResult(result);
      }
    }

    /// Holds [result] for [duration], the way a camera would: frames keep arriving
    /// while the clock advances, so the sustain is measured over an unbroken *run*
    /// of off-centre frames rather than one frame and a jump in time.
    void hold(
      MediaPipeProctoringService engine,
      FaceFrameResult result, {
      required Duration duration,
    }) {
      final frames =
          (duration.inMilliseconds / engine.inferenceInterval.inMilliseconds)
              .ceil();
      for (var i = 0; i < frames; i++) {
        now = now.add(engine.inferenceInterval);
        engine.handleResult(result);
      }
    }

    test('two missing-face frames are not a violation, the third is',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      feed(engine, const FaceFrameResult(faceCount: 0), 2);
      await pumpEventQueue();
      expect(seen, isEmpty, reason: 'a strict three-frame threshold');

      feed(engine, const FaceFrameResult(faceCount: 0), 1);
      await pumpEventQueue();
      expect(seen, <GazeSignal>[GazeSignal.noFace]);
    });

    test('three consecutive missing frames log no_face exactly once',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      feed(engine, const FaceFrameResult(faceCount: 0), 3); // sustained
      now = now.add(const Duration(seconds: 30));
      feed(engine, const FaceFrameResult(faceCount: 0), 40); // same episode

      await pumpEventQueue();
      expect(seen, <GazeSignal>[GazeSignal.noFace]);
    });

    test('a single visible frame resets the count, so the run must be unbroken',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Two frames out, one frame back, two frames out: never three in a row.
      feed(engine, const FaceFrameResult(faceCount: 0), 2);
      feed(engine, const FaceFrameResult(faceCount: 1), 1);
      feed(engine, const FaceFrameResult(faceCount: 0), 2);

      await pumpEventQueue();
      expect(
        seen,
        isNot(contains(GazeSignal.noFace)),
        reason: 'a dropped frame must not accumulate towards a strike',
      );
    });

    test('the face returning re-arms a fresh absence episode', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      feed(engine, const FaceFrameResult(faceCount: 0), 3); // no_face #1
      feed(engine, const FaceFrameResult(faceCount: 1), 1); // visible again
      feed(engine, const FaceFrameResult(faceCount: 0), 3); // no_face #2

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.noFace),
        hasLength(2),
      );
    });

    test('a glance at the keyboard stays centered', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // 12 deg of yaw and 15 deg of pitch sit inside the tolerance - the pitch is
      // the boundary itself, and the comparison is strict, so a head exactly on the
      // line is still centered and a normal sitting position can never nudge a
      // strike.
      feed(
        engine,
        const FaceFrameResult(faceCount: 1, yawDegrees: 12, pitchDegrees: 15),
        10,
      );
      // The same boundary on the other axis and the other sign: 15 deg of yaw to
      // the left, 15 deg of pitch up.
      feed(
        engine,
        const FaceFrameResult(faceCount: 1, yawDegrees: 15, pitchDegrees: -15),
        10,
      );

      await pumpEventQueue();
      expect(seen, isNot(contains(GazeSignal.lookingAway)));
      expect(seen, contains(GazeSignal.centered));
    });

    test('one off-axis frame is a glance, not a strike', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Yaw 30 is past the 15 deg tolerance, and one frame of it is 150 ms: a
      // blink, a notification, or one bad Euler estimate. The two-second sustain
      // is what turns "the detector saw a turned head" into "the student is
      // looking somewhere else", and the student who glances at their keyboard is
      // no longer warned for it.
      const glance = FaceFrameResult(faceCount: 1, yawDegrees: 30);
      engine.handleResult(glance);

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
        reason: 'a single frame must not reach the 2s sustain',
      );

      // ... and held for the full two seconds it is exactly one strike.
      hold(engine, glance, duration: const Duration(seconds: 2));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );

      // The latch still applies: a held turn is one episode, not one per frame.
      feed(engine, glance, 20);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );
    });

    test('a near-sideways turn is confirmed by two frames, not two seconds',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Past 30 degrees of yaw the head is no longer pointing at the screen at all,
      // so waiting the full hold made the detector look asleep. Two consecutive
      // frames are enough - and two, not one: a single estimate can be 60 degrees
      // wrong, and a strike on a detector artefact is worse than one frame later.
      const turned = FaceFrameResult(faceCount: 1, yawDegrees: 60);
      engine.handleResult(turned);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
        reason: 'one frame is a guess, however far round it reads',
      );

      now = now.add(engine.inferenceInterval);
      engine.handleResult(turned);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );

      // Two frames of it - not a second and a half - and one strike, not one per
      // inference while the head stays there.
      feed(engine, turned, 20);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );

      // A frame back inside the tolerances ends it, and the next turn has to be
      // confirmed twice of its own.
      engine.handleResult(const FaceFrameResult(faceCount: 1));
      now = now.add(engine.inferenceInterval);
      engine.handleResult(turned);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
        reason: 'one frame of the new episode confirms nothing',
      );
      now = now.add(engine.inferenceInterval);
      engine.handleResult(turned);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(2),
      );
    });

    test('a deep nod has no fast path: only a sideways turn does', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // 60 degrees of *pitch* is unambiguous about the frame as well - and it is
      // still the hold, because looking down at the desk is how a student reads a
      // printed sheet. The fast path is a yaw rule on both platforms: a nod is a
      // reason to give pitch a longer hold, not to confirm it sooner.
      const nodded = FaceFrameResult(faceCount: 1, pitchDegrees: 60);
      feed(engine, nodded, 5);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
        reason: 'five frames of a nod is a second of reading, not a strike',
      );

      hold(engine, nodded, duration: lookAwaySustain);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
        reason: 'a nod that is actually held is still a look-away',
      );
    });

    test('a chin down and a chin up are one rule', () async {
      // Pitch is judged on the absolute angle, at the same 15 deg as the yaw: a
      // head held down at a phone in the lap and a head held up at a screen across
      // the room are the same evidence, and the two detectors do not even agree on
      // which one is positive. The asymmetric 25 / 18 pair this replaces made the
      // tolerance depend on the direction of the tilt as well as on the axis.
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      const down = FaceFrameResult(faceCount: 1, pitchDegrees: 25);
      const up = FaceFrameResult(faceCount: 1, pitchDegrees: -25);

      // One frame either way is neither: the sustain, not the sign, decides.
      engine.handleResult(down);
      engine.handleResult(up);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
      );

      // Held for two seconds, a chin down is a look-away...
      hold(engine, down, duration: const Duration(seconds: 2));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );

      // ...and so is a chin up, once a centred frame has re-armed the episode.
      engine.handleResult(const FaceFrameResult(faceCount: 1));
      await pumpEventQueue();
      engine.handleResult(up);
      hold(engine, up, duration: const Duration(seconds: 2));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(2),
      );
    });

    test('a single centred frame restarts the sustain from zero', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Halfway out, back, halfway out again: two glances of 1.5s are not one
      // look-away of 3s. This is the "across consecutive frames" half of the rule,
      // and the reason glancing at notes every few seconds cannot accumulate into a
      // strike. 25 degrees keeps the test on the sustained rule: past 30 the turn
      // would be near-sideways and confirmed in two frames by design.
      const turned = FaceFrameResult(faceCount: 1, yawDegrees: 25);
      engine.handleResult(turned);
      hold(engine, turned, duration: const Duration(milliseconds: 1500));
      engine.handleResult(const FaceFrameResult(faceCount: 1));

      await pumpEventQueue();
      expect(seen, isNot(contains(GazeSignal.lookingAway)));

      engine.handleResult(turned);
      hold(engine, turned, duration: const Duration(milliseconds: 1500));

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
        reason: 'the centred frame ended the episode, so the clock restarted',
      );
    });

    test('a held turn logs looking_away once, and a return re-arms it',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      const away = FaceFrameResult(faceCount: 1, yawDegrees: 45);
      engine.handleResult(away);
      now = now.add(const Duration(seconds: 30));
      feed(engine, away, 40); // still away: no repeat
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );

      // Back to centered, then away again: a new episode, which has to earn its own
      // evidence - one frame is a guess whether the hold or the near-sideways count
      // is the rule that will confirm it.
      feed(engine, const FaceFrameResult(faceCount: 1), 1);
      engine.handleResult(away);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
        reason: 'the new episode has one frame and no hold yet',
      );

      hold(engine, away, duration: const Duration(seconds: 2));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(2),
      );
    });

    test('two faces are reported immediately, without a frame count',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 2));
      await pumpEventQueue();

      expect(seen, <GazeSignal>[GazeSignal.multipleFaces]);
    });

    test('a sustained second person is one violation, not one per inference',
        () async {
      // The regression this pins: two faces had no latch, so the signal was
      // emitted on every inference - ~7 a second at `inferenceInterval` - and
      // `register_violation` disqualifies on the third strike. One second of a
      // guest leaning into shot closed the attempt.
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 2)); // t0, reported
      for (var i = 0; i < 40; i++) {
        now = now.add(engine.inferenceInterval); // 6s of two faces
        engine.handleResult(const FaceFrameResult(faceCount: 2));
      }

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.multipleFaces),
        hasLength(1),
      );
    });

    test('the guest leaving re-arms one fresh episode, a flicker does not',
        () async {
      // Trace, with a 30s cooldown: two faces at t0 is the only signal; a
      // flicker back to two faces at t25 is suppressed *and* restarts the
      // alone-window, so the student must then be alone for a full 30s after
      // it before a second episode can be reported. Nothing here is
      // time-based luck - each step is the state machine's documented rule.
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 2)); // t0 -> #1
      engine.handleResult(const FaceFrameResult(faceCount: 1)); // t0 alone

      now = now.add(const Duration(seconds: 25)); // t25
      engine.handleResult(const FaceFrameResult(faceCount: 1)); // 25s alone
      engine.handleResult(const FaceFrameResult(faceCount: 2)); // suppressed

      now = now.add(const Duration(seconds: 15)); // t40
      engine.handleResult(const FaceFrameResult(faceCount: 1)); // 15s alone
      engine.handleResult(const FaceFrameResult(faceCount: 2)); // suppressed

      now = now.add(const Duration(seconds: 35)); // t75
      engine.handleResult(const FaceFrameResult(faceCount: 1)); // 35s alone

      now = now.add(const Duration(seconds: 1)); // t76
      engine.handleResult(const FaceFrameResult(faceCount: 2)); // #2

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.multipleFaces),
        hasLength(2),
      );
    });

    test('resetSustained clears a half-counted episode', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Two of the three frames, then the camera is restarted: the count starts
      // over, so one more missing frame is not enough.
      feed(engine, const FaceFrameResult(faceCount: 0), 2);
      engine.resetSustained();
      feed(engine, const FaceFrameResult(faceCount: 0), 1);

      await pumpEventQueue();
      expect(seen, isEmpty);
    });

    test('resetSustained re-arms the multi-face latch', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 2)); // #1

      // A camera that drops and comes back with the guest still in frame is a
      // fresh episode: carrying the latch across the gap would hide them for
      // the whole cooldown, and the gap is exactly the moment they arrive.
      engine.resetSustained();
      engine.handleResult(const FaceFrameResult(faceCount: 2)); // #2

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.multipleFaces),
        hasLength(2),
      );
    });
  });

  group('repeated glances', () {
    // The rolling half of the look-away rule: a student who reads paper and
    // screen in turn never holds a turn for two seconds, and used to collect
    // nothing at all. The window is shared with the browser (`WebFacePresenceMonitor`
    // feeds the same `LookAwayBurstWindow`), so these tests and that file's
    // `repeated glances` group are the same scenario on two sensors.
    late DateTime now;

    setUp(() => now = DateTime(2026, 1, 1, 12));

    MediaPipeProctoringService clocked() {
      final engine = MediaPipeProctoringService(
        clock: () => now,
        startupGrace: Duration.zero,
      );
      addTearDown(engine.dispose);
      return engine;
    }

    const turned = FaceFrameResult(faceCount: 1, yawDegrees: 30);
    const facing = FaceFrameResult(faceCount: 1);

    /// Holds [result] for [duration] the way the camera does: one frame per
    /// [MediaPipeProctoringService.inferenceInterval], clock advancing with each.
    void hold(
      MediaPipeProctoringService engine,
      FaceFrameResult result,
      Duration duration,
    ) {
      final frames =
          (duration.inMilliseconds / engine.inferenceInterval.inMilliseconds)
              .ceil();
      for (var i = 0; i < frames; i++) {
        now = now.add(engine.inferenceInterval);
        engine.handleResult(result);
      }
    }

    /// One glance of [length], ended by a frame back inside the tolerances, and
    /// [gap] spent looking at the screen before the next one. Both lengths are
    /// multiples of the inference interval, so a glance is exactly as long as it
    /// says: 600 ms is a glance, 300 ms is a fragment.
    void glance(
      MediaPipeProctoringService engine,
      Duration length, {
      Duration gap = const Duration(seconds: 2),
    }) {
      hold(engine, turned, length);
      now = now.add(engine.inferenceInterval);
      engine.handleResult(facing);
      now = now.add(gap);
    }

    Iterable<GazeSignal> strikes(List<GazeSignal> seen) =>
        seen.where((signal) => signal == GazeSignal.lookingAway);

    test('three glances inside a minute are one look away', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      glance(engine, const Duration(milliseconds: 600));
      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(strikes(seen), isEmpty, reason: 'two glances are not a pattern');

      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(
        strikes(seen),
        hasLength(1),
        reason: 'the third glance of the minute is the violation',
      );
      expect(
        seen.last,
        GazeSignal.lookingAway,
        reason: 'the frame that closed the third glance carries it, rather '
            'than a later frame that shows a centred head',
      );
    });

    test('three glances over ninety seconds are not', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 3; i++) {
        glance(
          engine,
          const Duration(milliseconds: 600),
          gap: const Duration(seconds: 39),
        );
      }
      await pumpEventQueue();
      expect(
        strikes(seen),
        isEmpty,
        reason: 'a glance a minute and a half ago is not evidence for this one',
      );
    });

    test('five seconds off screen in total are one look away', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Fragments too short to count as a glance (300 ms against a 500 ms
      // minimum), repeated: the shape the episode count cannot see, and the
      // reason the total sits beside it. Two-second gaps, because the total is
      // judged inside the same minute as the count - fragments a dozen seconds
      // apart would age out before they added up to anything.
      for (var i = 0; i < 16; i++) {
        glance(
          engine,
          const Duration(milliseconds: 300),
          gap: const Duration(seconds: 2),
        );
      }
      await pumpEventQueue();
      expect(strikes(seen), isEmpty, reason: '4.8 s is not five');

      glance(
        engine,
        const Duration(milliseconds: 300),
        gap: const Duration(seconds: 2),
      );
      await pumpEventQueue();
      expect(strikes(seen), hasLength(1));
    });

    test('a strike empties the window, so the next burst is earned again',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      for (var i = 0; i < 3; i++) {
        glance(engine, const Duration(milliseconds: 600));
      }
      await pumpEventQueue();
      expect(strikes(seen), hasLength(1));

      glance(engine, const Duration(milliseconds: 600));
      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(
        strikes(seen),
        hasLength(1),
        reason: 'the strike consumed the glances it came from, so two are two',
      );

      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(strikes(seen), hasLength(2));
    });

    test('a held turn is one strike, and is not also banked as a glance',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      hold(engine, turned, const Duration(seconds: 3));
      await pumpEventQueue();
      expect(strikes(seen), hasLength(1));

      now = now.add(engine.inferenceInterval);
      engine.handleResult(facing);
      await pumpEventQueue();
      expect(
        strikes(seen),
        hasLength(1),
        reason: 'the run belonged to the sustained rule, so returning is not a '
            'second strike',
      );

      // ...and its seconds are not in the window either: two glances after it
      // are two glances, not three.
      glance(engine, const Duration(milliseconds: 600));
      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(strikes(seen), hasLength(1));
    });

    test('a face lost mid-glance ends the glance rather than pausing it',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      hold(engine, turned, const Duration(milliseconds: 1500));
      // No head to judge a pose from, so the run is over: the second and a half
      // before it must not become a banked glance.
      hold(
        engine,
        const FaceFrameResult(faceCount: 0),
        const Duration(milliseconds: 450),
      );
      now = now.add(engine.inferenceInterval);
      engine.handleResult(facing);

      glance(engine, const Duration(milliseconds: 600));
      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(
        strikes(seen),
        isEmpty,
        reason: 'the abandoned 1.5 s is no evidence, and two glances is not three',
      );
    });

    test('a counter reset drops the evidence as well as the episode', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      glance(engine, const Duration(milliseconds: 600));
      glance(engine, const Duration(milliseconds: 600));

      // A camera that was not delivering saw no glances, so the two it did see
      // must not be spent on the first ones after the gap.
      engine.resetSustained();
      glance(engine, const Duration(milliseconds: 600));
      glance(engine, const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(strikes(seen), isEmpty);
    });
  });

  group('the start-up window', () {
    // The five seconds both platforms now ignore (`cameraStartupGrace`). The engine
    // used to judge its very first frame, so a student still moving the camera into
    // place could be struck by their own set-up; the browser has ignored its first
    // five seconds since it was written. These tests spend the window on the engine
    // that keeps the default, which is why the group above switches it off.
    late DateTime now;

    setUp(() => now = DateTime(2026, 1, 1, 12));

    /// An engine with the shipped defaults on a clock the test owns.
    MediaPipeProctoringService starting() {
      final engine = MediaPipeProctoringService(clock: () => now);
      addTearDown(engine.dispose);
      return engine;
    }

    /// Keeps [result] arriving for [duration], one frame per
    /// [MediaPipeProctoringService.inferenceInterval], advancing the clock with each.
    void watch(
      MediaPipeProctoringService engine,
      FaceFrameResult result,
      Duration duration,
    ) {
      final frames =
          (duration.inMilliseconds / engine.inferenceInterval.inMilliseconds)
              .ceil();
      for (var i = 0; i < frames; i++) {
        now = now.add(engine.inferenceInterval);
        engine.handleResult(result);
      }
    }

    // 25 degrees, not 40: this group is about the *window*, and a near-sideways turn
    // would be confirmed two frames after it ends, which is a different (tested)
    // rule. Below 30 the head is judged by the hold, exactly as the group describes.
    const turned = FaceFrameResult(faceCount: 1, yawDegrees: 25);

    test('a head turned while the student sets up is not a strike', () async {
      final engine = starting();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Four and a half seconds of a turned head from the very first frame: the
      // student is aiming the lens at the chair they are about to sit in, not
      // reading anything. Nothing at all is reported, and the counters are cleared
      // on every one of those frames rather than banked.
      watch(engine, turned, const Duration(milliseconds: 4500));
      await pumpEventQueue();
      expect(seen, isEmpty);

      // Past the window the head has to earn the phone's own two seconds, so the
      // first judged frame is not a strike either...
      watch(engine, turned, const Duration(seconds: 1));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
        reason: 'the window ends a set-up, it does not pre-load the sustain',
      );

      // ...and a held turn still is, exactly once.
      watch(engine, turned, lookAwaySustain);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );
    });
    test('a camera that opens late does not spend the window while it is black',
        () async {
      final engine = starting();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Three seconds with no frames at all - the preview is still opening. The
      // window is anchored on the first frame the engine *judges*, not on
      // construction, so none of it is spent here.
      now = now.add(const Duration(seconds: 3));
      engine.handleResult(turned);
      await pumpEventQueue();
      expect(seen, isEmpty);

      // Four seconds of frames later, still inside the window.
      watch(engine, turned, const Duration(seconds: 4));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        isEmpty,
        reason: 'a slow preview must not eat the grace the student needs',
      );

      // Five seconds after the first frame the head is judged, and a held turn
      // lands.
      watch(engine, turned, const Duration(seconds: 5));
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );
    });
    test('an empty frame during set-up is not a no_face', () async {
      final engine = starting();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // A student leaning out of shot to pick up a chair, counted as ten missing
      // frames: the three-frame absence rule would have fired on the set-up.
      watch(
        engine,
        const FaceFrameResult(faceCount: 0),
        const Duration(seconds: 4),
      );
      await pumpEventQueue();
      expect(seen, isEmpty);

      // Once the window is spent, three frames without a face are still exactly
      // what they were: one strike on a camera that is covered or has been left.
      watch(
        engine,
        const FaceFrameResult(faceCount: 0),
        const Duration(seconds: 2),
      );
      await pumpEventQueue();
      expect(seen, <GazeSignal>[GazeSignal.noFace]);
    });

    test('a second person during set-up is not reported, and is afterwards',
        () async {
      final engine = starting();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // The person helping position the camera is not evidence about the student,
      // which is why the window covers `multiple_faces` too - the one signal that
      // otherwise needs no measuring.
      watch(
        engine,
        const FaceFrameResult(faceCount: 2),
        const Duration(seconds: 4),
      );
      await pumpEventQueue();
      expect(seen, isEmpty);

      // A guest who is still there when the window ends is reported at once, as
      // always: the grace delays the strike, it does not lose it.
      watch(
        engine,
        const FaceFrameResult(faceCount: 2),
        const Duration(seconds: 2),
      );
      await pumpEventQueue();
      expect(seen, <GazeSignal>[GazeSignal.multipleFaces]);
    });
    test('a counter reset does not hand out a second window', () async {
      final engine = starting();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // Spend the window with a student who is behaving.
      watch(
        engine,
        const FaceFrameResult(faceCount: 1),
        const Duration(seconds: 6),
      );
      await pumpEventQueue();

      // The stream flaps - which the page reports through `setStreamActive` - and
      // comes back. It is judged on the frames it produces next: a window that
      // could be re-opened this way would be five unwatched seconds on demand.
      engine.setStreamActive(false);
      engine.setStreamActive(true);

      watch(engine, turned, lookAwaySustain + engine.inferenceInterval);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
        reason: 'the sitting has one start-up window, not one per reset',
      );
    });

  });

  group('engine defaults', () {
    test('match the documented throttle / threshold / sustain contract', () {
      expect(engine.inferenceInterval, const Duration(milliseconds: 150));
      // A look-away is a head turned past 15 deg of yaw or 15 deg of pitch - the
      // same angle on both axes, in either direction - held for two seconds across
      // consecutive frames. See `proctoring_thresholds.dart`.
      expect(engine.offCenterThresholdDegrees, lookAwayYawDegrees);
      expect(engine.pitchThresholdDegrees, lookAwayPitchDegrees);
      expect(engine.lookAwaySustain, lookAwaySustain);
      // The near-sideways start, shared with the browser monitor: past 30 deg of yaw
      // two consecutive frames confirm the turn, so an obviously turned head no longer
      // waits out the hold - and one frame is still not enough, so a 60 deg estimate
      // from a bad frame is only a candidate.
      expect(engine.immediateYawDegrees, lookAwayImmediateYawDegrees);
      expect(engine.immediateFrameThreshold, lookAwayImmediateFrames);
      // The frame floor under the sustain - one frame is enough evidence for the
      // *frames* half of the rule, so the timing is what decides.
      expect(engine.consecutiveFrameThreshold, 1);
      // A missing *face* is still counted, and deliberately not one: a working
      // detector drops a single frame on its own. See `missingFaceFrameThreshold`.
      expect(engine.missingFaceFrameThreshold, 3);
      // A multi-face episode is latched rather than frame-counted, so this is
      // how long the student has to be *alone* before a second one counts.
      expect(engine.multipleFacesCooldown, const Duration(seconds: 30));
      // And the sitting starts with five seconds in which nothing is judged -
      // `cameraStartupGrace`, the same window the browser monitor has always had.
      expect(engine.startupGrace, cameraStartupGrace);
    });

    test('expose a broadcast signal stream and leak nothing on dispose', () {
      expect(engine.signals.isBroadcast, isTrue);
      engine.dispose();
      expect(engine.dispose, returnsNormally); // idempotent
    });
  });

  group('teardown', () {
    test('a face frame that lands after dispose is dropped, not channelled',
        () async {
      // `handleResult` is reached from the camera stream and from a `faceDetector`
      // future that was already on the wire when the page was popped, so a result can
      // arrive after `dispose()` closed `signals`. Adding to a closed controller throws
      // into that detached chain, where nothing is left to catch it.
      final engine = MediaPipeProctoringService();
      addTearDown(engine.dispose);

      engine.dispose();

      // A centred face is the shape that emits immediately (no frame count), so this is
      // the shortest path to the closed controller.
      expect(
        () => engine.handleResult(const FaceFrameResult(faceCount: 1)),
        returnsNormally,
      );
      await pumpEventQueue();

      expect(await engine.signals.toList(), isEmpty);
    });

    test('a half-counted episode is neither counted nor reported after dispose',
        () async {
      // The frame counters underneath are the disqualification path: a `no_face`
      // episode that keeps counting after teardown would be reported against a
      // session that has already ended.
      final engine = MediaPipeProctoringService();
      addTearDown(engine.dispose);

      engine.handleResult(const FaceFrameResult(faceCount: 0)); // 1 of 3
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // 2 of 3
      engine.dispose();
      for (var i = 0; i < 5; i++) {
        engine.handleResult(const FaceFrameResult(faceCount: 0));
      }

      await pumpEventQueue();
      expect(await engine.signals.toList(), isEmpty);
    });
  });
}
