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

  setUp(() {
    guards = _FakeWebGuards();
    seen.clear();
  });

  WebExamGuard newGuard({
    Duration grace = Duration.zero,
    DateTime Function()? clock,
  }) =>
      WebExamGuard(
        guards: guards,
        onViolation: seen.add,
        startupGrace: grace,
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

    test('blur and a fullscreen exit are strikes as well', () async {
      final guard = newGuard();
      addTearDown(guard.stop);
      await guard.start();

      guards.emit(WebGuardEvent.windowBlurred);
      guards.emit(WebGuardEvent.fullscreenExited);
      await pumpEventQueue();

      expect(seen, <WebGuardEvent>[
        WebGuardEvent.windowBlurred,
        WebGuardEvent.fullscreenExited,
      ]);
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

  void emit(WebGuardEvent event) => controller.add(event);

  @override
  bool get isSupported => true;

  @override
  bool get isFullscreen => inFullscreen;

  @override
  Stream<WebGuardEvent> get events => controller.stream;

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
  Future<void> submitExam(String submissionId) async {}

  @override
  Future<void> markDisqualified(String submissionId) async {}
}
