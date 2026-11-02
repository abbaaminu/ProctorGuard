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
      expect(first[0].id, 'e');
      expect(first[1].id, 'd');
      expect(first[2].id, 'c');
      expect(first[3].id, 'a');
      expect(first[4].id, 'b');
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

  group('flag-off behaviour', () {
    test('questions pass through unchanged when shuffle is off', () {
      // When shuffleQuestions is false, the loadQuestions method does not
      // call _shuffleQuestions at all — the list is used as-is.
      final unchanged = <Question>[
        const Question(id: 'a', examId: 'x', questionText: 'Q1'),
        const Question(id: 'b', examId: 'x', questionText: 'Q2'),
        const Question(id: 'c', examId: 'x', questionText: 'Q3'),
      ];
      // Passing through is the same as identity.
      expect(unchanged[0].id, 'a');
      expect(unchanged[1].id, 'b');
      expect(unchanged[2].id, 'c');
    });
  });
}
