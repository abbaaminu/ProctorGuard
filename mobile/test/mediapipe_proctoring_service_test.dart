import 'package:exam_proctor/core/services/mediapipe_proctoring_service.dart';
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

  group('consecutive-frame threshold', () {
    late DateTime now;

    setUp(() => now = DateTime(2026, 1, 1, 12));

    /// An engine on a clock the test owns. The counted conditions below never
    /// read it — they count *frames*, which is the whole point — while the
    /// multi-face cooldown does, so a 30-second cooldown can be exercised
    /// instantly.
    MediaPipeProctoringService clocked() {
      final engine = MediaPipeProctoringService(clock: () => now);
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

    test('a minor head turn or a look down stays centered', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      // 25 deg yaw and 29 deg pitch sit inside the relaxed tolerances, for as
      // many frames as the student keeps reading and typing.
      const inside =
          FaceFrameResult(faceCount: 1, yawDegrees: 25, pitchDegrees: 29);
      feed(engine, inside, 20);

      await pumpEventQueue();
      expect(seen, isNot(contains(GazeSignal.lookingAway)));
      expect(seen, contains(GazeSignal.centered));
    });

    test('two off-axis frames are not a violation, the third is', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      const away = FaceFrameResult(faceCount: 1, yawDegrees: 45);
      feed(engine, away, 2);

      await pumpEventQueue();
      expect(seen, isEmpty, reason: 'a quick glance is not a violation');

      feed(engine, away, 1);
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );
    });

    test('three consecutive off-axis frames log looking_away exactly once',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      const away = FaceFrameResult(faceCount: 1, yawDegrees: 45);
      feed(engine, away, 3);
      now = now.add(const Duration(seconds: 30));
      feed(engine, away, 40); // still away: no repeat
      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );

      // Back to centered, then three more frames away: a new episode.
      feed(engine, const FaceFrameResult(faceCount: 1), 1);
      feed(engine, away, 3);
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

  group('engine defaults', () {
    test('match the documented throttle / threshold / frame contract', () {
      expect(engine.inferenceInterval, const Duration(milliseconds: 150));
      // Relaxed tolerances: a turn under ~28 deg, and looking down under ~30 deg
      // to read/type, must not flag the student.
      expect(engine.offCenterThresholdDegrees, 28.0);
      expect(engine.pitchThresholdDegrees, 30.0);
      // Strict *frames*, not seconds: three in a row of a missing face, or of a
      // head past the tolerances. See `consecutiveFrameThreshold`.
      expect(engine.consecutiveFrameThreshold, 3);
      // A multi-face episode is latched rather than frame-counted, so this is
      // how long the student has to be *alone* before a second one counts.
      expect(engine.multipleFacesCooldown, const Duration(seconds: 30));
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
