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

  group('time grace period', () {
    late DateTime now;

    setUp(() => now = DateTime(2026, 1, 1, 12));

    /// An engine whose sustained windows advance with [now] instead of the wall
    /// clock, so a 3-second grace can be exercised instantly.
    MediaPipeProctoringService clocked() {
      final engine = MediaPipeProctoringService(clock: () => now);
      addTearDown(engine.dispose);
      return engine;
    }

    test('a single missing-face frame is not a violation', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 0));
      await pumpEventQueue();

      expect(seen, isEmpty);
    });

    test('a sustained missing face logs no_face exactly once', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 0)); // t0
      now = now.add(const Duration(seconds: 2));
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // still inside
      now = now.add(const Duration(seconds: 1)); // t0 + 3s
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // sustained
      now = now.add(const Duration(seconds: 30));
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // same episode

      await pumpEventQueue();
      expect(seen, <GazeSignal>[GazeSignal.noFace]);
    });

    test('the face returning re-arms a fresh absence episode', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 0));
      now = now.add(const Duration(seconds: 3));
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // no_face #1

      engine.handleResult(const FaceFrameResult(faceCount: 1)); // visible again
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // fresh episode
      now = now.add(const Duration(seconds: 3));
      engine.handleResult(const FaceFrameResult(faceCount: 0)); // no_face #2

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

      // 25 deg yaw and 29 deg pitch sit inside the relaxed tolerances.
      const inside =
          FaceFrameResult(faceCount: 1, yawDegrees: 25, pitchDegrees: 29);
      engine.handleResult(inside);
      now = now.add(const Duration(seconds: 10));
      engine.handleResult(inside);

      await pumpEventQueue();
      expect(seen, isNot(contains(GazeSignal.lookingAway)));
      expect(seen, contains(GazeSignal.centered));
    });

    test('a sustained off-axis turn logs looking_away exactly once', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      const away = FaceFrameResult(faceCount: 1, yawDegrees: 45);
      engine.handleResult(away);
      now = now.add(const Duration(seconds: 3));
      engine.handleResult(away);
      now = now.add(const Duration(seconds: 30));
      engine.handleResult(away); // still away: no repeat

      await pumpEventQueue();
      expect(
        seen.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
      );
    });

    test('two faces are reported immediately, without a grace window',
        () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 2));
      await pumpEventQueue();

      expect(seen, <GazeSignal>[GazeSignal.multipleFaces]);
    });

    test('resetSustained clears a half-elapsed window', () async {
      final engine = clocked();
      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);
      addTearDown(sub.cancel);

      engine.handleResult(const FaceFrameResult(faceCount: 0));
      now = now.add(const Duration(seconds: 2));
      engine.resetSustained();
      now = now.add(const Duration(seconds: 1));
      engine.handleResult(const FaceFrameResult(faceCount: 0));

      await pumpEventQueue();
      expect(seen, isEmpty);
    });
  });

  group('engine defaults', () {
    test('match the documented throttle / threshold / grace contract', () {
      expect(engine.inferenceInterval, const Duration(milliseconds: 150));
      // Relaxed tolerances: a turn under ~28 deg, and looking down under ~30 deg
      // to read/type, must not flag the student.
      expect(engine.offCenterThresholdDegrees, 28.0);
      expect(engine.pitchThresholdDegrees, 30.0);
      expect(engine.lookAwayGraceDuration, const Duration(seconds: 3));
      expect(engine.noFaceGraceDuration, const Duration(seconds: 3));
    });

    test('expose a broadcast signal stream and leak nothing on dispose', () {
      expect(engine.signals.isBroadcast, isTrue);
      engine.dispose();
      expect(engine.dispose, returnsNormally); // idempotent
    });
  });
}
