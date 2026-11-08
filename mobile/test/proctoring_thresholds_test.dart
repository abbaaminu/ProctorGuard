import 'dart:async';

import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart';
import 'package:proctorguard/core/services/proctoring_thresholds.dart';
import 'package:proctorguard/core/services/web_face_presence.dart';
import 'package:proctorguard/core/services/web_face_signal_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the look-away rule, and the relationship between its two halves.
///
/// The numbers live in `proctoring_thresholds.dart` so that the rule can be
/// stated in one sentence and changed in one place; these tests are what stops a
/// future edit from quietly turning a glance into a strike again (or a real
/// look-away into silence). They also check that the engine's defaults really are
/// those constants - a copy of the number in the constructor would pass the
/// behaviour tests below while drifting from the file a reviewer reads - and that
/// the browser monitor quotes the same ones instead of keeping its own.
void main() {
  group('look-away rule', () {
    test('one angle, absolute, on both axes', () {
      expect(lookAwayYawDegrees, 15.0);
      expect(lookAwayPitchDegrees, 15.0);
      // Symmetric by construction: the same angle left and right, up and down,
      // compared against the absolute value. The asymmetric pair this replaced (25
      // yaw, 18 pitch) made a tilt down a strike where the same tilt up was not,
      // and ML Kit and the web's FaceLandmarker do not even agree on which
      // direction is positive - so two numbers also meant two verdicts for one
      // head on two platforms.
      expect(lookAwayPitchDegrees, lookAwayYawDegrees);
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

    test('both platforms judge a head with the same angle', () {
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
      // The web's near-sideways shortcut may only shorten the wait for a head that
      // is already unmistakably turned; it is asserted in the monitor itself to be
      // past the ordinary tolerance, and this is the same statement from outside.
      expect(web.immediateAwayYawDegrees, greaterThan(web.offCenterYawDegrees));
      // The sustain is the one number the web does not take from the engine: a
      // page's detector has no fixed frame rate, so the monitor measures elapsed
      // time against its own window instead of counting frames.
      // `web_face_presence.dart` explains the difference.
      expect(web.sustain, isNot(lookAwaySustain));
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

  @override
  void dispose() => _messages.close();
}

