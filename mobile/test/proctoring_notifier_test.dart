import 'dart:async';
import 'dart:typed_data';

import 'package:exam_proctor/core/services/mediapipe_proctoring_service.dart';
import 'package:exam_proctor/core/services/offline_sync_service.dart';
import 'package:exam_proctor/features/exam/domain/entities/exam.dart';
import 'package:exam_proctor/features/exam/domain/entities/question.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/exam/domain/repositories/exam_repository.dart';
import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
import 'package:exam_proctor/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:exam_proctor/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Anti-cheating inputs that do not come from the camera: the kiosk escape
/// callback (`lock_task_channel`), the audio-noise hook, and the 3-strike
/// escalation they feed into. Everything is driven through fakes — no device,
/// no Supabase.
void main() {
  // The notifier attaches a WidgetsBindingObserver on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('kiosk escape', () {
    test('a lock task escape is logged as app_minimized', () async {
      final repo = _RecordingProctoringRepository();
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(repo.violations.single.type, ViolationType.appMinimized);
      expect(repo.violations.single.type.dbValue, 'app_minimized');
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.lastViolation, ViolationType.appMinimized);
      expect(notifier.state.showViolationOverlay, isTrue);
    });
  });

  group('audio noise hook', () {
    test('a single loud blip is not a strike', () async {
      final repo = _RecordingProctoringRepository();
      final notifier = _notifier(
        proctoringRepo: repo,
        audioNoiseSustain: const Duration(milliseconds: 60),
      );
      addTearDown(notifier.dispose);

      notifier.reportAudioLevel(-70); // quiet
      notifier.reportAudioLevel(-10); // blip: opens the window
      notifier.reportAudioLevel(-70); // hush again: window resets
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();

      expect(repo.violations, isEmpty);
      expect(notifier.state.warningCount, 0);
    });

    test('sustained noise logs audio_noise once', () async {
      final repo = _RecordingProctoringRepository();
      final notifier = _notifier(
        proctoringRepo: repo,
        audioNoiseSustain: const Duration(milliseconds: 60),
      );
      addTearDown(notifier.dispose);

      notifier.reportAudioLevel(-10);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      notifier.reportAudioLevel(-10); // still loud, past the sustain window
      await pumpEventQueue();

      expect(repo.violations.single.type, ViolationType.audioNoise);
      expect(repo.violations.single.type.dbValue, 'audio_noise');
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.showViolationOverlay, isTrue);
    });
  });

  group('3-strike escalation', () {
    test('a server-side disqualification ends the session and forces exit',
        () async {
      final repo = _RecordingProctoringRepository(disqualifyAfter: 1);
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(notifier.state.disqualified, isTrue);
      expect(notifier.state.showViolationOverlay, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);

      // Signals arriving after the lockout are dropped, not logged again.
      notifier.reportAudioNoise();
      notifier.reportAppMinimized();
      await pumpEventQueue();
      expect(repo.violations, hasLength(1));

      // ...and the final lockout screen cannot be dismissed, unlike a warning.
      notifier.dismissOverlay();
      expect(notifier.state.showViolationOverlay, isTrue);
    });

    test('the third strike auto-disqualifies', () async {
      // Longer than the notifier's 2s debounce window, so each strike lands.
      const gap = Duration(milliseconds: 2200);
      final repo = _RecordingProctoringRepository();
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized(); // strike 1: leaving the exam surface
      await Future<void>.delayed(gap);
      notifier.reportAudioNoise(); // strike 2: background noise
      await Future<void>.delayed(gap);
      notifier.reportAppMinimized(); // strike 3: disqualified
      await pumpEventQueue();

      expect(
        repo.violations.map((violation) => violation.type.dbValue).toList(),
        <String>['app_minimized', 'audio_noise', 'app_minimized'],
      );
      expect(notifier.state.warningCount, 3);
      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);
    });
  });

  group('camera gate', () {
    test('gaze signals are ignored while the camera feed is offline',
        () async {
      final repo = _RecordingProctoringRepository();
      final engine = MediaPipeProctoringService(
        mockCamera: true,
        mockInterval: const Duration(milliseconds: 20),
      );
      final notifier = _notifier(proctoringRepo: repo, engine: engine);
      addTearDown(notifier.dispose);

      notifier.setCameraActive(false);
      expect(notifier.state.cameraPaused, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(repo.violations, isEmpty);
      expect(notifier.state.warningCount, 0);

      notifier.setCameraActive(true);
      expect(notifier.state.cameraPaused, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(repo.violations, isNotEmpty);
    });
  });

  group('violation outbox (requirement 4)', () {
    test('a violation that could not be delivered still counts locally',
        () async {
      final outbox = _FakeOutbox(reachable: false);
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      // The strike is shown and counted even though the row is only queued on the
      // device: losing the warning UI because the network is down would be worse
      // than a count that is briefly local.
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.showViolationOverlay, isTrue);
      expect(outbox.logged, hasLength(1));
      // Every event carries an id, which is what makes the retry idempotent.
      expect(outbox.logged.single.clientEventId, isNotNull);
    });

    test('a ruling delivered late raises the count but never lowers it',
        () async {
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();
      expect(notifier.state.warningCount, 1);

      outbox.emitRuling(warningCount: 2);
      await pumpEventQueue();
      expect(notifier.state.warningCount, 2);

      // A deferred ruling can be older than a live one that already arrived: it
      // must not walk the ladder back down.
      outbox.emitRuling(warningCount: 1);
      await pumpEventQueue();
      expect(notifier.state.warningCount, 2);
    });

    test('a third strike delivered late ends the attempt', () async {
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final outbox = _FakeOutbox();

      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        examRepo: examRepo,
        outbox: outbox,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      outbox.emitRuling(warningCount: 3, disqualified: true);
      await pumpEventQueue();

      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);
    });

    test('a ruling for another session is ignored', () async {
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      outbox.emitRuling(
        submissionId: 'sub-9',
        warningCount: 3,
        disqualified: true,
      );
      await pumpEventQueue();

      expect(notifier.state.disqualified, isFalse);
      expect(notifier.state.warningCount, 0);
    });
  });

  group('browser lockdown + device signals', () {
    test('each signal keeps its own action_type on the server', () async {
      // The enterprise set is six *different* pieces of evidence: a clipboard
      // attempt, a suppressed context menu, a developer-tools panel, a second
      // screen, a substituted camera and an idle device. All six enter through the
      // same `report*` entry points the browser guard and the integrity poll call,
      // and each has to reach the log with its own value.
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      notifier.reportRightClickBlocked();
      await pumpEventQueue();
      notifier.reportDevtoolsDetected();
      await pumpEventQueue();
      notifier.reportSecondaryDisplayDetected();
      await pumpEventQueue();
      notifier.reportVirtualCameraDetected();
      await pumpEventQueue();
      notifier.reportIdleAfk();
      await pumpEventQueue();

      expect(
        repo.violations.map((violation) => violation.type.dbValue).toList(),
        <String>[
          'copy_paste_attempt',
          'right_click_blocked',
          'devtools_detected',
          'secondary_display_detected',
          'virtual_camera_detected',
          'idle_afk',
        ],
      );
      expect(notifier.state.warningCount, 6);
      expect(notifier.state.lastViolation, ViolationType.idleAfk);
      expect(notifier.state.showViolationOverlay, isTrue);
    });

    test('the debounce is per type, not per session', () async {
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      // Three *different* signals inside one 2s debounce window: all three are
      // evidence. One shared stamp (the first shape of this) would have swallowed
      // whichever arrived second.
      notifier.reportCopyPasteAttempt();
      notifier.reportRightClickBlocked();
      notifier.reportIdleAfk();
      await pumpEventQueue();
      expect(repo.violations, hasLength(3));

      // A repeat of a type already logged inside the window is the same event...
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      expect(repo.violations, hasLength(3));

      // ...while the same type after the window is a new one.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      expect(repo.violations, hasLength(4));
    });

    test('lockdown strikes count towards the same 3-strike rule', () async {
      final repo = _RecordingProctoringRepository();
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      // Three different types, so what separates them is the evidence, not the
      // debounce: the escalation rule is the same one the camera signals feed.
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      notifier.reportRightClickBlocked();
      await pumpEventQueue();
      expect(notifier.state.disqualified, isFalse);

      notifier.reportDevtoolsDetected();
      await pumpEventQueue();

      expect(notifier.state.warningCount, 3);
      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);
    });
  });
}

/// Builds a notifier wired to fakes. The uploader fails loudly: with no
/// snapshot source attached, the notifier must never try to upload evidence.
ProctoringNotifier _notifier({
  required ProctoringRepository proctoringRepo,
  ExamRepository? examRepo,
  MediaPipeProctoringService? engine,
  ViolationOutbox? outbox,
  void Function()? onForceExit,
  Duration audioNoiseSustain = const Duration(seconds: 2),
}) {
  return ProctoringNotifier(
    submissionId: 'sub-1',
    proctoringRepo: proctoringRepo,
    examRepo: examRepo ?? _RecordingExamRepository(),
    engine: engine ?? MediaPipeProctoringService(),
    outbox: outbox,
    onForceExit: onForceExit ?? () {},
    uploadSnapshot: ({
      required String submissionId,
      required String actionType,
      required Uint8List bytes,
    }) async =>
        fail('no snapshot source is attached in these tests'),
    audioNoiseSustain: audioNoiseSustain,
  );
}

/// A [ViolationOutbox] a test can drive: [reachable] decides whether a live
/// delivery succeeds, and [emitRuling] is the "the queue delivered it later"
/// signal the notifier has to reconcile (see the requirement-4 group).
class _FakeOutbox implements ViolationOutbox {
  _FakeOutbox({this.reachable = true});

  final bool reachable;
  final List<Violation> logged = <Violation>[];
  final StreamController<ViolationRuling> _rulings =
      StreamController<ViolationRuling>.broadcast();

  @override
  Future<ViolationRuling?> log({
    required String submissionId,
    required Violation violation,
  }) async {
    logged.add(violation);
    if (!reachable) return null; // queued on the device, retried later
    return ViolationRuling(
      submissionId: submissionId,
      violation: violation,
      warningCount: logged.length,
      disqualified: false,
    );
  }

  void emitRuling({
    String submissionId = 'sub-1',
    required int warningCount,
    bool disqualified = false,
  }) =>
      _rulings.add(ViolationRuling(
        submissionId: submissionId,
        violation: Violation(
          type: ViolationType.appMinimized,
          timestamp: DateTime.utc(2026, 1, 1),
        ),
        warningCount: warningCount,
        disqualified: disqualified,
      ));

  @override
  Stream<ViolationRuling> get deferredRulings => _rulings.stream;
}

/// Stands in for `supabase.rpc('register_violation', ...)`: the server owns the
/// strike count and the threshold (3), which is what the notifier reconciles
/// its local count against.
class _RecordingProctoringRepository implements ProctoringRepository {
  _RecordingProctoringRepository({this.disqualifyAfter = 3});

  final int disqualifyAfter;
  final List<Violation> violations = <Violation>[];

  @override
  Future<({int warningCount, bool disqualified})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async {
    violations.add(violation);
    return (
      warningCount: violations.length,
      disqualified: violations.length >= disqualifyAfter,
    );
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}

class _RecordingExamRepository implements ExamRepository {
  final List<String> disqualified = <String>[];

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
  Future<void> markDisqualified(String submissionId) async {
    disqualified.add(submissionId);
  }
}
