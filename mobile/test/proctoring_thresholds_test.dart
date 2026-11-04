import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart';
import 'package:proctorguard/core/services/proctoring_thresholds.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the look-away rule, and the relationship between its two halves.
///
/// The numbers live in `proctoring_thresholds.dart` so that the rule can be
/// stated in one sentence and changed in one place; these tests are what stops a
/// future edit from quietly turning a glance into a strike again (or a real
/// look-away into silence). They also check that the engine's defaults really are
/// those constants - a copy of the number in the constructor would pass the
/// behaviour tests below while drifting from the file a reviewer reads.
void main() {
  group('look-away rule', () {
    test('a head must be turned past 25 degrees to count at all', () {
      expect(lookAwayYawDegrees, 25.0);
      // The audit's first version used 15, which flags a glance at the student's
      // own keyboard. Anything at or below 20 is a regression, and anything above
      // 45 stops catching a second screen beside the laptop.
      expect(lookAwayYawDegrees, greaterThan(20.0));
      expect(lookAwayYawDegrees, lessThanOrEqualTo(45.0));
    });

    test('a look-away must be held for two seconds', () {
      expect(lookAwaySustain, const Duration(seconds: 2));
      // One frame at the detector's rate is ~150 ms. A sustain that short is a
      // blink, and a sustain longer than a few seconds lets a cheater read a whole
      // paragraph off another screen between strikes.
      expect(lookAwaySustain, greaterThan(const Duration(milliseconds: 500)));
      expect(lookAwaySustain, lessThanOrEqualTo(const Duration(seconds: 5)));
    });

    test('the pitch tolerance catches a head down at a lap, not a chin drop', () {
      expect(lookAwayPitchDegrees, 18.0);
      // Reading and typing both lower the chin a few degrees; a phone in the lap
      // or notes on the desk is 25-40.
      expect(lookAwayPitchDegrees, greaterThan(10.0));
      expect(lookAwayPitchDegrees, lessThan(25.0));
    });

    test('the engine takes the constants as its defaults', () {
      final engine = MediaPipeProctoringService();
      addTearDown(engine.dispose);

      expect(engine.offCenterThresholdDegrees, lookAwayYawDegrees);
      expect(engine.pitchThresholdDegrees, lookAwayPitchDegrees);
      expect(engine.lookAwaySustain, lookAwaySustain);
      // A negative sustain would report a look-away the detector has not seen for
      // any time at all, so it is refused at construction.
      expect(
        () => MediaPipeProctoringService(
          lookAwaySustain: const Duration(seconds: -1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
