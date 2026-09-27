import 'dart:async';
import 'dart:typed_data';

import 'package:exam_proctor/core/services/mediapipe_proctoring_service.dart';
import 'package:exam_proctor/core/services/web_exam_guard.dart';
import 'package:exam_proctor/core/services/web_guards.dart';
import 'package:exam_proctor/features/exam/domain/entities/exam.dart';
import 'package:exam_proctor/features/exam/domain/entities/question.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/exam/domain/repositories/exam_repository.dart';
import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
import 'package:exam_proctor/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:exam_proctor/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// The browser guard rules, driven through a fake [WebGuards]: which events
/// become strikes, when they are ignored, and what `stop()` has to undo.
///
/// The DOM half (`web_guards_web.dart`) only exists in a web build — it is
/// type-checked by `dart analyze` and compiled by the web build, not by these
/// VM tests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeWebGuards guards;
  final seen = <WebGuardEvent>[];
  final fullscreen = <String>[];

  setUp(() {
    guards = _FakeWebGuards();
    seen.clear();
    fullscreen.clear();
  });

  WebExamGuard newGuard({
    Duration grace = Duration.zero,
    Duration fullscreenGrace = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) =>
      WebExamGuard(
        guards: guards,
        onViolation: seen.add,
        onFullscreenExitPending: () => fullscreen.add('pending'),
        onFullscreenRestored: () => fullscreen.add('restored'),
        startupGrace: grace,
        fullscreenGrace: fullscreenGrace,
        clock: clock,
      );

  group('browser events become strikes', () {
    test('a tab switch reaches the notifier as app_minimized', () async {
      final repo = _RecordingProctoringRepository();
      final notifier = ProctoringNotifier(
        submissionId: 'sub-1',
        proctoringRepo: repo,
        examRepo: _StubExamRepository(),
        engine: MediaPipeProctoringService(),
        onForceExit: () {},
        uploadSnapshot: ({
          required String submissionId,
          required String actionType,
          required Uint8List bytes,
        }) async =>
            fail('no snapshot source is attached in these tests'),
      );
      addTearDown(notifier.dispose);

      final guard = WebExamGuard(
        guards: guards,
        onViolation: (_) => notifier.reportAppMinimized(),
        startupGrace: Duration.zero,
      );
      addTearDown(guard.stop);

      expect(await guard.start(), isTrue, reason: 'fullscreen engaged');
      guards.emit(WebGuardEvent.tabHidden);
      await pumpEventQueue();

      // One entry point for every "left the exam" signal, so the strike, the
      // overlay and the RPC payload match a mobile minimize.
      expect(repo.violations.single.type.dbValue, 'app_minimized');
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.showViolationOverlay, isTrue);
    });

    test('a window blur is a strike straight away, a fullscreen exit is not',
        () async {
      final guard = newGuard();
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.windowBlurred);
      guards.emit(WebGuardEvent.fullscreenExited);
      await pumpEventQueue();

      // The blur is logged immediately; the fullscreen exit only opens the
      // countdown - the student is not penalised for a recoverable slip.
      expect(seen, <WebGuardEvent>[WebGuardEvent.windowBlurred]);
      expect(fullscreen, <String>['pending']);
      expect(guard.fullscreenExitPending, isTrue);
      expect(guard.fullscreenExitDeadline, isNotNull);
    });

    test('a fullscreen exit that runs out becomes one strike', () async {
      final guard = newGuard();
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.fullscreenExited);
      await pumpEventQueue();
      expect(seen, isEmpty);

      // What the exam page does when its visible countdown hits zero.
      guard.expireFullscreenGrace();
      guard.expireFullscreenGrace(); // racing the guard's own timer: still one
      await pumpEventQueue();

      expect(seen, <WebGuardEvent>[WebGuardEvent.fullscreenExited]);
      expect(guard.fullscreenExitPending, isFalse);
      expect(guard.fullscreenExitDeadline, isNull);
    });

    test('the guard\'s own timer expires the window without the page',
        () async {
      final guard = newGuard(fullscreenGrace: const Duration(milliseconds: 30));
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.fullscreenExited);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(seen, <WebGuardEvent>[WebGuardEvent.fullscreenExited]);
    });

    test('coming back to fullscreen inside the window cancels it', () async {
      final guard = newGuard();
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.fullscreenExited);
      await pumpEventQueue();
      expect(fullscreen, <String>['pending']);

      guards.emit(WebGuardEvent.fullscreenEntered);
      await pumpEventQueue();

      expect(fullscreen, <String>['pending', 'restored']);
      expect(guard.fullscreenExitPending, isFalse);
      expect(seen, isEmpty, reason: 'nothing was logged');
    });

    test('reassertFullscreen restarts the window when the page comes back',
        () async {
      final guard = newGuard();
      addTearDown(guard.stop);
      await guard.start();
      expect(guard.fullscreenEnteredThisSession, isTrue);

      // The page was backgrounded and is not in fullscreen any more, but no
      // `fullscreenchange` reached us (the browser was not looking).
      guards.inFullscreen = false;
      guard.reassertFullscreen();

      expect(guard.fullscreenExitPending, isTrue);
      expect(fullscreen, <String>['pending']);
    });

    test('a session that ends mid-countdown logs nothing', () async {
      final guard = newGuard();
      await guard.start();

      guards.emit(WebGuardEvent.fullscreenExited);
      await pumpEventQueue();
      expect(guard.fullscreenExitPending, isTrue);

      await guard.stop();
      expect(guard.fullscreenExitPending, isFalse);
      expect(seen, isEmpty);
    });

    test('start() asks for fullscreen once, the prompt can ask again',
        () async {
      final guard = newGuard();
      addTearDown(guard.stop);

      expect(await guard.start(), isTrue);
      expect(guards.enterCalls, 1);

      expect(await guard.requestFullscreen(), isTrue);
      expect(guards.enterCalls, 2);
    });

    test('a refused automatic attempt is reported, the tap retries', () async {
      guards.fullscreenGranted = false; // no user gesture yet
      final guard = newGuard();
      addTearDown(guard.stop);

      expect(await guard.start(), isFalse);
      expect(guard.fullscreenEnteredThisSession, isFalse);

      guards.fullscreenGranted = true;
      expect(await guard.requestFullscreen(), isTrue);
      expect(guard.fullscreenEnteredThisSession, isTrue);
    });


    test('the startup grace swallows the first seconds', () async {
      var now = DateTime(2026, 1, 1, 9);
      final guard = newGuard(
        grace: const Duration(seconds: 5),
        clock: () => now,
      );
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.windowBlurred); // e.g. the camera permission
      await pumpEventQueue();
      expect(seen, isEmpty);

      now = now.add(const Duration(seconds: 6));
      guards.emit(WebGuardEvent.tabHidden);
      await pumpEventQueue();
      expect(seen, <WebGuardEvent>[WebGuardEvent.tabHidden]);
    });

    test('stop() releases fullscreen and stops reporting', () async {
      final guard = newGuard();
      await guard.start();
      guards.emit(WebGuardEvent.tabHidden);
      await pumpEventQueue();
      expect(seen, hasLength(1));

      await guard.stop();
      expect(guards.exitCalls, 1);
      expect(guards.disposed, isTrue);

      guards.emit(WebGuardEvent.tabHidden);
      await pumpEventQueue();
      expect(seen, hasLength(1), reason: 'a finished exam stops counting');

      await guard.stop(); // idempotent
      expect(guards.exitCalls, 1);
    });
  });

  group('exam lockdown', () {
    test('start() arms the lockdown before asking for fullscreen', () async {
      final guard = newGuard();
      addTearDown(guard.stop);

      expect(guards.lockdownActive, isFalse);
      expect(await guard.start(), isTrue);
      expect(guards.lockdownStarts, 1);
      expect(guards.lockdownActive, isTrue);
      expect(guards.enterCalls, 1);
    });

    test('a blocked copy is a strike even inside the startup grace', () async {
      // The bootstrap script blocks attempts made *before* Flutter boots, and
      // startExamLockdown() replays them - i.e. inside the grace window. A copy
      // cannot be caused by the camera prompt or the fullscreen transition, so
      // unlike a blur it is never filtered.
      final guard = newGuard(grace: const Duration(seconds: 5));
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.copyBlocked);
      guards.emit(WebGuardEvent.windowBlurred); // start-up noise: ignored
      await pumpEventQueue();

      expect(seen, <WebGuardEvent>[WebGuardEvent.copyBlocked]);
    });

    test('every lockdown event reaches onViolation as itself', () async {
      final guard = newGuard();
      addTearDown(guard.stop);
      await guard.start();

      for (final event in <WebGuardEvent>[
        WebGuardEvent.cutBlocked,
        WebGuardEvent.pasteBlocked,
        WebGuardEvent.contextMenuBlocked,
        WebGuardEvent.devtoolsDetected,
      ]) {
        guards.emit(event);
      }
      await pumpEventQueue();

      // Passed through unchanged: the page, not the guard, decides which
      // violation each one costs (copy/cut/paste share `copy_paste_attempt`).
      expect(seen, <WebGuardEvent>[
        WebGuardEvent.cutBlocked,
        WebGuardEvent.pasteBlocked,
        WebGuardEvent.contextMenuBlocked,
        WebGuardEvent.devtoolsDetected,
      ]);
    });

    test('stop() releases the lockdown, and only once', () async {
      final guard = newGuard();
      await guard.start();
      expect(guards.lockdownActive, isTrue);

      await guard.stop();
      expect(guards.lockdownStops, 1);
      expect(
        guards.lockdownActive,
        isFalse,
        reason: 'a finished exam must not keep the browser blocked',
      );

      await guard.stop(); // idempotent
      expect(guards.lockdownStops, 1);
    });
  });

  group('non-web platforms', () {
    test('report "not supported" and never touch fullscreen', () async {
      // On the VM the factory hands back UnsupportedWebGuards — exactly what
      // Android/iOS/desktop get, since Android has lock task instead.
      final platform = WebGuards();
      expect(platform.isSupported, isFalse);

      var violations = 0;
      final guard = WebExamGuard(
        guards: platform,
        onViolation: (_) => violations++,
        startupGrace: Duration.zero,
      );

      expect(await guard.start(), isFalse);
      expect(guard.isFullscreen, isFalse);
      await guard.stop();
      expect(violations, 0);
    });
  });
}

/// Controllable stand-in for the DOM implementation.
class _FakeWebGuards implements WebGuards {
  final StreamController<WebGuardEvent> controller =
      StreamController<WebGuardEvent>.broadcast();

  bool fullscreenGranted = true;
  bool inFullscreen = false;
  int enterCalls = 0;
  int exitCalls = 0;
  bool disposed = false;

  /// The DOM lockdown: armed for the length of one attempt, and it has to be
  /// released again or the student's browser stays blocked ([stopExamLockdown]).
  bool lockdownActive = false;
  int lockdownStarts = 0;
  int lockdownStops = 0;

  void emit(WebGuardEvent event) => controller.add(event);

  @override
  bool get isSupported => true;

  @override
  bool get isFullscreen => inFullscreen;

  @override
  Stream<WebGuardEvent> get events => controller.stream;

  @override
  bool get supportsExamLockdown => true;

  @override
  void startExamLockdown() {
    lockdownStarts++;
    lockdownActive = true;
  }

  @override
  void stopExamLockdown() {
    lockdownStops++;
    lockdownActive = false;
  }

  @override
  Future<bool> enterFullscreen() async {
    enterCalls++;
    inFullscreen = fullscreenGranted;
    return inFullscreen;
  }

  @override
  Future<void> exitFullscreen() async {
    exitCalls++;
    inFullscreen = false;
  }

  /// Deliberately keeps the stream open, so the "ignored after stop" rule is
  /// tested through the guard's own state rather than the fake's plumbing.
  @override
  void dispose() {
    disposed = true;
  }
}

class _RecordingProctoringRepository implements ProctoringRepository {
  final List<Violation> violations = <Violation>[];

  @override
  Future<({int warningCount, bool disqualified})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async {
    violations.add(violation);
    return (warningCount: violations.length, disqualified: false);
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}

class _StubExamRepository implements ExamRepository {
  @override
  Future<List<Exam>> getPublishedExams() async => <Exam>[];

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError('not used in these tests');

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {}

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {}

  @override
  Future<void> submitExam(String submissionId) async {}

  @override
  Future<void> markDisqualified(String submissionId) async {}
}
