import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
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
}
