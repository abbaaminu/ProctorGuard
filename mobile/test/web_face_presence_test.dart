import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart'
    show GazeSignal;
import 'package:proctorguard/core/services/web_face_presence.dart';
import 'package:proctorguard/core/services/web_face_signal_source.dart';

/// The judgement half of the browser's face bridge.
///
/// A browser cannot run the on-device engine (no ML Kit, and `camera_web` offers
/// no `CameraImage` stream - see [WebFaceSignalSource]), so a host page does the
/// *detecting* and [WebFacePresenceMonitor] does the *judging*: which detections
/// are sustained enough to be a violation. Everything here runs on the Dart VM
/// with an injected clock and a fake source, which is exactly why the rules live
/// in this class rather than in the web-only source: `flutter test` cannot load
/// `dart:js_interop` code, and a strike ladder must not depend on a browser.
///
/// The rules are the ones `MediaPipeProctoringService` applies, with elapsed time
/// standing in for consecutive frames (a page's detector has no guaranteed frame
/// rate).
void main() {
  late _FakeFaceSource source;
  late DateTime now;
  late List<GazeSignal> signals;
  late WebFacePresenceMonitor monitor;

  /// Broadcast delivery is asynchronous; one trip round the event loop is enough
  /// for every `add` made so far to reach the listener.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  /// One detection at the current instant.
  void report(String message) => monitor.handleMessage(message);

  /// One detection far enough after the previous one that the condition has
  /// demonstrably held: the sustain window plus a margin, so the tests do not
  /// depend on the exact boundary.
  void hold(String message) {
    now = now.add(monitor.sustain + const Duration(milliseconds: 100));
    report(message);
  }

  /// Starts an episode now and keeps it going long enough to be reported: the
  /// first detection is what opens the window, the second is what fills it.
  void sustain(String message) {
    report(message);
    hold(message);
  }

  /// The monitor under test, with the start-up grace removed: these tests are
  /// about the episode rules, and a later group covers the grace itself.
  WebFacePresenceMonitor buildMonitor({
    Duration startupGrace = Duration.zero,
    Duration multipleFacesCooldown = const Duration(seconds: 30),
  }) {
    final built = WebFacePresenceMonitor(
      source: source,
      clock: () => now,
      startupGrace: startupGrace,
      multipleFacesCooldown: multipleFacesCooldown,
    )..start(at: now);
    built.signals.listen(signals.add);
    return built;
  }

  setUp(() {
    source = _FakeFaceSource();
    now = DateTime.utc(2026, 6, 1, 9);
    signals = <GazeSignal>[];
    monitor = buildMonitor();
  });

  tearDown(() => monitor.dispose());

  group('a second person in frame', () {
    test('is reported at once, then latched until the student has been alone',
        () async {
      report(WebFaceMessages.multipleFaces);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.multipleFaces],
        reason: 'two faces need no measuring to become evidence',
      );

      hold(WebFaceMessages.multipleFaces);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.multipleFaces],
        reason: 'the doorbell is not rung again for the same visitor',
      );

      // The student faces the screen again, but the detector still sees two
      // people - so the episode has not ended and nothing new is reported.
      now = now.add(const Duration(seconds: 10));
      report(WebFaceMessages.centered);
      hold(WebFaceMessages.multipleFaces);
      await flush();
      expect(
        signals.where((signal) => signal == GazeSignal.multipleFaces),
        hasLength(1),
        reason: 'ten seconds is not thirty',
      );

      // Alone for longer than the cooldown: the latch ends, and the *next*
      // second person is a fresh episode.
      now = now.add(const Duration(seconds: 31));
      report(WebFaceMessages.centered);
      hold(WebFaceMessages.multipleFaces);
      await flush();
      expect(
        signals.where((signal) => signal == GazeSignal.multipleFaces),
        hasLength(2),
      );
    });

    test('a flicker of a second face does not reopen the episode', () async {
      // A detector at the edge of its training data can alternate between one
      // and two faces. Each message pushes the re-arm out, so a flickering
      // exam never re-arms - and never re-strikes either.
      report(WebFaceMessages.multipleFaces);
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(seconds: 10));
        report(WebFaceMessages.multipleFaces);
      }
      await flush();
      expect(
        signals.where((signal) => signal == GazeSignal.multipleFaces),
        hasLength(1),
      );
    });
  });

  group('measured head pose', () {
    test("is judged with the engine's tolerances", () async {
      sustain('pose:45,-5');
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.lookingAway],
        reason: 'yaw well past the 28° tolerance',
      );

      report('pose:0,0');
      await flush();
      expect(signals.last, GazeSignal.centered);

      sustain('pose:20,45');
      await flush();
      expect(
        signals.last,
        GazeSignal.lookingAway,
        reason: 'pitch past 30° even with the yaw inside its tolerance',
      );

      // Case and padding are the host's business: the monitor reads the numbers.
      report(' POSE: -10 , 5 ');
      await flush();
      expect(
        signals.last,
        GazeSignal.centered,
        reason: 'inside both tolerances, whatever the spelling',
      );
    });

    test('an angle the detector cannot mean is clamped, not discarded',
        () async {
      // A detector reporting 400° is describing a head that is definitely not
      // facing the screen; turning the video off sideways is not "no evidence".
      sustain('pose:400,0');
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);
    });
  });

  group('messages this app cannot read', () {
    test('are not evidence', () async {
      for (final junk in <String>[
        '',
        '   ',
        'garbage',
        // A verdict from a vocabulary this build does not know.
        'reading',
        // Malformed poses: the numbers are missing, not zero.
        'pose:',
        'pose:1',
        'pose:abc,def',
        'pose:NaN,0',
        'pose:Infinity,-Infinity',
        'pose:10,20,30',
      ]) {
        report(junk);
      }
      await flush();
      expect(signals, isEmpty);
    });

    test('do not end a real episode', () async {
      // Reading a malformed pose as "centred" would quietly close a genuine
      // look-away - which is the one thing a student who is looking away would
      // most like the proctor to believe.
      sustain(WebFaceMessages.lookingAway);
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);

      report('garbage');
      report('pose:abc,def');
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.lookingAway],
        reason: 'nothing was emitted, and no episode was closed',
      );

      hold(WebFaceMessages.lookingAway);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.lookingAway],
        reason: 'still the same episode, so still one strike',
      );
    });
  });

  group('sustained episodes', () {
    test('a glance is not a look away, a held one is', () async {
      report(WebFaceMessages.lookingAway);
      await flush();
      expect(signals, isEmpty, reason: 'one detection is a glance');

      hold(WebFaceMessages.lookingAway);
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);

      // The head is still turned: the same episode, already reported. Without
      // the flag a student reading a question off-screen would collect a strike
      // per detection.
      hold(WebFaceMessages.lookingAway);
      hold(WebFaceMessages.lookingAway);
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);
    });

    test('a centred face ends the episode and re-arms it', () async {
      sustain(WebFaceMessages.lookingAway);
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);

      report(WebFaceMessages.centered);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.lookingAway, GazeSignal.centered],
        reason: 'centred closes the episode and is itself observable',
      );

      hold(WebFaceMessages.lookingAway);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.lookingAway, GazeSignal.centered],
        reason: 'a single detection after centring is only a glance',
      );

      hold(WebFaceMessages.lookingAway);
      await flush();
      expect(
        signals,
        <GazeSignal>[
          GazeSignal.lookingAway,
          GazeSignal.centered,
          GazeSignal.lookingAway,
        ],
        reason: 'a later look away is a new episode, not a repeat',
      );
    });

    test('an absent face is its own signal, reported once per episode',
        () async {
      sustain(WebFaceMessages.noFace);
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.noFace]);

      hold(WebFaceMessages.noFace);
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.noFace], reason: 'one episode');

      report(WebFaceMessages.centered);
      sustain(WebFaceMessages.noFace);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.noFace, GazeSignal.centered, GazeSignal.noFace],
      );
    });

    test('a turned head ends the absence, an absence ends the turn', () async {
      // Both mean "not looking at the screen", but they are different evidence,
      // and either one proves the other is over - so a student who leaves and
      // then returns and turns is reported for both.
      sustain(WebFaceMessages.noFace);
      sustain(WebFaceMessages.lookingAway);
      await flush();
      expect(
        signals,
        <GazeSignal>[GazeSignal.noFace, GazeSignal.lookingAway],
      );

      report(WebFaceMessages.centered);
      sustain(WebFaceMessages.noFace);
      await flush();
      expect(
        signals,
        <GazeSignal>[
          GazeSignal.noFace,
          GazeSignal.lookingAway,
          GazeSignal.centered,
          GazeSignal.noFace,
        ],
      );
    });

    test('a fast detector cannot stack strikes', () async {
      // A page running at 20 fps calls far more often than the sustain window;
      // what matters is elapsed time, not how many times it said so.
      for (var i = 0; i < 40; i++) {
        now = now.add(const Duration(milliseconds: 50));
        report(WebFaceMessages.lookingAway);
      }
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);
    });
  });

  group('the start-up window', () {
    test('nothing is reported while the student is settling in', () async {
      final gated = buildMonitor(startupGrace: const Duration(seconds: 5));
      addTearDown(gated.dispose);
      final seen = <GazeSignal>[];
      gated.signals.listen(seen.add);

      // A detector that starts with the page, a student adjusting the camera,
      // and a second person walking past the desk *before* the paper opens: none
      // of it is evidence about the exam.
      gated.handleMessage(WebFaceMessages.multipleFaces, at: now);
      gated.handleMessage(
        WebFaceMessages.lookingAway,
        at: now.add(const Duration(seconds: 3)),
      );
      gated.handleMessage(
        WebFaceMessages.lookingAway,
        at: now.add(const Duration(seconds: 4)),
      );
      await flush();
      expect(seen, isEmpty);

      // Past the grace the window opens with the *first* detection after it, so
      // a look-away that was already under way is still measured in full.
      final after = now.add(const Duration(seconds: 6));
      gated.handleMessage(WebFaceMessages.lookingAway, at: after);
      gated.handleMessage(
        WebFaceMessages.lookingAway,
        at: after.add(gated.sustain + const Duration(milliseconds: 100)),
      );
      await flush();
      expect(seen, <GazeSignal>[GazeSignal.lookingAway]);
    });
  });

  group('lifecycle', () {
    test('detections before start are dropped', () async {
      final unstarted = WebFacePresenceMonitor(
        source: source,
        clock: () => now,
        startupGrace: Duration.zero,
      );
      addTearDown(unstarted.dispose);
      final seen = <GazeSignal>[];
      unstarted.signals.listen(seen.add);
      expect(unstarted.isStarted, isFalse);

      unstarted.handleMessage(WebFaceMessages.multipleFaces);
      unstarted.handleMessage(WebFaceMessages.centered);
      await flush();
      expect(
        seen,
        isEmpty,
        reason: 'a face seen before the exam began is not evidence about it',
      );

      unstarted.start(at: now);
      expect(unstarted.isStarted, isTrue);
    });

    test('a second start does not restart the grace window', () async {
      // A retried bootstrap re-runs the session setup; if the second start moved
      // the grace window forward, the student would be unwatched for another
      // five seconds every time the attempt recovered.
      final gated = buildMonitor(startupGrace: const Duration(seconds: 5));
      addTearDown(gated.dispose);
      final seen = <GazeSignal>[];
      gated.signals.listen(seen.add);

      final later = now.add(const Duration(seconds: 10));
      gated.start(at: later);
      gated.handleMessage(WebFaceMessages.multipleFaces, at: later);
      await flush();
      expect(seen, <GazeSignal>[GazeSignal.multipleFaces]);
    });

    test('a detection that arrives through the source is judged the same',
        () async {
      expect(monitor.isSupported, isTrue);
      expect(monitor.source, same(source));

      // The hook hands over whatever the page sent; case and padding are the
      // source's job, the meaning is this class's.
      source.emit('  LOOKING_AWAY  ');
      await flush();
      expect(signals, isEmpty, reason: 'still just a glance');

      now = now.add(monitor.sustain + const Duration(milliseconds: 100));
      source.emit('Looking_Away');
      await flush();
      expect(signals, <GazeSignal>[GazeSignal.lookingAway]);
    });

    test('dispose ends the stream and releases the host hook', () async {
      var done = false;
      final sub = monitor.signals.listen((_) {}, onDone: () => done = true);
      addTearDown(sub.cancel);

      monitor.dispose();
      await flush();
      expect(done, isTrue);
      expect(source.disposes, 1);

      // A late detection - the page's detector firing between the submit and the
      // unload - is not evidence about an attempt that is over.
      monitor.handleMessage(WebFaceMessages.multipleFaces);
      await flush();
      expect(signals, isEmpty);

      monitor.dispose();
      expect(source.disposes, 1, reason: 'dispose is idempotent');
    });
  });
}

/// A host detector with no browser behind it, so the browser bridge's judgement
/// can be exercised on the VM (where `flutter test` and CI run).
class _FakeFaceSource implements WebFaceSignalSource {
  final StreamController<String> controller =
      StreamController<String>.broadcast();

  /// How many times the monitor released the hook; a session that leaves the
  /// global installed is a session a finished page can keep reporting into.
  int disposes = 0;

  void emit(String message) {
    if (!controller.isClosed) controller.add(message);
  }

  @override
  bool get isSupported => true;

  @override
  Stream<String> get messages => controller.stream;

  @override
  void dispose() {
    disposes++;
    if (!controller.isClosed) controller.close();
  }
}

