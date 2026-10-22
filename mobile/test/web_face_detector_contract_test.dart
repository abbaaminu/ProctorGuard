import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/web_face_presence.dart';
import 'package:proctorguard/core/services/web_face_signal_source.dart';

/// Pins the browser half of proctoring, the way `web_manifest_contract_test.dart`
/// pins the install surface and `android_manifest_contract_test.dart` pins the
/// Android one.
///
/// `web/proctor_face_detector.js` is the only detector a browser student has: no
/// ML Kit reaches the web, and `camera_web` cannot hand frames to a model. What
/// the page *can* do is watch the preview camera_web renders, so that script is
/// where "the camera was covered / closed / blanked" becomes a `no_face` at all.
/// None of that is reachable from `flutter test` - there is no DOM on the VM and
/// no JavaScript engine to run the file - so the file itself, and the wiring in
/// `index.html`, are the contract.
///
/// Each group stands for a way this fails silently in production:
///
///  * **It was never loaded.** A detector nobody includes detects nothing, and
///    the symptom is a page that looks proctored and never logs a `no_face`.
///  * **It spoke a vocabulary Dart does not know.** The hook name and the
///    verdicts are strings on both sides of a language boundary; a rename on one
///    side compiles perfectly and silences the bridge.
///  * **It reported nothing for a camera that was gone.** A covered lens, an
///    ended track, a muted track, a paused or hidden element: each is a way a
///    student stops being watched without the app being told.
///  * **It invented evidence.** A frame it could not read, a camera that never
///    opened, a browser with no face model: accusing any of those is a strike a
///    student did not earn, so each has to be silence or `centered`.
///  * **It was polled too slowly to be a strike.** Dart sustains a verdict for
///    [WebFacePresenceMonitor.sustain]; a detector that reports once per sustain
///    would open an episode and never close it.
void main() {
  /// Reads a file relative to the package root (`mobile/`, the working directory
  /// `flutter test` uses). Null when a checkout does not have it, so a failure
  /// says "missing" rather than throwing a `FileSystemException` from a matcher.
  String? read(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  final source = read('web/proctor_face_detector.js');

  /// The script, with one assertion of presence so every group below can use it
  /// as a plain string.
  String detector() {
    expect(
      source,
      isNotNull,
      reason: 'web/proctor_face_detector.js is missing - a browser build has no '
          'face sensor without it',
    );
    return source!;
  }

  /// The polling interval written into the file. It is the only `INTERVAL_MS`
  /// constant, and it is what Dart's sustain is measured against.
  int pollingInterval() {
    final match = RegExp(r'INTERVAL_MS\s*=\s*(\d+)').firstMatch(detector());
    expect(
      match,
      isNotNull,
      reason: 'the detector has no INTERVAL_MS constant to reason about',
    );
    return int.parse(match!.group(1)!);
  }

  group('web/index.html loads the detector', () {
    test('with a relative src, before Flutter boots', () {
      final html = read('web/index.html');
      expect(html, isNotNull, reason: 'web/index.html is missing');

      final tag =
          RegExp(r'<script[^>]*src="([^"]*proctor_face_detector\.js)"[^>]*>');
      final match = tag.firstMatch(html!);
      expect(
        match,
        isNotNull,
        reason: 'web/index.html does not load proctor_face_detector.js, so a '
            'browser session has no face sensor at all',
      );

      // Relative, like every icon URL in that file: `--base-href` rewrites it, so
      // the build works from a sub-path. An absolute `/proctor_face_detector.js`
      // 404s under `https://example.edu/proctorguard/`.
      expect(match!.group(1), 'proctor_face_detector.js');

      // And before the loader: the script has to be polling by the time the exam
      // opens a camera. `defer`/`async` would leave that to a race with
      // flutter_bootstrap.js, which the bootstrap usually wins.
      final detectorAt = html.indexOf(match.group(0)!);
      final bootstrapAt = html.indexOf('flutter_bootstrap.js');
      expect(
        detectorAt,
        lessThan(bootstrapAt < 0 ? html.length : bootstrapAt),
        reason: 'the detector is loaded after Flutter, so the first frames of a '
            'sitting can go unwatched',
      );
      expect(
        RegExp(r'<script[^>]*proctor_face_detector\.js"[^>]*\b(type="module"|defer|async)')
            .hasMatch(html),
        isFalse,
        reason: 'the detector must be a plain blocking classic script: Dart looks '
            'its hook up by name on window, and a deferred or module script can '
            'run only after the app has already installed it',
      );
    });

    test('and the file is a classic script, not a module', () {
      final js = detector();
      // `import`/`export` at the start of a line is ES-module syntax: the file
      // would stop running as a page-level classic script.
      expect(
        RegExp(r'^[ \t]*(import|export)\b', multiLine: true).hasMatch(js),
        isFalse,
        reason: 'proctor_face_detector.js uses module syntax but is loaded as a '
            'classic script',
      );
      expect(js, contains("'use strict'"));
    });

    test('and installing it twice does not start a second loop', () {
      expect(
        detector(),
        contains('ProctorGuardFaceDetector.installed'),
        reason: 'a host page that includes the script twice gets two detectors '
            'reporting the same face at twice the rate',
      );
    });
  });

  group('the hook and the vocabulary match Dart', () {
    test('it calls window.proctorGuardFaceSignal', () {
      final js = detector();
      // The name Dart installs (`WebFaceSignalSource.globalName`), held against
      // the literal in the script: this handshake is the whole bridge.
      expect(
        js,
        contains("var HOOK = '${WebFaceSignalSource.globalName}'"),
        reason: 'the script looks for a global other than '
            '"${WebFaceSignalSource.globalName}", so Dart never hears a verdict',
      );
      expect(
        RegExp(r"typeof hook === 'function'").hasMatch(js),
        isTrue,
        reason: 'the hook is not type-checked before it is called, so a page '
            'with no attempt open would throw on every tick',
      );
    });

    test('every verdict it speaks is a WebFaceMessages constant', () {
      final js = detector();
      for (final message in <String>[
        WebFaceMessages.centered,
        WebFaceMessages.noFace,
        WebFaceMessages.multipleFaces,
      ]) {
        expect(
          js,
          contains("'$message'"),
          reason: 'the script never says "$message", which '
              'WebFacePresenceMonitor understands and turns into a signal',
        );
      }
    });

    test('it does not claim a head pose it cannot measure', () {
      // `looking_away` is an angle. A bounding box is not one, and a page that
      // measures it properly says so itself through
      // `WebFaceMessages.lookingAway`; guessing is inventing evidence.
      expect(
        detector(),
        isNot(contains("'${WebFaceMessages.lookingAway}'")),
        reason: 'the script reports a head pose it has no model to measure',
      );
    });
  });

  group('a camera that is not delivering is no_face', () {
    test('the track, the element and the styles are all checked', () {
      final js = detector();
      // getVideoTracks/readyState/muted/enabled: the camera was closed, the
      // device was unplugged, the grant was revoked, or the track was blanked
      // from devtools. paused/ended/readyState/videoWidth: the element was
      // stopped or never started. display/visibility/opacity: the preview was
      // hidden behind the page.
      for (final probe in <String>[
        'getVideoTracks',
        'readyState',
        'muted',
        'enabled',
        'paused',
        'videoWidth',
        'display',
        'visibility',
        'opacity',
      ]) {
        expect(
          js,
          contains(probe),
          reason: 'nothing in the script reads "$probe", so at least one way of '
              'closing, blanking or hiding the camera goes unnoticed',
        );
      }
      expect(
        js,
        contains('function inactiveReason'),
        reason: 'the single place that decides "is this camera showing anything" '
            'is gone, so the reasons are being scattered again',
      );
      expect(
        RegExp(r'MESSAGES\.noFace').allMatches(js).length,
        greaterThanOrEqualTo(3),
        reason: 'no_face is not reachable from all three of the inactive-camera, '
            'blank-frame and zero-face paths',
      );
    });

    test('the frame is sampled into a thumbnail and judged blank', () {
      final js = detector();
      expect(js, contains('drawImage(element'));
      expect(js, contains('getImageData('));
      expect(
        js,
        contains('frameIsBlank(sampleFrame(element))'),
        reason: 'a covered lens is a black frame with a working track: the script '
            'has to measure the picture itself, not just the camera element',
      );
      // Mean and spread, not a single pixel: one dark pixel is a shadow, a dark
      // low-variance frame is a hand over the lens.
      expect(js, contains('sample.spread'));
      expect(js, contains('sample.mean'));
    });

    test('only a camera that has shown a live frame can go dark', () {
      expect(
        detector(),
        contains('seenLive === element ? MESSAGES.noFace : null'),
        reason: 'a preview that never opened (a retry that failed, a refused '
            'permission) reports no_face, which accuses a student of covering a '
            'camera that was never on',
      );
    });
  });

  group('it never invents evidence', () {
    test('an unreadable frame or a failed detector is silence', () {
      final js = detector();
      // `sampleFrame` gives null for a tainted canvas or a decoder that is not
      // ready; `countFaces` resolves to null when the model threw. Both are "could
      // not look", and neither is "nobody there".
      expect(
        js,
        contains('if (!sample) return false'),
        reason: 'an unreadable frame is being called blank, which is a no_face on '
            'a browser that merely refused getImageData',
      );
      expect(
        js,
        contains('if (faces === null) finished(null, session)'),
        reason: 'a face model that threw is being read as zero faces, which is a '
            'strike for a detection that never ran',
      );
    });

    test('no face model means centered, never no_face', () {
      final js = detector();
      final branch = RegExp(r'if \(!detection\) \{[\s\S]*?\n      \}').firstMatch(js);
      expect(
        branch,
        isNotNull,
        reason: 'the no-model branch is gone; a browser without the Shape '
            'Detection API still has to end an absence episode',
      );
      expect(
        branch!.group(0),
        contains('MESSAGES.centered'),
        reason: 'without a face model the only honest verdict about a live, '
            'non-blank frame is centered - no_face there accuses a student the '
            'page never actually failed to see',
      );
      expect(
        branch.group(0),
        isNot(contains('MESSAGES.noFace')),
        reason: 'the no-model branch reports no_face for a frame it is looking at',
      );
    });

    test('a blank frame is judged before a face is counted in it', () {
      final js = detector();
      expect(
        js.indexOf('frameIsBlank(sampleFrame(element))'),
        lessThan(js.indexOf('var detection = countFaces(element);')),
        reason: 'the face count runs on a frame that has not been checked for '
            'being blank, so a detector can find a face in a black rectangle',
      );
    });
  });

  group('the loop', () {
    test('is polled faster than the sustain it has to fill', () {
      final monitor = WebFacePresenceMonitor(source: _SilentSource());
      addTearDown(monitor.dispose);

      final interval = pollingInterval();
      expect(
        interval,
        greaterThan(monitor.sustain.inMilliseconds),
        reason: 'the detector polls every $interval ms and the monitor sustains a '
            'verdict for ${monitor.sustain.inMilliseconds} ms, so a verdict can be '
            're-sent before the sustain has elapsed and a covered camera never '
            'reaches a strike',
      );
      expect(
        interval,
        lessThanOrEqualTo(1000),
        reason: 'a covered camera waiting over a second between samples is a '
            'strike the student has earned arriving late',
      );
    });

    test('repeats a holding verdict and drops a repeated centered', () {
      expect(
        detector(),
        contains('message === lastVerdict && message === MESSAGES.centered'),
        reason: 'centered is being re-sent every tick (which drowns the bridge in '
            'signals), or no_face is being deduplicated (which breaks the sustain '
            'Dart measures in time)',
      );
    });

    test('skips its work between attempts and comes back for the next one', () {
      final js = detector();
      expect(
        js,
        contains('if (!drainHook())'),
        reason: 'the loop is not asking whether anything is listening, so it '
            'walks the DOM and reads pixels between attempts',
      );
      expect(js, contains('lastVerdict = null'));
      expect(js, contains('window.setTimeout('));
      expect(js, contains('window.clearTimeout('));
    });

    test('a stale detection after stop cannot report', () {
      // Every async path carries the generation it started in: a `detect()`
      // promise that resolves after stop() (or after a stop/start pair) must not
      // speak into a closed attempt or free the guard of the tick that owns it.
      final js = detector();
      expect(js, contains('if (session !== generation) return'));
      expect(js, contains('generation++'));
    });

    test('finds the preview through Flutter\'s platform view', () {
      final js = detector();
      // camera_web renders into a platform view, whose element can sit inside a
      // shadow root: `document.querySelector('video')` alone finds nothing there.
      expect(js, contains('shadowRoot'));
      expect(js, contains("querySelectorAll('video')"));
      expect(js, contains('MAX_SHADOW_DEPTH'));
    });
  });
}

/// A source with nothing to say, so the monitor's defaults can be read on the VM.
///
/// The rules themselves are covered by `web_face_presence_test.dart`; this file
/// only needs [WebFacePresenceMonitor.sustain] to hold the JavaScript interval
/// against.
class _SilentSource implements WebFaceSignalSource {
  @override
  bool get isSupported => true;

  @override
  Stream<String> get messages => const Stream<String>.empty();

  @override
  void dispose() {}
}
