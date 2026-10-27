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
      reason:
          'web/proctor_face_detector.js is missing - a browser build has no '
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

      final tag = RegExp(
        r'<script[^>]*src="([^"]*proctor_face_detector\.js)"[^>]*>',
      );
      final match = tag.firstMatch(html!);
      expect(
        match,
        isNotNull,
        reason:
            'web/index.html does not load proctor_face_detector.js, so a '
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
        reason:
            'the detector is loaded after Flutter, so the first frames of a '
            'sitting can go unwatched',
      );
      expect(
        RegExp(
          r'<script[^>]*proctor_face_detector\.js"[^>]*\b(type="module"|defer|async)',
        ).hasMatch(html),
        isFalse,
        reason:
            'the detector must be a plain blocking classic script: Dart looks '
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
        reason:
            'proctor_face_detector.js uses module syntax but is loaded as a '
            'classic script',
      );
      expect(js, contains("'use strict'"));
    });

    test('and installing it twice does not start a second loop', () {
      expect(
        detector(),
        contains('ProctorGuardFaceDetector.installed'),
        reason:
            'a host page that includes the script twice gets two detectors '
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
        reason:
            'the script looks for a global other than '
            '"${WebFaceSignalSource.globalName}", so Dart never hears a verdict',
      );
      expect(
        RegExp(r"typeof hook === 'function'").hasMatch(js),
        isTrue,
        reason:
            'the hook is not type-checked before it is called, so a page '
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
          reason:
              'the script never says "$message", which '
              'WebFacePresenceMonitor understands and turns into a signal',
        );
      }
    });

    test('it does not claim a head pose it cannot measure', () {
      // `looking_away` is an angle, and it is Dart's call: a page may report
      // what it measured (`pose:yaw,pitch`), never what it is worth. Deciding
      // that 20 degrees is a look away belongs to
      // `WebFacePresenceMonitor.offCenterYawDegrees`, where the same rule
      // applies to a phone's frames.
      final js = detector();
      expect(
        js,
        isNot(contains("'${WebFaceMessages.lookingAway}'")),
        reason:
            'the script reports a verdict instead of a measurement, so a '
            'browser sitting is judged by whatever threshold the page guessed',
      );
      expect(
        js,
        contains(WebFaceMessages.posePrefix),
        reason:
            'the detector has no way to say what it measured, so a browser '
            'can never produce a `looking_away` at all - which is the whole '
            'reason a measured pose exists in the vocabulary',
      );
    });

    test('it measures the pose from the landmarks, not from a box', () {
      final js = detector();
      // The Shape Detection API's `landmarks` are the only geometry a browser
      // gives: two eyes and a nose are enough for a yaw, and a bounding box is
      // not (its centre does not move when a head turns in place).
      for (final probe in <String>[
        'function measurePose',
        "'eye'",
        "'nose'",
        'Math.asin',
      ]) {
        expect(
          js,
          contains(probe),
          reason:
              'nothing in the reading uses $probe, so a measured pose is '
              'either invented or derived from a box that cannot know it',
        );
      }
      // Jitter is not a violation: a landmark model wobbles by a degree or two
      // between frames, and the samples that reach Dart have to be a median.
      expect(
        js,
        contains('function smoothedPose'),
        reason:
            'raw per-frame angles are being reported, so one jittery frame '
            'is one warning a student did not earn',
      );
      final window = RegExp(r'POSE_WINDOW\s*=\s*(\d+)').firstMatch(js);
      expect(window, isNotNull, reason: 'POSE_WINDOW is gone');
      expect(
        int.parse(window!.group(1)!),
        greaterThanOrEqualTo(2),
        reason: 'a window of one sample is no smoothing at all',
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
          reason:
              'nothing in the script reads "$probe", so at least one way of '
              'closing, blanking or hiding the camera goes unnoticed',
        );
      }
      expect(
        js,
        contains('function inactiveReason'),
        reason:
            'the single place that decides "is this camera showing anything" '
            'is gone, so the reasons are being scattered again',
      );
      expect(
        RegExp(r'MESSAGES\.noFace').allMatches(js).length,
        greaterThanOrEqualTo(3),
        reason:
            'no_face is not reachable from all three of the inactive-camera, '
            'blank-frame and zero-face paths',
      );
    });

    test('the frame is sampled into a thumbnail and judged blank', () {
      final js = detector();
      expect(js, contains('drawImage(element'));
      expect(js, contains('getImageData('));
      expect(
        js,
        contains('var sample = sampleFrame(element)'),
        reason:
            'the picture is not sampled exactly once per tick, so the blank '
            'test and the "has this frame changed at all" test can disagree',
      );
      expect(
        js,
        contains('frameIsBlank(sample)'),
        reason:
            'a covered lens is a dim, featureless frame with a working track: '
            'the script has to measure the picture itself, not just the camera '
            'element',
      );
      // Mean and spread, not a single pixel: one dark pixel is a shadow, a dark
      // low-variance frame is a hand over the lens.
      expect(js, contains('sample.spread'));
      expect(js, contains('sample.mean'));
    });

    test('a covered lens is judged by structure, not by near-black', () {
      final js = detector();
      final rules = RegExp(
        r'function frameIsBlank\([\s\S]*?\n  \}',
      ).firstMatch(js);
      expect(rules, isNotNull, reason: 'the blank-frame rules are gone');

      final body = rules!.group(0)!;
      expect(
        body,
        contains('sample.spread <= FEATURELESS_SPREAD'),
        reason:
            'a frame with no structure is not being called blank whatever its '
            'brightness. This is the rule a hand, a sticker or a closed shutter '
            'over the lens trips, and it was the bug: auto-exposure lifts a covered '
            'lens to a grey-brown (a measured mean of ~39, spread ~3.6), so a '
            '"darker than 18 luma" test reported a covered camera as `centered` '
            'and the student was never flagged',
      );
      expect(
        body,
        contains('sample.mean <= DARK_MEAN && sample.spread <= DARK_SPREAD'),
        reason:
            'a dim, near-featureless frame is not judged blank, so a covered '
            'camera in a dark room passes as a face',
      );
      expect(
        body,
        contains('sample.mean >= BLOWN_MEAN && sample.spread <= BLOWN_SPREAD'),
        reason: 'a camera pointed into a lamp is no longer treated as a face',
      );

      // The calibration itself, held against the measurements it came from.
      final featureless = RegExp(
        r'FEATURELESS_SPREAD\s*=\s*(\d+)',
      ).firstMatch(js);
      expect(featureless, isNotNull, reason: 'FEATURELESS_SPREAD is gone');
      expect(
        int.parse(featureless!.group(1)!),
        greaterThanOrEqualTo(4),
        reason:
            'a covered lens measures a spread of 3-4 at this thumbnail size, '
            'so a lower line would let the exact case this rule exists for through',
      );

      final darkMean = RegExp(r'DARK_MEAN\s*=\s*(\d+)').firstMatch(js);
      expect(darkMean, isNotNull, reason: 'DARK_MEAN is gone');
      expect(
        int.parse(darkMean!.group(1)!),
        greaterThanOrEqualTo(60),
        reason:
            'a covered lens in a lit room measures a mean of 35-75 luma; a '
            'lower ceiling would only catch a lens capped in the dark',
      );
      expect(
        js,
        isNot(contains('DARK_LUMA')),
        reason:
            'the old near-black-only rule is back: it cannot see a covered '
            'lens that auto-exposure has lifted off black',
      );
    });

    test('a still picture is not a live camera', () {
      final js = detector();
      expect(
        js,
        contains('trackFrozen(pixels)'),
        reason:
            'nothing compares one frame with the next, so a printed photo, a '
            'virtual camera looping a screenshot or a stalled decoder is a face '
            'for as long as it is held up',
      );
      expect(
        js,
        contains('lastPixels'),
        reason:
            'the previous frame is not kept, so "the same picture again" '
            'cannot be recognised',
      );
      expect(
        js,
        contains('sample.frozen'),
        reason: 'the repeat count never reaches the blank-frame verdict',
      );
      final frozenTicks = RegExp(r'FROZEN_TICKS\s*=\s*(\d+)').firstMatch(js);
      expect(frozenTicks, isNotNull, reason: 'FROZEN_TICKS is gone');
      expect(
        int.parse(frozenTicks!.group(1)!),
        greaterThanOrEqualTo(2),
        reason:
            'one repeated frame is a dropped frame in the capture pipeline, '
            'not a photograph',
      );
    });

    test('a preview that never delivers is reported once it has stalled', () {
      final js = detector();
      expect(
        js,
        contains('STALL_MS'),
        reason:
            'a camera blocked before the first tick could see it live is never '
            'reported: `seenLive` is never set, so the page stays silent for the '
            'whole sitting',
      );
      expect(
        js,
        contains('seenLive === element || stalled'),
        reason: 'the stalled preview is not reaching the no_face verdict',
      );
      expect(
        js,
        contains('Date.now() - inactiveSince'),
        reason:
            'the stall is not measured in time, so it can fire before a camera '
            'has had a chance to deliver its first frame',
      );
    });

    test('a hidden page reports nothing at all', () {
      expect(
        detector(),
        contains("document.visibilityState === 'hidden'"),
        reason:
            'a backgrounded tab is `app_minimized` from the web guard, and the '
            'browser throttles timers there: a no_face as well charges one act twice '
            'and accuses a student of hiding a preview they could not uncover',
      );
    });

    test('it can explain why nothing is being flagged', () {
      final js = detector();
      expect(
        js,
        contains('diagnostics: function'),
        reason:
            'a browser session that never flags anything has no way to say '
            'which half is silent: no hook, no preview, or no frame',
      );
      expect(js, contains('hook: !!drainHook()'));
      expect(js, contains("'no-preview'"));
    });

    test('only a camera that has shown a live frame can go dark', () {
      final js = detector();
      expect(
        js,
        contains('seenLive === element'),
        reason:
            'a preview that never opened (a retry that failed, a refused '
            'permission) is not told apart from one that went dark',
      );
      expect(
        js,
        contains('seenLive = element'),
        reason:
            'nothing ever records that this camera did show a live frame, so '
            'a covered lens can go unreported for the whole sitting',
      );
      expect(
        js,
        contains('function inactiveReason'),
        reason:
            'the single place that decides "is this camera showing anything" '
            'is gone, so the reasons are being scattered again',
      );
    });
  });

  group('it never invents evidence', () {
    test('an unreadable frame or a failed detector is silence', () {
      final js = detector();
      // `sampleFrame` gives null for a tainted canvas or a decoder that is not
      // ready; `inspect` resolves to null when the model threw. Both are "could
      // not look", and neither is "nobody there".
      expect(
        js,
        contains('if (!sample) return false'),
        reason:
            'an unreadable frame is being called blank, which is a no_face on '
            'a browser that merely refused getImageData',
      );
      expect(
        js,
        contains('function inspect'),
        reason:
            'the face reading is gone, so nothing can tell a model that saw '
            'no face from one that never ran',
      );
      expect(
        js,
        contains('if (!reading) {'),
        reason:
            'a face model that threw is being read as zero faces, which is a '
            'strike for a detection that never ran',
      );
      expect(
        js,
        contains('if (!faces) return { faces: 0, yaw: null, pitch: null }'),
        reason:
            'a detector that resolves to nothing is not being read as "no '
            'face", so an empty result can crash the tick instead of clearing it',
      );
    });

    test('no face model means centered, never no_face', () {
      final js = detector();
      final branch = RegExp(
        r'if \(!detection\) \{[\s\S]*?\n      \}',
      ).firstMatch(js);
      expect(
        branch,
        isNotNull,
        reason:
            'the no-model branch is gone; a browser without the Shape '
            'Detection API still has to end an absence episode',
      );
      expect(
        branch!.group(0),
        contains('MESSAGES.centered'),
        reason:
            'without a face model the only honest verdict about a live, '
            'non-blank frame is centered - no_face there accuses a student the '
            'page never actually failed to see',
      );
      expect(
        branch.group(0),
        isNot(contains('MESSAGES.noFace')),
        reason:
            'the no-model branch reports no_face for a frame it is looking at',
      );
    });

    test('a blank frame is judged before a face is read in it', () {
      final js = detector();
      expect(
        js.indexOf('frameIsBlank(sample)'),
        lessThan(js.indexOf('var detection = inspect(element);')),
        reason:
            'the face reading runs on a frame that has not been checked for '
            'being blank, so a detector can find a face in a black rectangle',
      );
    });
  });

  /// The model this build ships, pinned the way the loop below is: the assets it
  /// names have to be in the build, it has to come from this origin, and it has to
  /// stay a *sensor*. A browser with no Shape Detection API is most of the desktop
  /// traffic - Chrome and Edge, every Firefox and Safari - so this is the only head
  /// pose those students have, and every way it goes wrong is silent: a model that
  /// never loaded leaves `centered` looking exactly like a face at the screen.
  group('the shipped head-pose model', () {
    /// The three paths in the `MEDIAPIPE` block, exactly as the script writes them.
    Map<String, String> shippedPaths() {
      final block = RegExp(
        r'var MEDIAPIPE = \{[\s\S]*?\};',
      ).firstMatch(detector());
      expect(
        block,
        isNotNull,
        reason:
            'the MEDIAPIPE block is gone, so the model has no asset paths to '
            'check against the build',
      );
      final paths = <String, String>{};
      for (final key in ['module', 'wasm', 'model']) {
        final match = RegExp("$key:\\s*'([^']*)'").firstMatch(block!.group(0)!);
        expect(
          match,
          isNotNull,
          reason:
              'MEDIAPIPE names no $key, so the loader either fetches nothing or '
              'fetches an asset no deployment was told to serve',
        );
        paths[key] = match!.group(1)!;
      }
      return paths;
    }

    test('names assets this build actually ships', () {
      final paths = shippedPaths();
      final module = paths['module']!;
      final wasm = paths['wasm']!;
      final model = paths['model']!;

      // Relative, like the detector's own script tag: `--base-href` and the
      // `<base href>` in index.html rewrite them, so a sub-path deployment works.
      for (final path in [module, wasm, model]) {
        expect(
          path,
          isNot(startsWith('/')),
          reason:
              'a model path is absolute, so a deployment under a sub-path '
              '(https://example.edu/proctorguard/) fetches it from the domain root '
              'and gets a 404',
        );
        expect(
          path,
          isNot(contains('://')),
          reason: 'a model path is a full URL',
        );
      }

      expect(
        File('web/$module').existsSync(),
        isTrue,
        reason:
            'web/$module is not in the build, so a browser without the Shape '
            'Detection API has no face model at all',
      );
      expect(
        File('web/$model').existsSync(),
        isTrue,
        reason:
            'web/$model is not in the build, so the module has nothing to '
            'solve a head pose from',
      );
      // The bundle resolves these two by name against the directory it is given.
      for (final name in [
        'vision_wasm_internal.js',
        'vision_wasm_internal.wasm',
      ]) {
        expect(
          File('web/$wasm/$name').existsSync(),
          isTrue,
          reason:
              'web/$wasm/$name is not in the build, so the model cannot be '
              'compiled and every tick falls back to centered',
        );
      }
    });

    test('is loaded from this origin, lazily, and never retried', () {
      final js = detector();
      // One dynamic import in code, inside the loader (the comments above it
      // mention `import()` by name, so the count is of the statement itself): a
      // top-level one would make this a module and stop it being the classic
      // script index.html loads.
      expect(
        RegExp(r'return import\(').allMatches(js).length,
        1,
        reason:
            'the detector holds more than one dynamic import in code, so the '
            'model is being fetched from somewhere other than ensureMediaPipe',
      );
      // `import('mediapipe/vision_bundle.mjs')` is a *bare* specifier and fails
      // with "Failed to resolve module specifier": the path has to be resolved
      // against the page first.
      expect(
        js,
        contains('new URL(specifier, document.baseURI)'),
        reason:
            'the model specifier reaches import() unresolved, so the browser '
            'refuses to load it and the page quietly keeps answering centered',
      );
      expect(
        js,
        contains('window.proctorGuardMediaPipe'),
        reason:
            'a host cannot point the detector at its own model, or turn it off '
            'for a deployment that has none',
      );
      expect(
        RegExp(r'mediaPipe\.state = .failed.').hasMatch(js),
        isTrue,
        reason:
            'nothing records that the model was given up on, so diagnostics '
            'cannot tell "no model" from "the model saw nothing"',
      );
      expect(
        js,
        contains('MEDIAPIPE_FAILURES'),
        reason:
            'a model that fails every frame is retried for the life of the '
            'page instead of being given up on',
      );
    });

    test('a model that never loads is centered, never no_face', () {
      final js = detector();
      final giveUp = RegExp(
        r'function giveUpMediaPipe\(reason\) \{[\s\S]*?\n  \}',
      ).firstMatch(js);
      expect(giveUp, isNotNull, reason: 'the give-up path is gone');
      expect(
        giveUp!.group(0),
        isNot(contains('MESSAGES.noFace')),
        reason:
            'a browser whose model failed to load is reporting no_face for '
            'frames it never read - a strike for a download error',
      );
      // Null, not a zero-face reading: the same shape as a detector that threw.
      expect(
        js,
        contains("if (mediaPipe.state !== 'ready') return null"),
        reason:
            'a model that is still loading or already gone is being read as '
            '"no face", so the first ticks of a sitting accuse a student who is '
            'right there',
      );
      expect(
        js,
        contains(
          "if (mediaPipe.state !== 'ready' || !mediaPipe.landmarker) return;",
        ),
        reason:
            'the pump runs before the model exists, losing ticks while its '
            'WebAssembly is still compiling',
      );
      // A reading from a frame nobody is serving any more is not evidence.
      expect(
        js,
        contains('MEDIAPIPE_STALE_MS'),
        reason:
            'a model that stopped answering keeps its last angles forever, so '
            'a student who walked away is judged by a face from ten seconds ago',
      );
    });

    test('measures a head pose, in the units Dart judges', () {
      final js = detector();
      expect(
        js,
        contains("runningMode: 'VIDEO'"),
        reason:
            'the model is not in the mode that keeps a tracker between frames, '
            'so every tick is an independent guess and the pose jitters',
      );
      expect(
        js,
        contains('numFaces: 2'),
        reason:
            'a model that stops at one face can never report multiple_faces, '
            'which is a verdict Dart acts on',
      );
      expect(
        js,
        contains('outputFacialTransformationMatrixes: true'),
        reason:
            'the model is not asked for the head pose it solved, so the angles '
            'fall back to a 2D approximation that cannot see a nod',
      );
      expect(
        js,
        contains(".delegate = 'CPU'"),
        reason:
            'there is no CPU retry: a machine without usable WebGL (a kiosk, a '
            'headless runner, a blocklisted driver) has no head pose at all',
      );
      // The one decimal `web_face_presence_test.dart` pins Dart parsing to.
      expect(
        js,
        contains('pose.yaw.toFixed(1)'),
        reason:
            'the yaw is not formatted the way Dart reads pose:<yaw>,<pitch>',
      );
      expect(
        js,
        contains('pose.pitch.toFixed(1)'),
        reason:
            'the pitch is not formatted the way Dart reads pose:<yaw>,<pitch>',
      );
      // Both providers: the Shape Detection API's landmarks and the model's, in
      // one definition of yaw, so a desktop browser and an Android tablet judge
      // the same head turn the same way.
      expect(
        RegExp(r'function measurePose\(face\)').hasMatch(js),
        isTrue,
        reason: 'the landmark measurement this file has always used is gone',
      );
      expect(
        js,
        contains('function landmarkPose('),
        reason:
            'the shipped model\'s landmarks are not measured through the same '
            'geometry as the browser\'s own, so the two providers disagree',
      );
    });

    test('needs no CSP origin the page did not already have', () {
      final html = read('web/index.html');
      expect(html, isNotNull, reason: 'web/index.html is missing');
      for (final origin in [
        'jsdelivr',
        'unpkg.com',
        'storage.googleapis.com',
        'cdnjs',
      ]) {
        expect(
          html!,
          isNot(contains(origin)),
          reason:
              'index.html points at $origin: the model has to be served by this '
              'app, because an exam that depends on a third-party CDN fails closed '
              'on a network that blocks it and trusts a host nobody audited',
        );
      }
      expect(
        html,
        contains("'wasm-unsafe-eval'"),
        reason:
            'the policy no longer allows WebAssembly compilation, which the '
            'model needs as much as CanvasKit does',
      );
    });

    test('is exercised under that policy, not on an unpolicied page', () {
      final labFile = read('tool/face_lab/lab.js');
      final harness = read('tool/face_lab/harness.html');
      expect(
        labFile,
        isNotNull,
        reason:
            'tool/face_lab/lab.js is missing - nothing loads the real model',
      );
      final lab = labFile!;
      // The lab must not keep its own copy of the policy: a copy passes while the
      // page ships something narrower, which is the only thing being tested.
      expect(
        lab,
        contains("'web', 'index.html'"),
        reason:
            'the lab no longer reads the policy out of web/index.html, so the '
            'model scenario runs on a page with no policy at all and proves '
            'nothing about the page a student loads',
      );
      expect(
        lab,
        contains('Content-Security-Policy'),
        reason: 'the lab sends no Content-Security-Policy header to the page',
      );
      expect(
        lab,
        contains("'mediapipe+csp'"),
        reason:
            'no scenario loads the shipped model under the shipped policy, so a '
            'model the CSP refuses would fall back to centered in production '
            'with every other test still green',
      );
      expect(
        harness,
        contains('securitypolicyviolation'),
        reason:
            'a refused load would be silent: without this listener a policy '
            'violation is neither an error nor a failure, only a page that '
            'quietly answers centered',
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
        reason:
            'the detector polls every $interval ms and the monitor sustains a '
            'verdict for ${monitor.sustain.inMilliseconds} ms, so a verdict can be '
            're-sent before the sustain has elapsed and a covered camera never '
            'reaches a strike',
      );
      expect(
        interval,
        lessThanOrEqualTo(1000),
        reason:
            'a covered camera waiting over a second between samples is a '
            'strike the student has earned arriving late',
      );
    });

    test('rate-limits a repeated centered and never deduplicates a verdict', () {
      final js = detector();
      // `centered` is not evidence, but it is the only "the student is still
      // there and this sensor is still watching" the page can say: rate-limited
      // rather than dropped, so a silent detector and a quiet student are told
      // apart. Every other verdict *must* be re-sent, because Dart measures a
      // sustain in time.
      expect(
        js,
        contains('message === lastVerdict &&'),
        reason: 'nothing compares a verdict with the one before it',
      );
      expect(
        js,
        contains('message === MESSAGES.centered &&'),
        reason:
            'centered is being re-sent every tick (which drowns the bridge in '
            'signals), or no_face is being deduplicated (which breaks the sustain '
            'Dart measures in time)',
      );
      expect(
        js,
        contains('CENTERED_REPEAT_MS'),
        reason:
            'a dropped-but-repeated centered leaves the app unable to tell a '
            'working detector from one that died after its first tick',
      );
    });

    test('skips its work between attempts and comes back for the next one', () {
      final js = detector();
      expect(
        js,
        contains('if (!drainHook())'),
        reason:
            'the loop is not asking whether anything is listening, so it '
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

    test('watches the page\'s own camera when no preview carries it', () {
      // The failure this covers: camera_web is free to draw its self-view
      // somewhere this script cannot see (a platform view slot, a canvas, a
      // widget that can render to a texture), and a detector that then reports
      // nothing leaves a browser student entirely unproctored while the app
      // shows them their own face. The stream the app asked the browser for is
      // the camera, wherever it is drawn.
      final js = detector();
      expect(
        js,
        contains('navigator.mediaDevices'),
        reason:
            'the page\'s own camera request is not being watched, so a '
            'preview this script cannot reach means a silent sitting',
      );
      expect(
        js,
        contains('getUserMedia'),
        reason:
            'the camera is opened anywhere but getUserMedia - or the hook '
            'was never installed on it',
      );
      expect(
        js,
        contains('watchPageCameras();'),
        reason:
            'the interception exists but is never installed at load time, '
            'which is the only moment before Flutter opens a lens',
      );
      expect(
        js,
        contains('function capturedVideo'),
        reason:
            'a captured stream with no element of its own can never be '
            'sampled, so the fallback finds a camera it cannot read',
      );
      expect(
        js,
        contains('video = fallback || capturedVideo();'),
        reason:
            'the fallback is not reached when the document has no live '
            'preview, which is exactly the case it exists for',
      );
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
