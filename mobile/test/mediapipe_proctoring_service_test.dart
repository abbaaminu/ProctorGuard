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

  group('engine defaults', () {
    test('match the documented throttle / threshold / grace contract', () {
      expect(engine.inferenceInterval, const Duration(milliseconds: 150));
      expect(engine.offCenterThresholdDegrees, 20.0);
      expect(engine.lookAwayGraceDuration, const Duration(seconds: 3));
    });

    test('expose a broadcast signal stream and leak nothing on dispose', () {
      expect(engine.signals.isBroadcast, isTrue);
      engine.dispose();
      expect(engine.dispose, returnsNormally); // idempotent
    });
  });
}
