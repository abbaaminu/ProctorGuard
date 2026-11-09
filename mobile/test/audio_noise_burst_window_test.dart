import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/audio_noise_detector.dart';

/// Pins rule 5: **repeated short noise is a finding, even though no single run of
/// it lasts two seconds.**
///
/// The mistake this rule exists to prevent is the one the two-second rule creates
/// on its own. A student reading the paper out in phrases - a sentence, a pause, a
/// sentence - never holds the level up for `audioNoiseSustain`, because every pause
/// resets the window. Live testing found exactly that: the detector heard a
/// monologue and reported nothing. The window answers the same question a second
/// way, and each test here is written as the failure it guards against:
///
///  * three phrases inside a minute are reported (the gap the two-second rule
///    leaves);
///  * two are not (a single word and its echo must not cost a strike);
///  * three phrases spread over ninety seconds are not (the window slides, it does
///    not remember the whole sitting);
///  * four seconds of fragments too short to be phrases are reported (the shape the
///    burst *count* cannot see);
///  * a report empties the window, so the next two phrases do not immediately pay
///    for the same conversation twice;
///  * a burst still cannot land during the cooldown after another strike;
///  * `reset()` empties the window with the rest of the evidence;
///  * the two-second rule itself is untouched (continuous noise is still one strike,
///    once).
///
/// The room is calibrated in every test with a single `-60` dBFS sample and a
/// zero-length window, which puts the threshold at `-50` (floor, plus the 6 dB
/// margin, clamped up): `-45` is over the line and `-60` is a real dip.
void main() {
  late DateTime now;
  setUp(() => now = DateTime.utc(2026, 3, 1, 9));

  AudioNoiseDetector measured({
    Duration cooldown = const Duration(seconds: 10),
  }) {
    final detector = AudioNoiseDetector(
      calibrationWindow: Duration.zero,
      // The shipped sustain: rule 5 is what these tests are about, and it has to
      // work *because* the sustain is two seconds and phrases are shorter.
      sustain: const Duration(seconds: 2),
      releaseGrace: Duration.zero,
      hysteresisDb: 0,
      cooldown: cooldown,
      minCalibrationSamples: 1,
      clock: () => now,
    );
    detector.add(-60); // measure the room: threshold -50
    expect(detector.isCalibrated, isTrue);
    expect(detector.thresholdDb, -50);
    return detector;
  }

  /// One phrase: a pause, then [length] of sound over the line, then a pause that
  /// ends it.
  ///
  /// Returns true when *any* of its samples was the one that reported. Which sample
  /// that is depends on the rule: a phrase that completes the burst count reports on
  /// the pause that ends it (the count is only known once the run has stopped), while
  /// a phrase whose own running length crosses the cumulative total reports on the
  /// sample that crosses it, a quarter of a second earlier. Both are the same finding
  /// arriving as soon as it is true, so the tests ask "did this phrase report", not
  /// "which sample did".
  ///
  /// The leading sample is a pause rather than sound for two reasons: it is what a
  /// phrase is (it follows a pause), and it releases the one-episode latch if the
  /// previous phrase was the one reported.
  bool phrase(
    AudioNoiseDetector detector, {
    Duration length = const Duration(milliseconds: 400),
  }) {
    detector.add(-60); // the pause before it, which also releases the latch
    var reported = detector.add(-45); // the run opens here: the clock starts
    now = now.add(length);
    reported =
        detector.add(-45) || reported; // still over, short of the 2 s sustain
    return detector.add(-60) || reported; // the pause that ends it
  }

  /// The gap between two phrases, so the next one is a separate burst.
  void pause([Duration length = const Duration(seconds: 1)]) {
    now = now.add(length);
  }

  group('audioNoiseBurstCount - three phrases in a window', () {
    test('three phrases separated by pauses are one audio_noise', () {
      final detector = measured();

      expect(phrase(detector), isFalse);
      expect(detector.burstCountInWindow, 1);
      pause();

      expect(phrase(detector), isFalse);
      expect(detector.burstCountInWindow, 2);
      pause();

      expect(
        phrase(detector),
        isTrue,
        reason: 'the third phrase is what makes it a conversation',
      );
      expect(
        detector.burstCountInWindow,
        0,
        reason: 'a report empties the window it was judged on',
      );
    });

    test('two phrases are not enough', () {
      final detector = measured();

      expect(phrase(detector), isFalse);
      pause();
      expect(phrase(detector), isFalse);
      pause();
      // The pause after the last phrase must not report anything either: nothing is
      // logged for having heard two phrases.
      expect(detector.add(-60), isFalse);
      expect(detector.burstCountInWindow, 2);
    });

    test('three phrases spread over ninety seconds are not repeated', () {
      final detector = measured();

      expect(phrase(detector), isFalse);
      pause(const Duration(seconds: 45));
      expect(phrase(detector), isFalse);
      pause(const Duration(seconds: 45));

      // 90 s after the first phrase ended, 45 s after the second: the first has
      // aged out of the sixty-second window and is no longer evidence for this one.
      expect(
        phrase(detector),
        isFalse,
        reason: 'one phrase every minute and a half is not a conversation',
      );
      expect(detector.burstCountInWindow, 2);
    });

    test('a click shorter than a burst is not a phrase', () {
      final detector = measured();

      for (var i = 0; i < 3; i++) {
        expect(
          phrase(detector, length: const Duration(milliseconds: 200)),
          isFalse,
          reason: 'a keystroke repeated three times is still a keystroke',
        );
        expect(detector.burstCountInWindow, 0);
        pause();
      }
    });
  });

  group('audioNoiseBurstTotal - fragments that add up', () {
    test('four seconds of fragments inside the window is one audio_noise', () {
      final detector = measured();

      // 200 ms fragments, each too short to be a burst, one second apart: 19 of
      // them are 3.8 s of a sixty-second window, and the twentieth crosses 4 s.
      for (var i = 0; i < 19; i++) {
        expect(
          phrase(detector, length: const Duration(milliseconds: 200)),
          isFalse,
          reason: '3.8 s of talking is not yet the total',
        );
        expect(detector.burstCountInWindow, 0);
        pause();
      }
      expect(detector.noiseTimeInWindow, lessThan(const Duration(seconds: 4)));

      expect(
        phrase(detector, length: const Duration(milliseconds: 200)),
        isTrue,
      );
      expect(
        detector.noiseTimeInWindow,
        Duration.zero,
        reason: 'the report emptied the window, open run included',
      );
    });

    test('the same fragments spread over more than a minute are not', () {
      final detector = measured();

      // Eight fragments of 200 ms, each one 9 s after the last: the early ones have
      // aged out of the sixty-second window long before the total would fill.
      for (var i = 0; i < 8; i++) {
        expect(
          phrase(detector, length: const Duration(milliseconds: 200)),
          isFalse,
        );
        pause(const Duration(seconds: 9));
      }
      expect(detector.noiseTimeInWindow, lessThan(const Duration(seconds: 4)));
    });
  });

  group('the window and the other rules', () {
    test('a report empties the window, so two more phrases do not land', () {
      // No cooldown at all: the only thing that can stop the next phrases from
      // reporting is the window having been emptied by the first report.
      final detector = measured(cooldown: Duration.zero);

      expect(phrase(detector), isFalse);
      pause();
      expect(phrase(detector), isFalse);
      pause();
      expect(phrase(detector), isTrue);

      pause();
      expect(phrase(detector), isFalse);
      expect(detector.burstCountInWindow, 1);
      pause();
      expect(
        phrase(detector),
        isFalse,
        reason: 'five phrases would be two strikes if the window never emptied',
      );
      pause();
      expect(detector.burstCountInWindow, 2);
      pause();

      // The sixth phrase is the third of the *new* window, so it reports again.
      expect(phrase(detector), isTrue);
    });

    test('the cooldown after a strike swallows the phrases inside it', () {
      final detector = measured(); // ten-second cooldown

      // A continuous two seconds: one strike, by the rule this one sits beside.
      detector.add(-45);
      now = now.add(const Duration(seconds: 1));
      expect(detector.add(-45), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(detector.add(-45), isTrue);
      expect(detector.isCoolingDown, isTrue);

      // Three phrases inside the dead zone: the level is ignored entirely, so
      // nothing is counted and nothing is reported.
      for (var i = 0; i < 3; i++) {
        expect(phrase(detector), isFalse);
        pause();
      }
      expect(
        detector.burstCountInWindow,
        0,
        reason: 'the cooldown is a dead zone for rule 5 as well',
      );

      // Once the cooldown is over the window starts again from empty.
      pause(const Duration(seconds: 10));
      expect(phrase(detector), isFalse);
      expect(detector.burstCountInWindow, 1);
    });

    test('reset() empties the window with the rest of the evidence', () {
      final detector = measured();

      expect(phrase(detector), isFalse);
      pause();
      expect(phrase(detector), isFalse);
      expect(detector.burstCountInWindow, 2);

      detector.reset();
      expect(detector.isCalibrated, isFalse);
      detector.add(-60); // re-measure the room: threshold -50 again
      expect(detector.thresholdDb, -50);

      pause();
      expect(
        phrase(detector),
        isFalse,
        reason: 'the phrases before the interruption are not in this room',
      );
      expect(detector.burstCountInWindow, 1);
    });

    test('the two-second rule is unchanged: continuous noise is one strike', () {
      final detector = measured();

      // Twenty samples a quarter-second apart: the shipped 250 ms sampling rate,
      // five seconds of unbroken noise.
      expect(detector.add(-45), isFalse);
      var strikes = 0;
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(milliseconds: 250));
        if (detector.add(-45)) strikes++;
      }

      expect(
        strikes,
        1,
        reason: 'the latch and the cooldown hold: one episode, one strike',
      );
      expect(
        detector.burstCountInWindow,
        0,
        reason: 'the report emptied the window and the run never ended',
      );
    });
  });
}
