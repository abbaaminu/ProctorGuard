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

      expect(uploads.first, 'sub-1/no_face/4');
      expect(proctoringRepo.violations, hasLength(1)); // notifier debounce
      final logged = proctoringRepo.violations.single;
      expect(logged.type, ViolationType.noFace);
      expect(
        logged.snapshotUrl,
        'https://cdn.test/proctor-snapshots/sub-1/no_face.jpg',
      );
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

      expect(proctoringRepo.violations, hasLength(1));
      expect(proctoringRepo.violations.single.snapshotUrl, isNull);
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
  Future<void> submitExam(String submissionId) async {}

  @override
  Future<void> markDisqualified(String submissionId) async {}
}
