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
  /// clamp, a `-55` dB threshold (floor + 4 is `-56`, clamped up), so `-50` is
  /// over the line, `-56` is a quiet syllable inside the default 3 dB band, and
  /// `-65` is a real dip.
  ///
  /// The window is pinned wide (2 s) on purpose: these tests step a full second
  /// at a time and are about the *band*, so the measured value is the band's
  /// effect on the window rather than the shipped 500 ms window firing early and
  /// hiding it.
  AudioNoiseDetector measured({double hysteresisDb = 3}) {
    final detector = AudioNoiseDetector(
      calibrationWindow: Duration.zero,
      sustain: const Duration(seconds: 2),
      hysteresisDb: hysteresisDb,
      minCalibrationSamples: 1,
      clock: () => now,
    );
    detector.add(-60);
    expect(detector.isCalibrated, isTrue);
    expect(detector.thresholdDb, -55);
    return detector;
  }

  group('hysteresisDb', () {
    test('a quiet syllable does not throw away the sentence', () {
      final sensor = measured();

      expect(sensor.add(-50), isFalse); // 5 dB over: the window opens
      expect(sensor.isNoisy, isTrue);

      now = now.add(const Duration(seconds: 1));
      // 1 dB under the line: a syllable, not a break in the sound. The window
      // keeps whatever it had instead of restarting from zero.
      expect(sensor.add(-56), isFalse);
      expect(
        sensor.isNoisy,
        isTrue,
        reason: 'the indicator must not flicker on a quiet syllable',
      );

      now = now.add(const Duration(seconds: 1));
      expect(
        sensor.add(-50),
        isTrue,
        reason: 'two seconds of speech, one of them soft, is still speech',
      );
    });

    test('a band that is too wide cannot make quiet sound a strike', () {
      final sensor = measured();

      // Nothing ever crossed the line, so nothing accrues - the band keeps an
      // episode alive, it never starts one.
      expect(sensor.add(-56), isFalse);
      expect(sensor.isNoisy, isFalse);

      now = now.add(const Duration(seconds: 10));
      expect(sensor.add(-56), isFalse);
      expect(sensor.isNoisy, isFalse);
    });

    test('a dip beyond the band still ends the episode', () {
      final sensor = measured();

      sensor.add(-50); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-65); // 11 dB under: past the band, so the release clock starts
      expect(
        sensor.isNoisy,
        isFalse,
        reason: 'a genuine dip is not "something is building"',
      );

      now = now.add(const Duration(seconds: 1));
      expect(
        sensor.add(-50),
        isFalse,
        reason: 'the dip outlasted releaseGrace, so the window restarted here',
      );

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-50), isFalse); // 1 s into the new window
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-50), isTrue); // 2 s: the new episode, warned once
    });

    test('zero restores the strict rule, syllable or not', () {
      final sensor = measured(hysteresisDb: 0);

      sensor.add(-50); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-56); // strictly under the line: the window is over

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-50), isFalse); // restarted from here
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-50), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-50), isTrue);
    });

    test('a short dropout is bridged instead of restarting the window', () {
      final sensor = measured();

      sensor.add(-50); // t0
      now = now.add(const Duration(seconds: 1));
      sensor.add(-65); // a word gap: under the band, under releaseGrace
      now = now.add(const Duration(milliseconds: 100));
      expect(sensor.add(-50), isFalse); // bridged: still the same window

      now = now.add(const Duration(seconds: 1));
      expect(sensor.add(-50), isTrue); // 2.1 s of it: one strike, not two
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
      expect(sensor.thresholdDb, -55); // -77.5 + 5, clamped up to the floor
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
    /// the room, so the threshold is -55 dB and `-40` is comfortably over it.
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

    test('two seconds of meter noise is one strike, not none and not two', () {
      final sensor = calibrated();

      expect(
        sustainedNoise(sensor, const Duration(seconds: 2)),
        1,
        reason: 'the cooldown has to keep one burst to one strike even though the '
            'window closes long before the noise does',
      );
    });

    test('two words are enough: half a second of speech is a strike', () {
      final sensor = calibrated();

      // At AudioMonitor's real 250 ms rate the shortest burst that can close the
      // shipped 500 ms window is three samples - one opens it, the third lands
      // exactly 500 ms later. That is a couple of words, which is the point of the
      // tuning: a student reading a question aloud is caught, not only a shout.
      expect(sustainedNoise(sensor, const Duration(milliseconds: 750)), 1);
    });

    test('a cough - one or two samples - is still not enough', () {
      final sensor = calibrated();

      // Loud, but over before the window can add up: a cough, a door, a chair, a
      // breath. Only the amber indicator reacts, and nothing is logged.
      expect(sustainedNoise(sensor, const Duration(milliseconds: 500)), 0);
      expect(sensor.isNoisy, isTrue, reason: 'suspicious, not a violation');
    });

    test('the sampling offset cannot swallow a short burst', () {
      // A burst that starts just after a sample only contributes its remainder to
      // the window: 750 ms of noise yields 500 ms of evidence. The shipped window
      // is exactly that, so the shortest audible phrase still lands.
      final sensor = calibrated();
      expect(sensor.sustain, const Duration(milliseconds: 500));
      expect(sustainedNoise(sensor, const Duration(milliseconds: 750)), 1);

      // One sample less and nothing accrues: the window is not so short that the
      // 250 ms sampling interval alone closes it.
      final tooShort = calibrated();
      expect(sustainedNoise(tooShort, const Duration(milliseconds: 500)), 0);
    });
  });
}

