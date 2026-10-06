import 'dart:typed_data';

import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the `--dart-define=MOCK_CAMERA=true` path and the violation-snapshot
/// upload wiring. Neither needs a device: the simulated feed drives the
/// notifier, and the Storage upload is injected as a fake.
void main() {
  // The notifier attaches a WidgetsBindingObserver on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mock camera feed', () {
    test('alternates no_face / looking_away on its interval', () async {
      final engine = MediaPipeProctoringService(
        mockCamera: true,
        mockInterval: const Duration(milliseconds: 20),
      );
      addTearDown(engine.dispose);

      final seen = <GazeSignal>[];
      final sub = engine.signals.listen(seen.add);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();

      expect(engine.isMockFeedActive, isTrue);
      expect(seen.take(4).toList(), <GazeSignal>[
        GazeSignal.noFace,
        GazeSignal.lookingAway,
        GazeSignal.noFace,
        GazeSignal.lookingAway,
      ]);
    });

    test('is off by default (no dart-define, no timer)', () {
      final engine = MediaPipeProctoringService();
      addTearDown(engine.dispose);

      expect(engine.isMockFeedActive, isFalse);
      expect(engine.mockCamera, isFalse);
      // Documented default cadence of the simulated feed.
      expect(engine.mockInterval, const Duration(seconds: 12));
    });
  });

  group('violation snapshots', () {
    test('uploads a frame and attaches its URL to the logged violation',
        () async {
      final proctoringRepo = _RecordingProctoringRepository();
      final engine = MediaPipeProctoringService(
        mockCamera: true,
        mockInterval: const Duration(milliseconds: 20),
      );

      final uploads = <String>[];
      final notifier = ProctoringNotifier(
        submissionId: 'sub-1',
        proctoringRepo: proctoringRepo,
        examRepo: _StubExamRepository(),
        engine: engine,
        onForceExit: () {},
        uploadSnapshot: ({
          required String submissionId,
          required String actionType,
          required Uint8List bytes,
        }) async {
          uploads.add('$submissionId/$actionType/${bytes.length}');
          return 'https://cdn.test/proctor-snapshots/$submissionId/$actionType.jpg';
        },
      );
      addTearDown(notifier.dispose);
      notifier.attachSnapshotSource(
        () async => Uint8List.fromList(<int>[1, 2, 3, 4]),
      );

      await Future<void>.delayed(const Duration(milliseconds: 250));

      // The simulated feed alternates no_face / looking_away every 20 ms and the
      // notifier's debounce is *per type* (2 s each, see `_lastLoggedAt`): inside
      // this window that is one violation of each kind, not one in total. A single
      // shared stamp used to swallow whichever signal arrived second.
      expect(
        proctoringRepo.violations.map((violation) => violation.type).toList(),
        <ViolationType>[ViolationType.noFace, ViolationType.lookingAway],
      );

      // The frame captured for the first one travels with it.
      final logged = proctoringRepo.violations.first;
      expect(logged.type, ViolationType.noFace);
      expect(
        logged.snapshotUrl,
        'https://cdn.test/proctor-snapshots/sub-1/no_face.jpg',
      );
      // One upload per violation, named after the violation's action_type.
      expect(uploads.toSet(), <String>{
        'sub-1/no_face/4',
        'sub-1/looking_away/4',
      });
    });

    test('logs the violation (without a URL) when capture yields nothing',
        () async {
      final proctoringRepo = _RecordingProctoringRepository();
      final engine = MediaPipeProctoringService(
        mockCamera: true,
        mockInterval: const Duration(milliseconds: 20),
      );

      final notifier = ProctoringNotifier(
        submissionId: 'sub-2',
        proctoringRepo: proctoringRepo,
        examRepo: _StubExamRepository(),
        engine: engine,
        onForceExit: () {},
        uploadSnapshot: ({
          required String submissionId,
          required String actionType,
          required Uint8List bytes,
        }) async =>
            fail('nothing should be uploaded when capture returns null'),
      );
      addTearDown(notifier.dispose);
      notifier.attachSnapshotSource(() async => null);

      await Future<void>.delayed(const Duration(milliseconds: 250));

      // Same alternating feed, same two violations - and neither carries a URL,
      // because there was no frame to upload. The rows are still written: the
      // strike happened whether or not the evidence could be attached to it.
      expect(
        proctoringRepo.violations.map((violation) => violation.type).toList(),
        <ViolationType>[ViolationType.noFace, ViolationType.lookingAway],
      );
      expect(
        proctoringRepo.violations.every(
          (violation) => violation.snapshotUrl == null,
        ),
        isTrue,
      );
    });
  });
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
  Future<ExamSubmitResult> submitExam(String submissionId) async =>
      const ExamSubmitResult(status: SubmissionStatus.submitted);

  @override
  Future<void> markDisqualified(String submissionId) async {}
}
