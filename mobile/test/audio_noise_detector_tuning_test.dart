import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/audio_noise_detector.dart';

/// Pins the two tuning knobs that decide whether a *sentence* is heard as one
/// sound: `hysteresisDb` (how far under the line a quiet syllable may sit) and
/// `maxCalibrationSamples` (how much of the room the median keeps).
///
/// `audio_monitoring_test.dart` pins the room measurement and the strike ladder.
/// These pin the rules in between, and each test is written as the mistake the
/// knob exists to prevent:
///
///  * without the band, one soft syllable in the middle of a sentence restarts
///    the sustain window, so a student can talk in short bursts and never be
///    warned - or, with the band too wide, a room that actually went quiet keeps
///    an episode alive;
///  * without the cap, calibration's working set is whatever rate the caller
///    samples at - a growth path in the one place that measures the room.
void main() {
  late DateTime now;
  setUp(() => now = DateTime.utc(2026, 1, 1, 9));

  /// A detector that has already measured the room.
  ///
  /// One `-60` dBFS sample with a zero-length window gives the bottom of the
  /// clamp, a `-50` dB threshold (floor + 6 is `-54`, clamped up), so `-45` is
  /// over the line, `-51` is a quiet syllable inside the default 3 dB band, and
  /// `-60` is a real dip.
  ///
  /// The window is pinned wide (2 s) on purpose: these tests step a full second
  /// at a time and are about the *band*, so the measured value is the band's
  /// effect on the window rather than the window itself firing early and hiding
  /// it.
  ///
  /// [releaseGrace] defaults to the shipped zero - a dip resets the timer - and is
  /// only raised by the one test that proves the knob still bridges a word gap when
  /// a host asks it to.
  AudioNoiseDetector measured({
    double hysteresisDb = 3,
    Duration releaseGrace = Duration.zero,
  }) {
    final detector = AudioNoiseDetector(
      calibrationWindow: Duration.zero,
      sustain: const Duration(seconds: 2),
      releaseGrace: releaseGrace,
      hysteresisDb: hysteresisDb,
      minCalibrationSamples: 1,
      clock: () => now,
    );
    detector.add(-60);
    expect(detector.isCalibrated, isTrue);
    expect(detector.thresholdDb, -50);
    return detector;
  }

  group('hysteresisDb', () {
    test('a quiet syllable does not throw away the sentence', () {
      final sensor = measured();

      expect(sensor.add(-45), isFalse); // 5 dB over: the window opens
      expect(sensor.isNoisy, isTrue);

      now = now.add(const Duration(seconds: 1));
      // 1 dB under the line: a syllable, not a break in the sound. The window
      // keeps whatever it had instead of restarting from zero.
      expect(sensor.add(-51), isFalse);
      expect(
        sensor.isNoisy,
        isTrue,
        reason: 'the indicator must not flicker on a quiet syllable',
      );

      now = now.add(const Duration(seconds: 1));
      expect(
        sensor.add(-45),
        isTrue,
        reason: 'two seconds of speech, one of them soft, is still speech',
      );
    });

    test('a band that is too wide cannot make quiet sound a strike', () {
      final sensor = measured();

      // Nothing ever crossed the line, so nothing accrues - the band keeps an
      // episode alive, it never starts one.
      expect(sensor.add(-51), isFalse);
      expect(sensor.isNoisy, isFalse);

      now = now.add(const Duration(seconds: 10));
      expect(sensor.add(-51), isFalse);
      expect(sensor.isNoisy, isFalse);
    });

    test('a dip beyond the band still ends the episode', () {
      final sensor = measured();

      sensor.add(-45); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-60); // 10 dB under: past the band, so the release clock starts
      expect(
        sensor.isNoisy,
        isFalse,
        reason: 'a genuine dip is not "something is building"',
      );

      now = now.add(const Duration(seconds: 1));
      expect(
        sensor.add(-45),
        isFalse,
        reason: 'the dip outlasted releaseGrace, so the window restarted here',
      );

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isFalse); // 1 s into the new window
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isTrue); // 2 s: the new episode, warned once
    });

    test('zero restores the strict rule, syllable or not', () {
      final sensor = measured(hysteresisDb: 0);

      sensor.add(-45); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-51); // strictly under the line: the window is over

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isFalse); // restarted from here
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isTrue);
    });

    test('a short dropout is bridged - when a host asks for the grace', () {
      // The bridging rule is still available (`releaseGrace`), and this is what it
      // buys: a 100 ms word gap does not restart the window. The *shipped* value is
      // zero, so an app that never passes one gets the strict rule - see
      // `proctoring_thresholds_test.dart` and the "shipped sensitivity" group below.
      final sensor = measured(releaseGrace: const Duration(milliseconds: 400));

      sensor.add(-45); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-60); // a word gap: under the band, under releaseGrace
      now = now.add(const Duration(milliseconds: 100));
      expect(sensor.add(-45), isFalse); // bridged: still the same window

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isTrue); // 2.1 s of it: one strike, not two
    });

    test('the shipped zero grace restarts the window on that same 100 ms gap', () {
      // The other half of the trade, asserted rather than assumed: with the defaults
      // an app actually ships, the same 100 ms dip costs the whole window. This is
      // the price of "a dip below resets the timer", and it is the reason a noisy
      // room can end an honest student's sitting - for a human to review, never an
      // automatic disqualification.
      final sensor = measured();

      sensor.add(-45); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-60); // the 100 ms gap
      now = now.add(const Duration(milliseconds: 100));
      expect(sensor.add(-45), isFalse);
      expect(sensor.isNoisy, isTrue, reason: 'a fresh window opens here');

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isFalse, reason: 'only 1.1 s into the new window');
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-45), isTrue);
    });
  });


  group('maxCalibrationSamples', () {
    /// Ten readings a quarter-second apart are more than this cap allows, which
    /// is the shape of a caller that samples faster than `AudioMonitor` does.
    AudioNoiseDetector fastSource() => AudioNoiseDetector(
          calibrationWindow: const Duration(seconds: 10),
          minCalibrationSamples: 1,
          maxCalibrationSamples: 4,
          clock: () => now,
        );

    test('the median holds at most the cap, however fast the source is', () {
      final sensor = fastSource();
      for (var i = 0; i < 10; i++) {
        sensor.add(-70.0 - i);
        expect(
          sensor.calibrationSampleCount,
          lessThanOrEqualTo(4),
          reason: 'a fast source must not grow the calibration buffer',
        );
        now = now.add(const Duration(milliseconds: 250));
      }

      expect(sensor.samples, 10);
      expect(sensor.calibrationSampleCount, 4);
      expect(
        sensor.isCalibrated,
        isFalse,
        reason: '2.25 s of a 10 s window: still measuring',
      );
    });

    test('the oldest readings are the ones dropped', () {
      final sensor = fastSource();
      for (var i = 0; i < 10; i++) {
        sensor.add(-70.0 - i);
        now = now.add(const Duration(milliseconds: 250));
      }

      // Past the window, so this sample completes calibration. The four
      // readings kept before it were -76..-79, and the median of those plus
      // -70 is -77.5: the early, louder readings are gone, which is what makes
      // the measurement describe the room the student is in now.
      now = now.add(const Duration(seconds: 8));
      sensor.add(-70);

      expect(sensor.isCalibrated, isTrue);
      expect(sensor.roomFloorDb, -77.5);
      expect(sensor.thresholdDb, -50); // -71.5, clamped up to the floor
      expect(
        sensor.calibrationSampleCount,
        0,
        reason: 'the readings have no further use once the room is known',
      );
    });

    test('a cap under the minimum still finishes calibrating', () {
      final sensor = AudioNoiseDetector(
        calibrationWindow: const Duration(seconds: 2),
        minCalibrationSamples: 5, // more than the cap below
        maxCalibrationSamples: 2,
        clock: () => now,
      );

      for (var i = 0; i < 8; i++) {
        sensor.add(-58);
        now = now.add(const Duration(milliseconds: 250));
      }
      now = now.add(const Duration(seconds: 1));

      sensor.add(-58);
      expect(
        sensor.isCalibrated,
        isTrue,
        reason: 'the requirement is clamped to the cap, not past it',
      );
      expect(sensor.roomFloorDb, -58);
    });

    test('reset drops the readings with the room they described', () {
      final sensor = fastSource();
      for (var i = 0; i < 6; i++) {
        sensor.add(-70);
        now = now.add(const Duration(milliseconds: 250));
      }
      expect(sensor.calibrationSampleCount, 4);

      sensor.reset();

      expect(sensor.calibrationSampleCount, 0);
      expect(sensor.isCalibrated, isFalse);
      expect(sensor.thresholdDb, -30); // the uncalibrated default again
      expect(sensor.samples, 0);
    });
  });

  group('shipped sensitivity', () {
    /// A detector on the shipped tuning, already past calibration. `-60` measures
    /// the room, so the threshold is -50 dB and `-40` is comfortably over it.
    AudioNoiseDetector calibrated() {
      final detector = AudioNoiseDetector(
        calibrationWindow: Duration.zero,
        minCalibrationSamples: 1,
        clock: () => now,
      );
      detector.add(-60);
      expect(detector.isCalibrated, isTrue);
      return detector;
    }

    /// Feeds [duration] of continuous meter noise at `AudioMonitor`'s real rate -
    /// one sample every 250 ms - and returns how many strikes it produced.
    int sustainedNoise(AudioNoiseDetector detector, Duration duration) {
      var strikes = 0;
      final samples = duration.inMilliseconds ~/ 250;
      for (var i = 0; i < samples; i++) {
        now = now.add(const Duration(milliseconds: 250));
        if (detector.add(-40)) strikes++;
      }
      return strikes;
    }

    test('two and a quarter seconds of meter noise is one strike, not two', () {
      // The window is 2 s and the meter reports every 250 ms, so the shortest burst
      // that can fill it is nine samples: one opens the window and the ninth lands
      // exactly 2 s later. Eight samples (2 s of noise) is one sample short, which
      // the sampling-offset test below pins as "not yet".
      final sensor = calibrated();
      expect(sensor.sustain, const Duration(seconds: 2));

      expect(
        sustainedNoise(sensor, const Duration(milliseconds: 2250)),
        1,
        reason: 'the latch and the cooldown have to keep one burst to one strike '
            'even though the window closes long before the noise does',
      );

      // ...and a burst that keeps going for a minute is still one strike.
      expect(
        sustainedNoise(sensor, const Duration(seconds: 60)),
        0,
        reason: 'one episode, one strike: nothing more is reported until the level '
            'drops back below the threshold',
      );
    });

    test('anything shorter than two seconds never reports', () {
      // The requirement, at the real sampling rate: a cough, a keystroke, a chair,
      // a door and a short "hey you" all come and go inside the window, and none of
      // them is an `audio_noise`.
      for (final duration in <Duration>[
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1000),
        const Duration(milliseconds: 1750),
      ]) {
        final sensor = calibrated();
        expect(
          sustainedNoise(sensor, duration),
          0,
          reason: '${duration.inMilliseconds} ms is under the 2 s window',
        );
        expect(
          sensor.isNoisy,
          isTrue,
          reason: 'still amber on the chip - suspicious, not a violation',
        );
      }
    });

    test('a dip below the threshold restarts the two-second timer', () {
      // Eight loud samples, then the room drops for one sample, then eight more:
      // twenty-four hundredths of a second of evidence that a totalising rule would
      // count as two seconds and a half. The window starts over instead, so the
      // strike lands only once the level has held for 2 s *without* leaving the line.
      final sensor = calibrated();

      for (var i = 0; i < 8; i++) {
        now = now.add(const Duration(milliseconds: 250));
        expect(sensor.add(-40), isFalse, reason: 'sample ${i + 1}: 1.75 s, no strike');
      }

      now = now.add(const Duration(milliseconds: 250));
      expect(sensor.add(-70), isFalse); // the dip
      expect(sensor.isNoisy, isFalse);

      for (var i = 0; i < 8; i++) {
        now = now.add(const Duration(milliseconds: 250));
        expect(
          sensor.add(-40),
          isFalse,
          reason: 'sample ${i + 1} of the new window: the first 1.75 s is not 2 s',
        );
      }
      now = now.add(const Duration(milliseconds: 250));
      expect(sensor.add(-40), isTrue); // 2 s unbroken: one strike
    });

    test('a cough, a keystroke or a chair is still not enough', () {
      final sensor = calibrated();

      // Loud, but over before the window can fill. A browser reports the peak of a
      // short analyser window, so a keyboard, a mouse click, a chair or a single
      // cough all clear the line for a sample or two - three samples of noise are
      // still three samples, and the window needs nine.
      expect(sustainedNoise(sensor, const Duration(milliseconds: 750)), 0);
      expect(sensor.isNoisy, isTrue, reason: 'suspicious, not a violation');
    });

    test('the sampling offset cannot swallow the shortest real episode', () {
      // A burst that starts just after a sample only contributes its remainder to
      // the window: 2250 ms of noise yields the 2000 ms of evidence the window needs,
      // because the meter is read every 250 ms. That is the shortest burst the rule
      // can hear, and it is the honest lower bound - the rule really is "two seconds
      // of continuous level", measured at the meter's resolution.
      final sensor = calibrated();
      expect(sensor.sustain, const Duration(seconds: 2));
      expect(sustainedNoise(sensor, const Duration(milliseconds: 2250)), 1);

      // One sample less and nothing accrues.
      final tooShort = calibrated();
      expect(sustainedNoise(tooShort, const Duration(seconds: 2)), 0);
    });

    test('one continuous episode is one strike, however long it lasts', () {
      // The latch rule, on the shipped tuning: the same 30 s of noise is one
      // `audio_noise` even though the 10 s cooldown expires twice inside it. A room
      // that stays loud cannot climb the weighted ladder on its own - which matters
      // now that a noise strike counts towards the threshold.
      final sensor = calibrated();
      expect(sustainedNoise(sensor, const Duration(seconds: 30)), 1);

      // The level drops back below the threshold, then the room is loud again: a
      // second episode, and a second strike.
      now = now.add(const Duration(milliseconds: 250));
      expect(sensor.add(-70), isFalse);
      expect(
        sustainedNoise(sensor, const Duration(seconds: 12)),
        1,
        reason: 'a genuinely new episode after the room went quiet',
      );
    });
  });
}

