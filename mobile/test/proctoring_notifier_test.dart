import 'dart:typed_data';

import 'package:exam_proctor/core/services/mediapipe_proctoring_service.dart';
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
}

/// Builds a notifier wired to fakes. The uploader fails loudly: with no
/// snapshot source attached, the notifier must never try to upload evidence.
ProctoringNotifier _notifier({
  required ProctoringRepository proctoringRepo,
  ExamRepository? examRepo,
  void Function()? onForceExit,
  Duration audioNoiseSustain = const Duration(seconds: 2),
}) {
  return ProctoringNotifier(
    submissionId: 'sub-1',
    proctoringRepo: proctoringRepo,
    examRepo: examRepo ?? _RecordingExamRepository(),
    engine: MediaPipeProctoringService(),
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
  Future<void> submitExam(String submissionId) async {}

  @override
  Future<void> markDisqualified(String submissionId) async {
    disqualified.add(submissionId);
  }
}
