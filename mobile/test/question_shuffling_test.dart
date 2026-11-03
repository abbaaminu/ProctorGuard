import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/di/providers.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/providers/exam_session_controller.dart';

/// Pins the deterministic shuffle contract so the same submission id always
/// produces the same order, and the shuffle-off path is unchanged.
void main() {
  final questions = <Question>[
    const Question(id: 'a', examId: 'x', questionText: 'Q1'),
    const Question(id: 'b', examId: 'x', questionText: 'Q2'),
    const Question(id: 'c', examId: 'x', questionText: 'Q3'),
    const Question(id: 'd', examId: 'x', questionText: 'Q4'),
    const Question(id: 'e', examId: 'x', questionText: 'Q5'),
  ];

  group('deterministic shuffle', () {
    test('the same submission id produces the same order', () {
      final first = ExamSessionController.shuffleQuestionsForTest(
        questions,
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      );
      // The test always expects the same order from this seed.
      expect(first, hasLength(5));
      // Check stability: second call with same id gives same order.
      final second = ExamSessionController.shuffleQuestionsForTest(
        questions,
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      );
      expect(
        first.map((q) => q.id),
        orderedEquals(second.map((q) => q.id)),
      );
    });

    test('a different submission id produces a different order', () {
      final first = ExamSessionController.shuffleQuestionsForTest(
        questions,
        'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
      );
      final second = ExamSessionController.shuffleQuestionsForTest(
        questions,
        'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
      );
      // At least one position must differ.
      final sameOrder = first.every(
        (q) => q.id == second[first.indexOf(q)].id,
      );
      expect(sameOrder, isFalse);
    });

    test('the order is stable across two calls with the same seed', () {
      final seed = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
      final first = ExamSessionController.shuffleQuestionsForTest(
        questions,
        seed,
      );
      final second = ExamSessionController.shuffleQuestionsForTest(
        questions,
        seed,
      );
      expect(
        first.map((q) => q.id),
        orderedEquals(second.map((q) => q.id)),
      );
    });

    test('a single question is returned unchanged', () {
      final single = <Question>[
        const Question(id: 'a', examId: 'x', questionText: 'Only'),
      ];
      final shuffled = ExamSessionController.shuffleQuestionsForTest(
        single,
        'any-seed',
      );
      expect(shuffled, hasLength(1));
      expect(shuffled[0].id, 'a');
    });
  });

  group('resume stability', () {
    test('the same submission keeps the same order across a hypothetical '
        'resume — the seed is derived from submission id, not from a '
        'session- or instance-level counter', () {
      const submissionId = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1';

      // Simulate the first session: the flag is on, questions are shuffled.
      final session1 = ExamSessionController.shuffleQuestionsForTest(
        questions,
        submissionId,
      );

      // Simulate a resume: the flag is STILL on, same submission id.
      final session2 = ExamSessionController.shuffleQuestionsForTest(
        questions,
        submissionId,
      );

      // The order is identical — stable on resume.
      expect(
        session1.map((q) => q.id),
        orderedEquals(session2.map((q) => q.id)),
      );

      // Sanity: confirm it is actually different from the original order.
      final originalOrder = questions.map((q) => q.id).toList();
      final allMatch = originalOrder.every(
        (id) => id == session1[originalOrder.indexOf(id)].id,
      );
      // The shuffle actually does something (astronomically unlikely to
      // produce the same order by chance).
      expect(allMatch, isFalse);
    });

    test('a submission started with shuffle=off and then the flag is turned '
        'on mid-lifecycle is a server-side question, not a client concern — '
        'the client just reflects the flag it reads from the exam row', () {
      // When shuffle is off, the order is the original.
      const submissionId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
      final questionsCopy = List<Question>.from(questions);

      // The controller only calls _shuffleQuestions when shuffle flag is on.
      // If the flag toggles between sessions, the new session reads the new
      // flag value from the exam row.
      final shuffled = ExamSessionController.shuffleQuestionsForTest(
        questionsCopy,
        submissionId,
      );

      // After toggling the flag on, the order changes from the original.
      // The seed is the same submission id, so the order is deterministic.
      expect(shuffled, hasLength(questionsCopy.length));
      // Just verify it is actually different from the original order.
      final originalIds = questionsCopy.map((q) => q.id).toList();
      final shuffledIds = shuffled.map((q) => q.id).toList();
      final sameOrder = originalIds.every(
        (id) => id == shuffledIds[originalIds.indexOf(id)],
      );
      expect(sameOrder, isFalse);
    });
  });

  // The shuffle itself is only half the feature: the controller decides whether
  // to call it from the flag it read off the exam row (`args.shuffleQuestions`),
  // and "off means the paper as authored" is that half. The pure function cannot
  // show it, so these tests drive the controller over a repository that answers
  // at once and read the order the student would actually be painted.
  group('the flag decides the order the student sees', () {
    Future<ExamSessionController> loadedSession({
      required bool shuffleQuestions,
    }) async {
      final exams = _AnsweredExamRepository(questions);
      final container = ProviderContainer(
        overrides: <Override>[examRepositoryProvider.overrideWithValue(exams)],
      );
      addTearDown(container.dispose);

      final args = ExamSessionArgs(
        examId: 'x',
        submissionId: 'sub-1',
        shuffleQuestions: shuffleQuestions,
      );
      // A listener keeps the `autoDispose` provider alive for the test.
      container.listen(examSessionControllerProvider(args), (_, _) {});
      final controller =
          container.read(examSessionControllerProvider(args).notifier);

      await controller.loadQuestions();
      return controller;
    }

    test('shuffle off paints the questions in the order the paper stores',
        () async {
      final controller = await loadedSession(shuffleQuestions: false);

      expect(
        controller.state.questions.map((q) => q.id).toList(),
        questions.map((q) => q.id).toList(),
        reason: 'a paper that never asked for a shuffle is shown as authored, '
            'whatever the seed would have produced',
      );
    });

    test('shuffle on paints the seeded order, not the stored one', () async {
      final controller = await loadedSession(shuffleQuestions: true);
      final expected = ExamSessionController.shuffleQuestionsForTest(
        questions,
        'sub-1',
      );

      expect(
        controller.state.questions.map((q) => q.id).toList(),
        expected.map((q) => q.id).toList(),
        reason: 'the session must paint exactly the order its own seed defines, '
            'so a resume lands where the student left off',
      );
      expect(
        controller.state.questions.map((q) => q.id).toList(),
        isNot(questions.map((q) => q.id).toList()),
        reason: 'a flag that changes nothing is not a shuffle',
      );
    });
  });
}

/// Answers the question feed immediately: what these tests vary is the flag, not
/// the timing of the fetch. Every other call is outside their scope and fails
/// loudly if a future change makes the bootstrap reach for one.
class _AnsweredExamRepository implements ExamRepository {
  _AnsweredExamRepository(this.questions);

  final List<Question> questions;

  @override
  Future<List<Question>> getQuestions(String examId) async => questions;

  @override
  Future<List<Exam>> getPublishedExams() async => const <Exam>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError();

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) =>
      throw UnimplementedError();

  @override
  Future<ExamSubmitResult> submitExam(String submissionId) =>
      throw UnimplementedError();

  @override
  Future<void> markDisqualified(String submissionId) =>
      throw UnimplementedError();
}
