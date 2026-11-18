import 'dart:async';

import 'package:proctorguard/core/services/audio_noise_detector.dart';
import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart';
import 'package:proctorguard/core/services/proctoring_thresholds.dart';
import 'package:proctorguard/core/services/web_face_presence.dart';
import 'package:proctorguard/core/services/web_face_signal_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the look-away rule, the audio rule, and the relationship between their
/// halves.
///
/// The numbers live in `proctoring_thresholds.dart` so that each rule can be
/// stated in one sentence and changed in one place; these tests are what stops a
/// future edit from quietly turning a glance into a strike again (or a real
/// look-away into silence), and the same for a noisy room. They also check that the
/// engine's and the detector's defaults really are those constants - a copy of the
/// number in a constructor would pass the behaviour tests below while drifting from
/// the file a reviewer reads - and that the browser monitor quotes the same ones
/// instead of keeping its own.
void main() {
  group('look-away rule', () {
    test('one angle, absolute, on both axes - and one web-only exception', () {
      expect(lookAwayYawDegrees, 15.0);
      expect(lookAwayPitchDegrees, 15.0);
      // Absolute by construction: the same angle left and right, and up and down,
      // compared against the absolute value. The asymmetric pair this replaced (25
      // yaw, 18 pitch) made a tilt down a strike where the same tilt up was not,
      // and ML Kit and the web's FaceLandmarker do not even agree on which
      // direction is positive - so two numbers also meant two verdicts for one
      // head on two platforms.
      expect(lookAwayPitchDegrees, lookAwayYawDegrees);
      // The exception, and it is narrow on purpose: the *browser* allows a chin five
      // degrees further down, because the keyboard a browser student reads is below
      // the screen - and only downwards, because a chin *raised* past 15 degrees is a
      // monitor mounted above the screen, which is the second screen this rule exists
      // to catch. The phone has no such number: ML Kit's pitch sign has never been
      // verified, so a signed rule there would be a guess, and the engine goes on
      // judging the absolute angle.
      expect(lookAwayWebDownwardPitchDegrees, 20.0);
      expect(lookAwayWebDownwardPitchDegrees, greaterThan(lookAwayPitchDegrees));
      // Wide enough that the keyboard a browser student reads does not reach it,
      // narrow enough that a head which has stopped reading still does.
      expect(
        lookAwayWebDownwardPitchDegrees - lookAwayPitchDegrees,
        lessThanOrEqualTo(5.0),
      );
      expect(lookAwayWebDownwardPitchDegrees, lessThan(30.0));
      // A gate, not zero: a tolerance at zero would call every head position off
      // centre. And still tight enough that a second screen beside the laptop (a
      // 25-45 degree turn at a normal viewing distance) is comfortably past it.
      expect(lookAwayYawDegrees, greaterThan(0.0));
      expect(lookAwayYawDegrees, lessThan(25.0));
    });

    test('a look-away must be held for two seconds', () {
      expect(lookAwaySustain, const Duration(seconds: 2));
      // One frame at the detector's rate is ~150 ms. A sustain that short is a
      // blink, and a sustain longer than a few seconds lets a cheater read a whole
      // paragraph off another screen between strikes. This - not a wider angle -
      // is the app's answer to the false positives a strict 15 degrees lets in.
      expect(lookAwaySustain, greaterThan(const Duration(milliseconds: 500)));
      expect(lookAwaySustain, lessThanOrEqualTo(const Duration(seconds: 5)));
      // A negative sustain would report a look-away the detector has not seen for
      // any time at all, so the engine refuses it at construction.
      expect(
        () => MediaPipeProctoringService(
          lookAwaySustain: const Duration(seconds: -1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('both platforms judge a head with the same angle and the same hold', () {
      final engine = MediaPipeProctoringService();
      addTearDown(engine.dispose);
      final web = WebFacePresenceMonitor(source: _SilentSource());
      addTearDown(web.dispose);

      // Shared constants rather than restated ones: a browser session and a phone
      // session have to judge the same head the same way, or an appeal is decided
      // by which device the student happened to sit.
      expect(engine.offCenterThresholdDegrees, lookAwayYawDegrees);
      expect(engine.pitchThresholdDegrees, lookAwayPitchDegrees);
      expect(web.offCenterYawDegrees, lookAwayYawDegrees);
      expect(web.offCenterPitchDegrees, lookAwayPitchDegrees);
      // Equal on each platform in turn, so neither can drift into an asymmetry of
      // its own while still agreeing with the constants.
      expect(engine.offCenterThresholdDegrees, engine.pitchThresholdDegrees);
      expect(web.offCenterYawDegrees, web.offCenterPitchDegrees);
      // The one number that is *not* shared, and it is a widening rather than a
      // tightening: the browser allows a chin 20 degrees down where the phone allows
      // 15. Yaw, the upward half and the hold are the engine's own, so this is one
      // side of one axis on one platform - not the 25/18 pair above, which moved both
      // axes and applied to the phone as well.
      expect(web.downwardPitchDegrees, lookAwayWebDownwardPitchDegrees);
      expect(web.downwardPitchDegrees, greaterThan(web.offCenterPitchDegrees));
      expect(web.downwardPitchDegrees, greaterThan(web.offCenterYawDegrees));
      // ...and it cannot be narrowed into something tighter than a look up: a monitor
      // that judged a keyboard glance harder than a raised chin would be the old
      // asymmetry coming in through the constructor instead of the constants.
      expect(
        () => WebFacePresenceMonitor(
          source: _SilentSource(),
          offCenterPitchDegrees: 20.0,
          downwardPitchDegrees: 15.0,
        ),
        throwsA(isA<AssertionError>()),
      );
      // The *hold* is shared too, and this is the parity the audit asked for: 15
      // degrees of yaw or pitch up - 20 down, in a browser - held for two seconds, on
      // both platforms. The web measures that two seconds on a clock where the engine
      // measures it over consecutive frames, but the finding, and the number in it,
      // is one.
      expect(web.lookAwaySustain, lookAwaySustain);
      expect(web.lookAwaySustain, engine.lookAwaySustain);
      // Cross-platform equality of the gate itself, restated as one line rather than
      // inferred from the two constants above.
      expect(web.offCenterYawDegrees, engine.offCenterThresholdDegrees);
      // The near-sideways start is shared too, and it is a confirmation rather than
      // an exemption: past 30 degrees of yaw - twice the gate - two consecutive
      // detections are enough. Both numbers come from the one file so a browser
      // cannot be quicker than the phone for the same head again (it used to report
      // that turn on the *first* detection), and the count is what keeps one bad
      // Euler estimate - which can read 60 degrees - from being a strike.
      expect(web.immediateYawDegrees, lookAwayImmediateYawDegrees);
      expect(engine.immediateYawDegrees, lookAwayImmediateYawDegrees);
      expect(web.immediateConfirmations, lookAwayImmediateFrames);
      expect(engine.immediateFrameThreshold, lookAwayImmediateFrames);
      expect(lookAwayImmediateYawDegrees, greaterThan(lookAwayYawDegrees));
      // Not so wide that a real glance reaches it: a second screen beside the laptop
      // is a 25-45 degree turn, and 30 is where "no reading position explains this"
      // starts. Past 45 and a cheater would be free.
      expect(lookAwayImmediateYawDegrees, lessThanOrEqualTo(45.0));
      // "Seen twice" is the whole rule; a single detection is a frame, not a student.
      expect(lookAwayImmediateFrames, greaterThan(1));
      expect(lookAwayImmediateFrames, lessThanOrEqualTo(3));
      // Absence is the one window that is *not* the look-away's: a covered, muted
      // or unplugged camera has to say so at once, and the engine confirms it over
      // three frames (~0.45 s) rather than two seconds. Pinned, so a future tidy-up
      // cannot quietly make "my camera is covered" a two-second wait - or make a
      // student's blink a `no_face`.
      expect(web.noFaceSustain, const Duration(milliseconds: 300));
      expect(web.noFaceSustain, lessThan(web.lookAwaySustain));
      // And the start-up window is shared too, which is the other half of the audit's
      // finding: the browser ignored its first five seconds while Android judged its
      // very first frame, so a phone could strike a student who was still moving the
      // camera into place. One constant now, read by both.
      expect(cameraStartupGrace, const Duration(seconds: 5));
      expect(web.startupGrace, cameraStartupGrace);
      expect(engine.startupGrace, cameraStartupGrace);
    });

    test('repeated glances are judged in a window, beside the one above', () {
      // A student reading paper and screen in turn never holds a turn for two
      // seconds, so the sustained rule above saw nothing at all. The second way of
      // asking the same question is a rolling window: three glances, or five
      // seconds of them, inside a minute.
      expect(lookAwayMinEpisode, const Duration(milliseconds: 500));
      expect(lookAwayBurstWindow, const Duration(seconds: 60));
      expect(lookAwayBurstCount, 3);
      expect(lookAwayBurstCumulative, const Duration(seconds: 5));

      // A glance has to be shorter than the sustained hold, or that rule owns the
      // run already and one turn would be two strikes.
      expect(lookAwayMinEpisode, lessThan(lookAwaySustain));
      // ...and longer than a blink, or one bad Euler estimate would count.
      expect(lookAwayMinEpisode, greaterThan(const Duration(milliseconds: 100)));
      // Three counted glances have to fit inside the window with room to spare, or
      // a student glancing every half minute could never reach the count.
      expect(
        lookAwayBurstWindow,
        greaterThan(lookAwayMinEpisode * lookAwayBurstCount),
      );
      // The total is reachable without one counted glance - sub-minimum fragments
      // add up - which is the whole reason it sits beside the count...
      expect(
        lookAwayBurstCumulative,
        greaterThan(lookAwayMinEpisode * lookAwayBurstCount),
      );
      // ...and it is still a fraction of the minute, so a student who looks at the
      // keyboard now and then is not struck just for doing so.
      expect(lookAwayBurstCumulative, lessThan(lookAwayBurstWindow));
    });

    test('the same three glances are one strike on either platform', () async {
      // Parity is not a doc comment. Both hosts feed one `LookAwayBurstWindow`, and
      // this is the sequence that proves it: three 600 ms glances, two seconds
      // apart, each ended by a look back at the screen. Neither run reaches the
      // two-second hold, so the sustained rule is silent and the window is the only
      // thing that can speak.
      var now = DateTime(2026, 1, 1, 12);
      final engine = MediaPipeProctoringService(
        clock: () => now,
        startupGrace: Duration.zero,
      );
      addTearDown(engine.dispose);
      final fromEngine = <GazeSignal>[];
      final engineSub = engine.signals.listen(fromEngine.add);
      addTearDown(engineSub.cancel);

      final web = WebFacePresenceMonitor(
        source: _SilentSource(),
        clock: () => now,
        // The shipped five-second window would swallow this whole sequence; the
        // start-up rule has its own tests.
        startupGrace: Duration.zero,
      )..start(at: now);
      addTearDown(web.dispose);
      final fromWeb = <GazeSignal>[];
      final webSub = web.signals.listen(fromWeb.add);
      addTearDown(webSub.cancel);

      const turned = FaceFrameResult(faceCount: 1, yawDegrees: 30);
      const facing = FaceFrameResult(faceCount: 1);
      for (var glance = 0; glance < 3; glance++) {
        // 600 ms of a turned head: four frames on the phone, opened by the one
        // `looking_away` a browser detector would send at that instant.
        for (var frame = 0; frame < 4; frame++) {
          now = now.add(engine.inferenceInterval);
          if (frame == 0) {
            web.handleMessage(WebFaceMessages.lookingAway);
          }
          engine.handleResult(turned);
        }
        // ...and back at the screen, once for each host, at the same instant. The
        // browser is told twice, because its detector ticks every 350 ms and one
        // tick of `centered` is not a return (`lookAwayWebReturnDwell` - the page
        // says `centered` for a tick it could not measure a pose in): the second
        // message, 700 ms later, is the head *still* facing the screen, and it is
        // the one that ends the glance. The gap that follows is shortened by the
        // same 700 ms, so the two hosts see the same sequence in the same two
        // seconds.
        now = now.add(engine.inferenceInterval);
        web.handleMessage(WebFaceMessages.centered);
        engine.handleResult(facing);
        now = now.add(lookAwayWebReturnDwell);
        web.handleMessage(WebFaceMessages.centered);
        now = now.add(const Duration(seconds: 2) - lookAwayWebReturnDwell);
      }

      await pumpEventQueue();
      expect(
        fromEngine.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
        reason: 'three glances are one strike on the phone',
      );
      expect(
        fromWeb.where((signal) => signal == GazeSignal.lookingAway),
        hasLength(1),
        reason: '...and one on the browser, because it is the same window',
      );
      // Not just the same count but the same place in the sequence: the strike is
      // carried by the detection that ends the third glance, after two `centered`
      // signals, so an appeal reads the same on either platform.
      expect(fromEngine.indexOf(GazeSignal.lookingAway), 2);
      expect(fromWeb.indexOf(GazeSignal.lookingAway), 2);
    });

    test('a near-sideways turn is two detections on either platform', () async {
      // The responsiveness half of the rule, stated as parity rather than as a
      // comment: the same head, two consecutive detections, one strike - and nothing
      // from the first one, because one detection is a frame, not a student. The
      // browser used to report that turn on a single detection, which is both the
      // speed this keeps and the guess it drops.
      var now = DateTime(2026, 1, 1, 12);
      final engine = MediaPipeProctoringService(
        clock: () => now,
        startupGrace: Duration.zero,
      );
      addTearDown(engine.dispose);
      final fromEngine = <GazeSignal>[];
      final engineSub = engine.signals.listen(fromEngine.add);
      addTearDown(engineSub.cancel);

      final web = WebFacePresenceMonitor(
        source: _SilentSource(),
        clock: () => now,
        startupGrace: Duration.zero,
      )..start(at: now);
      addTearDown(web.dispose);
      final fromWeb = <GazeSignal>[];
      final webSub = web.signals.listen(fromWeb.add);
      addTearDown(webSub.cancel);

      const sideways = FaceFrameResult(faceCount: 1, yawDegrees: 60);
      now = now.add(engine.inferenceInterval);
      engine.handleResult(sideways);
      web.handleMessage('pose:60.0,0.0');
      await pumpEventQueue();
      expect(fromEngine, isEmpty, reason: 'one frame is a guess');
      expect(fromWeb, isEmpty, reason: 'one detection is the same guess');

      now = now.add(engine.inferenceInterval);
      engine.handleResult(sideways);
      web.handleMessage('pose:60.0,0.0');
      await pumpEventQueue();
      expect(fromEngine, <GazeSignal>[GazeSignal.lookingAway]);
      expect(fromWeb, <GazeSignal>[GazeSignal.lookingAway]);
    });
  });

  group('audio noise rule', () {
    test('the window is two seconds, and it is the same two as the look-away', () {
      expect(audioNoiseSustain, const Duration(seconds: 2));
      // The release asked for exactly this: "audio noise must be sustained for 2
      // seconds before it is reported". Long enough that a cough, a keystroke, a
      // chair or a door cannot fill it; the same standard the glance rule uses, so
      // the two ambient signals are not two different ideas of "sustained".
      expect(audioNoiseSustain, lookAwaySustain);
    });

    test('a dip below the threshold resets the window', () {
      // No bridging and no hysteresis band: the level has to stay above the line
      // for the whole two seconds. This is the strict reading of the rule and it is
      // what makes "sustained" mean one continuous episode rather than a total.
      expect(audioNoiseReleaseGrace, Duration.zero);
      expect(audioNoiseHysteresisDb, 0.0);
    });

    test('how loud is unchanged: a measured floor plus 6 dB, clamped', () {
      // "Do not change the noise level threshold itself" - so these three numbers
      // are pinned as they were, and only the window around them moved.
      expect(audioNoiseMarginDb, 6.0);
      expect(audioNoiseMinThresholdDb, -50.0);
      expect(audioNoiseMaxThresholdDb, -32.0);
      // A clamp, not a fixed threshold: a quiet room ends up at the bottom of the
      // band (sensitive), a loud one is pinned below its own floor so its steady
      // background is itself the finding.
      expect(audioNoiseMinThresholdDb, lessThan(audioNoiseMaxThresholdDb));
    });

    test('the detector ships those constants, not copies of them', () {
      // The same complaint as the look-away test above: a number written into the
      // constructor would pass the behaviour tests in `audio_monitoring_test.dart`
      // while drifting from the file a reviewer reads.
      final detector = AudioNoiseDetector();
      expect(detector.sustain, audioNoiseSustain);
      expect(detector.releaseGrace, audioNoiseReleaseGrace);
      expect(detector.hysteresisDb, audioNoiseHysteresisDb);
      expect(detector.speechMarginDb, audioNoiseMarginDb);
      expect(detector.minThresholdDb, audioNoiseMinThresholdDb);
      expect(detector.maxThresholdDb, audioNoiseMaxThresholdDb);
    });

    test('repeated short noise is judged in a window, beside the one above', () {
      // A detector that only asks "two unbroken seconds" hears a student reading the
      // paper out in phrases and logs nothing, because every pause resets the
      // window. The second way of asking the same question is a rolling window:
      // three phrases, or four seconds of fragments, inside a minute.
      expect(audioNoiseMinBurst, const Duration(milliseconds: 300));
      expect(audioNoiseBurstWindow, const Duration(seconds: 60));
      expect(audioNoiseBurstCount, 3);
      expect(audioNoiseBurstTotal, const Duration(seconds: 4));

      // A burst has to be shorter than the sustain, otherwise the two-second rule
      // would have reported the run already and the burst rule would never speak.
      expect(audioNoiseMinBurst, lessThan(audioNoiseSustain));
      // ...and longer than the room: a keystroke or a cough is tens of
      // milliseconds, and neither may count as a phrase.
      expect(
        audioNoiseMinBurst,
        greaterThan(const Duration(milliseconds: 100)),
      );
      // Three bursts have to fit comfortably inside the window, or a student
      // talking every couple of seconds could never reach the count.
      expect(
        audioNoiseBurstWindow,
        greaterThan(audioNoiseMinBurst * audioNoiseBurstCount),
      );
      // The total is reachable without ever producing one counted burst, which is
      // the whole reason it exists beside the count...
      expect(
        audioNoiseBurstTotal,
        greaterThan(audioNoiseMinBurst * audioNoiseBurstCount),
      );
      // ...and it is still a fraction of the window, so a busy room is not a strike
      // just for being busy.
      expect(audioNoiseBurstTotal, lessThan(audioNoiseBurstWindow));
    });

    test('the detector ships the burst window too', () {
      final detector = AudioNoiseDetector();
      expect(detector.minBurst, audioNoiseMinBurst);
      expect(detector.burstWindow, audioNoiseBurstWindow);
      expect(detector.burstCount, audioNoiseBurstCount);
      expect(detector.burstTotal, audioNoiseBurstTotal);
    });
  });
}

/// A web source that reports nothing: these tests are about the rule, not about
/// what a browser's detector saw.
class _SilentSource implements WebFaceSignalSource {
  final StreamController<String> _messages =
      StreamController<String>.broadcast();

  @override
  bool get isSupported => false;

  @override
  Stream<String> get messages => _messages.stream;

  /// No page, no opinion: these tests are about the rule.
  @override
  Stream<bool> get analysis => const Stream<bool>.empty();

  /// Nothing becomes visible again where nothing was hidden: these tests are
  /// about the rules, and the monitor is driven by [messages].
  @override
  Stream<void> get pageResumed => const Stream<void>.empty();

  @override
  void dispose() => _messages.close();
}
