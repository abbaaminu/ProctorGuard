import 'package:proctorguard/features/authoring/domain/entities/attempt_grading.dart';
import 'package:proctorguard/features/authoring/domain/entities/authored_exam.dart';
import 'package:proctorguard/features/authoring/domain/entities/authored_question.dart';
import 'package:proctorguard/features/authoring/domain/repositories/question_authoring_repository.dart';
import 'package:proctorguard/features/authoring/presentation/pages/attempt_grading_page.dart';
import 'package:proctorguard/features/authoring/presentation/pages/attempt_review_page.dart';
import 'package:proctorguard/features/authoring/presentation/pages/lecturer_console_page.dart';
import 'package:proctorguard/features/authoring/presentation/pages/question_authoring_page.dart';
import 'package:proctorguard/features/authoring/presentation/providers/question_authoring_providers.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The lecturer console, in two halves:
///
///  * **authoring** — the four question shapes, the rules the database also
///    enforces (`QuestionDraft.problem` mirrors `questions_answer_key_shape`),
///    and the editor that produces them;
///  * **marking** — what the server decided about the automatically graded
///    answers, and the marks a person awards to an essay.
///
/// Everything runs against a fake repository, so no Supabase project, no network
/// and no camera are involved.
void main() {
  const examId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3';
  const lecturerId = '55555555-5555-4555-8555-555555555555';

  final exam = const Exam(
    id: examId,
    title: 'GES301: Software Engineering Midterm',
    createdBy: lecturerId,
    durationMinutes: 50,
    isPublished: true,
  );

  AuthoredQuestion question({
    String id = 'q-mcq',
    QuestionType type = QuestionType.multipleChoice,
    String text = 'Which process model delivers a working increment?',
    List<String> options = const <String>['Waterfall', 'Scrum'],
    int? correctOption = 1,
    String? correctTextAnswer,
    double points = 2,
  }) =>
      AuthoredQuestion(
        id: id,
        examId: examId,
        questionText: text,
        questionType: type,
        options: options,
        correctOption: correctOption,
        correctTextAnswer: correctTextAnswer,
        points: points,
      );

  /// Chidi's attempt on the paper above: one question of each shape, the first
  /// three answered (one of them wrongly, one with different casing), and the
  /// essay answered but not yet marked.
  AttemptGrading attemptWith({
    double? essayAwarded,
    String? feedback,
    DateTime? gradedAt,
    Object? trueFalseAnswer = 'true',
    Object? blankAnswer = '  continuous integration ',
  }) =>
      AttemptGrading(
        submission: Submission(
          id: 'sub-1',
          studentId: '33333333-3333-4333-8333-333333333333',
          examId: examId,
          answers: <String, dynamic>{
            'q-mcq': 1,
            'q-tf': trueFalseAnswer,
            'q-blank': blankAnswer,
            'q-essay':
                'I would read the diff for anything that holds a secret.',
          },
          status: SubmissionStatus.submitted,
          score: 4,
        ),
        studentName: 'Chidi Okonkwo',
        lines: <GradeLine>[
          GradeLine(question: question(), rawAnswer: 1),
          GradeLine(
            question: question(
              id: 'q-tf',
              type: QuestionType.trueFalse,
              text: 'A pull request may be merged before its checks pass.',
              options: const <String>[],
              correctOption: null,
              correctTextAnswer: 'false',
              points: 1,
            ),
            rawAnswer: trueFalseAnswer,
          ),
          GradeLine(
            question: question(
              id: 'q-blank',
              type: QuestionType.fillInTheBlank,
              text: 'What is the practice of running tests on every change?',
              options: const <String>[],
              correctOption: null,
              correctTextAnswer: 'Continuous integration',
              points: 2,
            ),
            rawAnswer: blankAnswer,
          ),
          GradeLine(
            question: question(
              id: 'q-essay',
              type: QuestionType.subjective,
              text: 'Describe how you would review a change to authentication.',
              options: const <String>[],
              correctOption: null,
              points: 5,
            ),
            rawAnswer:
                'I would read the diff for anything that holds a secret.',
            awarded: essayAwarded,
            feedback: feedback,
            gradedAt: gradedAt,
          ),
        ],
      );

  group("QuestionDraft rules (the database's rules, answered locally)", () {
    test('a complete draft of each shape is accepted', () {
      expect(
        const QuestionDraft(
          questionType: QuestionType.multipleChoice,
          questionText: 'Which data structure is FIFO?',
          options: <String>['Stack', 'Queue'],
          correctOption: 1,
        ).isComplete,
        isTrue,
      );
      expect(
        const QuestionDraft(
          questionType: QuestionType.trueFalse,
          questionText: 'A pull request may be merged before its checks pass.',
          correctTextAnswer: 'false',
        ).isComplete,
        isTrue,
      );
      expect(
        const QuestionDraft(
          questionType: QuestionType.fillInTheBlank,
          questionText: 'What does HTTP stand for?',
          correctTextAnswer: 'HyperText Transfer Protocol',
        ).isComplete,
        isTrue,
      );
      // An essay has nothing to ask for beyond its wording: the absence of a key
      // is the shape.
      expect(
        const QuestionDraft(
          questionType: QuestionType.subjective,
          questionText: 'Describe how you would review a change.',
          points: 5,
        ).isComplete,
        isTrue,
      );
    });

    test('each shape reports the one thing it is missing', () {
      const missingText = QuestionDraft(
        questionType: QuestionType.multipleChoice,
        questionText: '   ',
      );
      expect(missingText.problem, 'Write the question.');

      const oneOption = QuestionDraft(
        questionType: QuestionType.multipleChoice,
        questionText: 'Which data structure is FIFO?',
        options: <String>['Queue'],
      );
      expect(oneOption.problem, contains('at least 2 options'));

      const emptyOption = QuestionDraft(
        questionType: QuestionType.multipleChoice,
        questionText: 'Which data structure is FIFO?',
        options: <String>['Queue', '  '],
      );
      expect(emptyOption.problem, 'Every option needs text.');

      const noAnswer = QuestionDraft(
        questionType: QuestionType.multipleChoice,
        questionText: 'Which data structure is FIFO?',
        options: <String>['Queue', 'Stack'],
      );
      expect(noAnswer.problem, 'Pick which option is correct.');

      const noWord = QuestionDraft(
        questionType: QuestionType.trueFalse,
        questionText: 'A pull request may be merged before its checks pass.',
      );
      expect(noWord.problem, 'Choose whether the answer is true or false.');

      const noWording = QuestionDraft(
        questionType: QuestionType.fillInTheBlank,
        questionText: 'What does HTTP stand for?',
      );
      expect(noWording.problem, 'Type the answer you will accept.');

      const negativeMarks = QuestionDraft(
        questionType: QuestionType.subjective,
        questionText: 'Describe how you would review a change.',
        points: -1,
      );
      expect(negativeMarks.problem, 'Marks cannot be negative.');

      const sillyMarks = QuestionDraft(
        questionType: QuestionType.subjective,
        questionText: 'Describe how you would review a change.',
        points: 500,
      );
      expect(sillyMarks.problem, 'Marks cannot exceed 100.0.');
    });

    test('a blank multiple-choice draft opens with two empty options', () {
      final draft = QuestionDraft.blank(QuestionType.multipleChoice);
      expect(draft.options, <String>['', '']);
      expect(draft.problem, 'Write the question.');

      // Every other shape opens with no options at all.
      expect(QuestionDraft.blank(QuestionType.subjective).options, isEmpty);
      expect(QuestionDraft.blank(QuestionType.trueFalse).options, isEmpty);
    });

    test('the row carries one answer key, matching the shape', () {
      // Multiple choice: the index, and no typed key. Options are trimmed, the
      // index is untouched.
      final choice = const QuestionDraft(
        questionType: QuestionType.multipleChoice,
        questionText: 'Which data structure is FIFO?',
        options: <String>[' Stack ', 'Queue'],
        correctOption: 1,
        points: 2,
      ).toRow();
      expect(choice['question_type'], 'multiple_choice');
      expect(choice['options'], <String>['Stack', 'Queue']);
      expect(choice['correct_option'], 1);
      expect(choice['correct_text_answer'], isNull);

      // True/false: the word, lowercased, and no index at all.
      final statement = const QuestionDraft(
        questionType: QuestionType.trueFalse,
        questionText: 'A pull request may be merged before its checks pass.',
        correctTextAnswer: '  FALSE ',
      ).toRow();
      expect(statement['question_type'], 'true_false');
      expect(statement['correct_text_answer'], 'false');
      expect(statement['correct_option'], isNull);
      expect(statement['options'], isEmpty);

      // Fill in the blank: trimmed but *not* lowercased — the server compares
      // case-insensitively, and the author's spelling is what a report prints.
      final typed = const QuestionDraft(
        questionType: QuestionType.fillInTheBlank,
        questionText: 'What does HTTP stand for?',
        correctTextAnswer: '  HyperText Transfer Protocol ',
      ).toRow();
      expect(typed['correct_text_answer'], 'HyperText Transfer Protocol');
      expect(typed['correct_option'], isNull);

      // Subjective: no key at all, whatever the draft was holding.
      final essay = const QuestionDraft(
        questionType: QuestionType.subjective,
        questionText: 'Describe how you would review a change.',
        correctTextAnswer: 'left over from another shape',
        correctOption: 3,
        options: <String>['a', 'b'],
        points: 5,
      ).toRow();
      expect(essay['question_type'], 'subjective');
      expect(essay['correct_text_answer'], isNull);
      expect(essay['correct_option'], isNull);
      expect(essay['options'], isEmpty);
      expect(essay['points'], 5);
    });
  });

  group('AuthoredQuestion', () {
    test('reads a row with its key, and reports the key back in words', () {
      final choice = AuthoredQuestion.fromMap(<String, dynamic>{
        'id': 'q-1',
        'exam_id': examId,
        'question_text': 'Which process model delivers a working increment?',
        'question_type': 'multiple_choice',
        'options': <String>['Waterfall', 'Scrum'],
        'correct_option': 1,
        'correct_text_answer': null,
        'points': 2,
      });
      // The option *text*, not the index: an index means nothing on a review
      // screen.
      expect(choice.answerSummary, 'Scrum');
      expect(choice.points, 2);

      expect(
        question(
          type: QuestionType.trueFalse,
          options: const <String>[],
          correctOption: null,
          correctTextAnswer: 'false',
        ).answerSummary,
        'False',
      );
      expect(
        question(
          type: QuestionType.fillInTheBlank,
          options: const <String>[],
          correctOption: null,
          correctTextAnswer: 'Continuous integration',
        ).answerSummary,
        '“Continuous integration”',
      );
      expect(
        question(
          type: QuestionType.subjective,
          options: const <String>[],
          correctOption: null,
        ).answerSummary,
        'No answer key — marked by hand',
      );
    });

    test('a row with a broken key says so rather than showing an empty line',
        () {
      // An option index the paper no longer holds: the list says it is missing
      // instead of showing "Answer: ".
      expect(
        question(options: const <String>['Only one'], correctOption: 4)
            .answerSummary,
        'No correct option set',
      );
      expect(
        question(
          type: QuestionType.trueFalse,
          options: const <String>[],
          correctOption: null,
        ).answerSummary,
        'No correct answer set',
      );
      expect(
        question(
          type: QuestionType.fillInTheBlank,
          options: const <String>[],
          correctOption: null,
        ).answerSummary,
        'No accepted answer set',
      );
    });

    test('toDraft re-opens the question in the editor, unchanged', () {
      final original = question(
        type: QuestionType.fillInTheBlank,
        text: 'What does HTTP stand for?',
        options: const <String>[],
        correctOption: null,
        correctTextAnswer: 'HyperText Transfer Protocol',
        points: 3,
      );

      final draft = original.toDraft();
      expect(draft.questionType, QuestionType.fillInTheBlank);
      expect(draft.questionText, original.questionText);
      expect(draft.correctTextAnswer, 'HyperText Transfer Protocol');
      expect(draft.points, 3);
      expect(draft.isComplete, isTrue);
    });
  });

  group('GradeLine: the automatic verdict, per shape', () {
    test('multiple choice compares the stored option index with the key', () {
      final line = GradeLine(question: question(), rawAnswer: 1);
      expect(line.isCorrect, isTrue);
      // The option text is what a lecturer reads; the index is what was scored.
      expect(line.answerText, 'Scrum');
      expect(line.expectedText, 'Scrum');

      final wrong = GradeLine(question: question(), rawAnswer: 0);
      expect(wrong.isCorrect, isFalse);
      expect(wrong.answerText, 'Waterfall');
    });

    test('true/false compares the stored word, case-insensitively', () {
      final statement = question(
        id: 'q-tf',
        type: QuestionType.trueFalse,
        options: const <String>[],
        correctOption: null,
        correctTextAnswer: 'false',
      );

      final right = GradeLine(question: statement, rawAnswer: 'FALSE');
      expect(right.isCorrect, isTrue);
      expect(right.answerText, 'False');

      final wrong = GradeLine(question: statement, rawAnswer: 'true');
      expect(wrong.isCorrect, isFalse);
      expect(wrong.answerText, 'True');
    });

    test('fill in the blank trims and ignores case, exactly like the server',
        () {
      final typed = question(
        id: 'q-blank',
        type: QuestionType.fillInTheBlank,
        options: const <String>[],
        correctOption: null,
        correctTextAnswer: 'Continuous integration',
      );

      // `  continuous integration ` scores for "Continuous integration": the same
      // comparison `auto_graded_score()` makes.
      final line = GradeLine(
        question: typed,
        rawAnswer: '  continuous integration ',
      );
      expect(line.isCorrect, isTrue);
      expect(line.answerText, 'continuous integration');
      expect(line.expectedText, '“Continuous integration”');

      expect(
        GradeLine(question: typed, rawAnswer: 'continuous delivery').isCorrect,
        isFalse,
      );
    });

    test('an essay has no automatic verdict at all', () {
      final line = GradeLine(
        question: question(
          id: 'q-essay',
          type: QuestionType.subjective,
          options: const <String>[],
          correctOption: null,
          points: 5,
        ),
        rawAnswer: 'A paragraph.',
      );

      expect(line.isEssay, isTrue);
      // Null, not false: nothing automatic decided this — a mark is a person's
      // answer rather than a comparison.
      expect(line.isCorrect, isNull);
      expect(line.expectedText, isNull);
      expect(line.isMarked, isFalse);
    });

    test('an unanswered question did not score, and is not called wrong', () {
      final line = GradeLine(question: question(), rawAnswer: null);
      expect(line.isAnswered, isFalse);
      expect(line.isCorrect, isNull);
      expect(line.answerText, isNull);
    });

    test('a stored index the paper no longer holds is shown, not hidden', () {
      // The question's options were edited after the attempt closed. Dropping the
      // answer would make a wrong answer look unanswered.
      final line = GradeLine(
        question: question(
          options: const <String>['Only one'],
          correctOption: 0,
        ),
        rawAnswer: 3,
      );
      expect(line.answerText, 'Option 4 (no longer on the paper)');
      expect(line.isCorrect, isFalse);
    });
  });

  group('AttemptGrading: what is left to mark', () {
    test('an attempt with an unmarked essay is waiting for marks', () {
      final attempt = attemptWith();

      expect(attempt.essayLines, hasLength(1));
      expect(attempt.essaysGraded, 0);
      expect(attempt.essaysToGrade, 1);
      expect(attempt.isAwaitingMarks, isTrue);
      // Everything the paper is worth, and what the server holds so far.
      expect(attempt.maxScore, 10);
      expect(attempt.score, 4);
    });

    test('a marked essay closes the attempt out', () {
      final attempt = attemptWith(
        essayAwarded: 3.5,
        feedback: 'Good threat model.',
        gradedAt: DateTime(2026, 5, 9, 14, 30),
      );

      expect(attempt.essaysGraded, 1);
      expect(attempt.essaysToGrade, 0);
      expect(attempt.isAwaitingMarks, isFalse);
      expect(attempt.essayLines.single.isMarked, isTrue);
      expect(attempt.essayLines.single.gradedAt, DateTime(2026, 5, 9, 14, 30));
    });

    test('the payload carries only the essays that have marks', () {
      // Nothing marked yet: an empty payload is a no-op rather than an
      // instruction to clear somebody's marks.
      expect(attemptWith().gradePayload(), isEmpty);

      final payload =
          attemptWith(essayAwarded: 4, feedback: 'Clear.').gradePayload();
      expect(payload, <String, dynamic>{
        'q-essay': <String, dynamic>{'awarded': 4.0, 'feedback': 'Clear.'},
      });
    });

    test('a paper with no essays is never "waiting"', () {
      final attempt = AttemptGrading(
        submission: const Submission(
          id: 'sub-2',
          studentId: 'student-2',
          examId: examId,
          answers: <String, dynamic>{'q-mcq': 1},
          status: SubmissionStatus.submitted,
          score: 2,
        ),
        studentName: 'Student 33333333',
        lines: <GradeLine>[GradeLine(question: question(), rawAnswer: 1)],
      );

      expect(attempt.essayLines, isEmpty);
      expect(attempt.isAwaitingMarks, isFalse);
    });
  });

  group('GradingOutcome', () {
    test('reads the RPC row and says what happened in one sentence', () {
      final partial = GradingOutcome.fromMap(<String, dynamic>{
        'final_score': 6.5,
        'graded_answers': 1,
        'ungraded_answers': 2,
      });
      expect(partial.finalScore, 6.5);
      expect(partial.summary, 'Saved. 6.5 so far, 2 essays still to mark.');

      final done = GradingOutcome.fromMap(<String, dynamic>{
        'final_score': 9,
        'graded_answers': 2,
        'ungraded_answers': 0,
      });
      // Whole marks print without a trailing ".0".
      expect(done.summary, 'Marked. The attempt now totals 9.');
    });
  });

  group('lecturer console', () {
    late _FakeAuthoring repo;

    setUp(() => repo = _FakeAuthoring());

    Widget consoleUnderTest() => ProviderScope(
          overrides: [
            questionAuthoringRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: LecturerConsolePage(lecturerName: 'Dr. Tunde Balogun'),
          ),
        );

    testWidgets('lists the papers this account owns, with their counts',
        (tester) async {
      repo.exams = <AuthoredExam>[
        AuthoredExam(exam: exam, questionCount: 4, attemptCount: 1),
        AuthoredExam(
          exam: Exam(
            id: 'exam-draft',
            title: 'GES302: Requirements Engineering',
            createdBy: lecturerId,
            durationMinutes: 30,
            isPublished: false,
          ),
          questionCount: 0,
          attemptCount: 0,
        ),
      ];

      await tester.pumpWidget(consoleUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('GES301: Software Engineering Midterm'), findsOneWidget);
      expect(find.text('4 questions · 1 attempt'), findsOneWidget);
      expect(find.text('Published'), findsOneWidget);
      // A draft is labelled as one, so "why can nobody see this?" has an answer.
      expect(find.text('Draft'), findsOneWidget);
      expect(find.text('0 questions · 0 attempts'), findsOneWidget);
      // The four things a lecturer does with a paper, per row.
      expect(find.byKey(const Key('exam-questions-$examId')), findsOneWidget);
      expect(find.byKey(const Key('exam-grading-$examId')), findsOneWidget);
      expect(find.byKey(const Key('exam-publish-$examId')), findsOneWidget);
      expect(find.byKey(const Key('exam-delete-$examId')), findsOneWidget);
    });

    testWidgets('an empty console invites the first paper', (tester) async {
      await tester.pumpWidget(consoleUnderTest());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('lecturer-no-papers')), findsOneWidget);
      // The only way to get a paper: the action itself.
      expect(find.byKey(const Key('lecturer-new-exam')), findsOneWidget);
    });

    testWidgets('a new paper is created as a draft, by default and by design',
        (tester) async {
      await tester.pumpWidget(consoleUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('lecturer-new-exam')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-exam-dialog')), findsOneWidget);

      // A title is required; the duration defaults to an hour.
      await tester.tap(find.byKey(const Key('new-exam-create')));
      await tester.pumpAndSettle();
      expect(find.text('Give the paper a title'), findsOneWidget);
      expect(repo.created, isEmpty);

      await tester.enterText(
        find.byKey(const Key('new-exam-title')),
        'GES301: Software Engineering Midterm',
      );
      await tester.enterText(
        find.byKey(const Key('new-exam-duration')),
        '45',
      );
      await tester.tap(find.byKey(const Key('new-exam-create')));
      await tester.pumpAndSettle();

      // Draft, not published: a paper with no questions cannot be sat, so the
      // default is the one that cannot go wrong.
      expect(repo.created.single, (
        title: 'GES301: Software Engineering Midterm',
        durationMinutes: 45,
        isPublished: false,
      ));
      expect(find.textContaining('saved as a draft'), findsOneWidget);
      await letSnackBarExpire(tester);
    });

    testWidgets('publishing a paper with no questions is refused, with the fix',
        (tester) async {
      repo.exams = <AuthoredExam>[
        AuthoredExam(
          exam: Exam(
            id: 'exam-draft',
            title: 'GES302: Requirements Engineering',
            createdBy: lecturerId,
            durationMinutes: 30,
            isPublished: false,
          ),
          questionCount: 0,
          attemptCount: 0,
        ),
      ];

      await tester.pumpWidget(consoleUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-publish-exam-draft')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('Add at least one question before publishing'),
        findsOneWidget,
      );
      // Nothing was sent: the students' list is what an empty published paper
      // would damage.
      expect(repo.publishCalls, isEmpty);
      await letSnackBarExpire(tester);
    });

    testWidgets('deleting a paper asks first, and names what goes with it',
        (tester) async {
      repo.exams = <AuthoredExam>[
        AuthoredExam(exam: exam, questionCount: 4, attemptCount: 1),
      ];

      await tester.pumpWidget(consoleUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-delete-$examId')));
      await tester.pumpAndSettle();

      // The cascade, in the words of somebody deciding whether to press it.
      expect(
        find.textContaining('4 questions, 1 attempt, every answer'),
        findsOneWidget,
      );
      expect(repo.deletedExams, isEmpty);

      await tester.tap(find.byKey(const Key('exam-delete-confirm')));
      await tester.pumpAndSettle();
      expect(repo.deletedExams, <String>[examId]);
    });
  });

  group('question authoring', () {
    late _FakeAuthoring repo;

    setUp(() => repo = _FakeAuthoring());

    Widget authoringUnderTest() => ProviderScope(
          overrides: [
            questionAuthoringRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: QuestionAuthoringPage(examId: examId, examTitle: 'GES301'),
          ),
        );

    testWidgets('lists every shape with the key it will be marked against',
        (tester) async {
      useTallSurface(tester);
      repo.questions = <AuthoredQuestion>[
        question(),
        question(
          id: 'q-tf',
          type: QuestionType.trueFalse,
          text: 'A pull request may be merged before its checks pass.',
          options: const <String>[],
          correctOption: null,
          correctTextAnswer: 'false',
          points: 1,
        ),
        question(
          id: 'q-blank',
          type: QuestionType.fillInTheBlank,
          text: 'What is running the suite on every change called?',
          options: const <String>[],
          correctOption: null,
          correctTextAnswer: 'Continuous integration',
          points: 2,
        ),
        question(
          id: 'q-essay',
          type: QuestionType.subjective,
          text: 'Describe how you would review a change to authentication.',
          options: const <String>[],
          correctOption: null,
          points: 5,
        ),
      ];

      await tester.pumpWidget(authoringUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Multiple choice'), findsOneWidget);
      expect(find.text('True / false'), findsOneWidget);
      expect(find.text('Fill in the blank'), findsOneWidget);
      expect(find.text('Essay'), findsOneWidget);
      // The key, read back in words — the one place a client holds it.
      expect(find.text('Answer: Scrum'), findsOneWidget);
      expect(find.text('Answer: False'), findsOneWidget);
      expect(find.text('Answer: “Continuous integration”'), findsOneWidget);
      expect(
        find.text('Answer: No answer key — marked by hand'),
        findsOneWidget,
      );
      // The paper's questions in the order they were written.
      expect(find.text('Question 1'), findsOneWidget);
      expect(find.text('Question 4'), findsOneWidget);
      expect(find.byKey(const Key('question-add')), findsOneWidget);
    });

    testWidgets('a multiple-choice question is refused until it is answerable',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(authoringUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('question-add')));
      await tester.pumpAndSettle();

      // The editor opens on multiple choice, with the starter pair of options.
      expect(find.byKey(const Key('question-option-0')), findsOneWidget);
      expect(find.byKey(const Key('question-option-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();
      expect(find.text('Write the question.'), findsOneWidget);
      expect(repo.createdQuestions, isEmpty);

      await tester.enterText(
        find.byKey(const Key('question-text')),
        'Which data structure is FIFO?',
      );
      await tester.enterText(
        find.byKey(const Key('question-option-0')),
        'Stack',
      );
      await tester.enterText(
        find.byKey(const Key('question-option-1')),
        'Queue',
      );
      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();
      // Still refused: nothing says which option is right, and a question with no
      // key is ungradeable.
      expect(find.text('Pick which option is correct.'), findsOneWidget);
      expect(repo.createdQuestions, isEmpty);

      await tester.tap(find.byKey(const Key('question-option-correct-1')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('question-points')), '2');
      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();

      expect(repo.createdQuestions.single.examId, examId);
      final draft = repo.createdQuestions.single.draft;
      expect(draft.questionType, QuestionType.multipleChoice);
      expect(draft.options, <String>['Stack', 'Queue']);
      expect(draft.correctOption, 1);
      expect(draft.points, 2);
      expect(find.text('Question added.'), findsOneWidget);
      await letSnackBarExpire(tester);
    });

    testWidgets('a true/false question stores the word, not an option index',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(authoringUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('question-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('question-type-true_false')));
      await tester.pumpAndSettle();

      // No option rows, and no free-text key: the two tap targets *are* the key.
      expect(find.byKey(const Key('question-option-0')), findsNothing);
      expect(find.byKey(const Key('question-answer-text')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('question-text')),
        'A pull request may be merged before its checks pass.',
      );
      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();
      expect(
        find.text('Choose whether the answer is true or false.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('question-answer-false')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();

      final draft = repo.createdQuestions.single.draft;
      expect(draft.questionType, QuestionType.trueFalse);
      expect(draft.correctTextAnswer, 'false');
      expect(draft.options, isEmpty);
      await letSnackBarExpire(tester);
    });

    testWidgets('an essay has no key field at all, and keeps its marks',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(authoringUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('question-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('question-type-subjective')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('question-answer-text')), findsNothing);
      expect(find.byKey(const Key('question-answer-true')), findsNothing);
      expect(find.textContaining('No answer key'), findsOneWidget);
      // It says who marks it, so "why is this attempt still waiting?" is answered
      // where the question is written.
      expect(find.textContaining('Marked by hand'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('question-text')),
        'Describe how you would review a change to authentication.',
      );
      await tester.enterText(find.byKey(const Key('question-points')), '5');
      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();

      final draft = repo.createdQuestions.single.draft;
      expect(draft.questionType, QuestionType.subjective);
      expect(draft.correctTextAnswer, isEmpty);
      expect(draft.points, 5);
      await letSnackBarExpire(tester);
    });

    testWidgets('the option list grows and shrinks, and the key index follows',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(authoringUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('question-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('question-add-option')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('question-option-2')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('question-text')),
        'Which data structure is FIFO?',
      );
      await tester.enterText(
          find.byKey(const Key('question-option-0')), 'Stack');
      await tester.enterText(
          find.byKey(const Key('question-option-1')), 'Tree');
      await tester.enterText(
          find.byKey(const Key('question-option-2')), 'Queue');
      await tester.tap(find.byKey(const Key('question-option-correct-2')));
      await tester.pumpAndSettle();

      // Removing the first option shifts the key down with it, instead of leaving
      // the index pointing at a different answer.
      await tester.tap(find.byKey(const Key('question-remove-option-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('question-save')));
      await tester.pumpAndSettle();

      final draft = repo.createdQuestions.single.draft;
      expect(draft.options, <String>['Tree', 'Queue']);
      expect(draft.correctOption, 1);
      await letSnackBarExpire(tester);
    });

    testWidgets('deleting a question names the marks it takes with it',
        (tester) async {
      repo.questions = <AuthoredQuestion>[
        question(
          id: 'q-essay',
          type: QuestionType.subjective,
          text: 'Describe how you would review a change to authentication.',
          options: const <String>[],
          correctOption: null,
          points: 5,
        ),
      ];

      await tester.pumpWidget(authoringUnderTest());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('question-delete-q-essay')));
      await tester.pumpAndSettle();
      expect(find.textContaining('any marks already awarded'), findsOneWidget);
      expect(repo.deletedQuestions, isEmpty);

      await tester.tap(find.byKey(const Key('question-delete-confirm')));
      await tester.pumpAndSettle();
      expect(repo.deletedQuestions, <String>['q-essay']);
      await letSnackBarExpire(tester);
    });
  });

  group('marking an attempt', () {
    late _FakeAuthoring repo;

    setUp(() => repo = _FakeAuthoring());

    Widget gradingUnderTest() => ProviderScope(
          overrides: [
            questionAuthoringRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(
            home: AttemptGradingPage(examId: examId, examTitle: 'GES301'),
          ),
        );

    /// The marking screen behind a launcher route, so saving can pop back to a
    /// queue the way it does in the console (popping the *root* route is not what
    /// production does).
    Widget reviewUnderTest(AttemptGrading attempt) => ProviderScope(
          overrides: [
            questionAuthoringRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AttemptReviewPage(
                          examId: examId,
                          examTitle: 'GES301',
                          attempt: attempt,
                        ),
                      ),
                    ),
                    child: const Text('open attempt'),
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('the queue says whose paper is waiting, and what it is worth',
        (tester) async {
      repo.attempts = <AttemptGrading>[attemptWith()];

      await tester.pumpWidget(gradingUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Chidi Okonkwo'), findsOneWidget);
      expect(find.text('4 of 4 answered'), findsOneWidget);
      expect(find.text('4 of 10 marks'), findsOneWidget);
      // One essay, no marks: the tile carries the work left.
      expect(find.byKey(const Key('attempt-waiting-sub-1')), findsOneWidget);
      expect(find.text('1 to mark'), findsOneWidget);
    });

    testWidgets('opening an attempt shows each shape its own way',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(reviewUnderTest(attemptWith()));
      await tester.tap(find.text('open attempt'));
      await tester.pumpAndSettle();

      text(String key) => tester.widget<Text>(find.byKey(Key(key))).data;

      // Multiple choice: right, with the key beside it so the verdict is
      // auditable.
      expect(text('line-verdict-q-mcq'), 'Correct');
      expect(find.text('Expected: Scrum'), findsOneWidget);
      // True/false: wrong (the statement was false and the student said true).
      expect(text('line-verdict-q-tf'), 'Incorrect');
      expect(find.text('Expected: False'), findsOneWidget);
      // Fill in the blank: right, even though the student's casing differed.
      expect(text('line-verdict-q-blank'), 'Correct');
      // The essay has marks fields instead of a verdict.
      expect(find.byKey(const Key('line-verdict-q-essay')), findsNothing);
      expect(find.byKey(const Key('essay-marks-q-essay')), findsOneWidget);
      expect(find.byKey(const Key('essay-feedback-q-essay')), findsOneWidget);
      expect(find.text('1 essay to mark'), findsOneWidget);
      expect(find.text('4 of 10 marks'), findsOneWidget);
    });

    testWidgets('a mark outside the question is refused before it is sent',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(reviewUnderTest(attemptWith()));
      await tester.tap(find.text('open attempt'));
      await tester.pumpAndSettle();

      // Five marks is the whole question, so nine is a slip — and the field says
      // so against that question's weight.
      await tester.enterText(
        find.byKey(const Key('essay-marks-q-essay')),
        '9',
      );
      await tester.tap(find.byKey(const Key('grading-save')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('essay-marks-error-q-essay')))
            .data,
        'Between 0 and 5.',
      );
      expect(repo.gradeCalls, isEmpty);

      await tester.enterText(
        find.byKey(const Key('essay-marks-q-essay')),
        '3.5',
      );
      await tester.enterText(
        find.byKey(const Key('essay-feedback-q-essay')),
        'Good threat model.',
      );
      await tester.tap(find.byKey(const Key('grading-save')));
      await tester.pumpAndSettle();

      // One call, naming the attempt and the essay, with the feedback alongside
      // the mark.
      expect(repo.gradeCalls.single.submissionId, 'sub-1');
      expect(repo.gradeCalls.single.grades, <String, dynamic>{
        'q-essay': <String, dynamic>{
          'awarded': 3.5,
          'feedback': 'Good threat model.',
        },
      });
      // The screen reports what the server answered, and returns to the queue.
      expect(find.text('Marked. The attempt now totals 9.'), findsOneWidget);
      expect(find.text('open attempt'), findsOneWidget);
      await letSnackBarExpire(tester);
    });

    testWidgets('saving with nothing entered is refused, not sent as a no-op',
        (tester) async {
      await tester.pumpWidget(reviewUnderTest(attemptWith()));
      await tester.tap(find.text('open attempt'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('grading-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.textContaining('Enter marks for at least one essay'),
        findsOneWidget,
      );
      expect(repo.gradeCalls, isEmpty);
      await letSnackBarExpire(tester);
    });

    testWidgets('an attempt whose essays are all marked says so',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        reviewUnderTest(
          attemptWith(
            essayAwarded: 4,
            feedback: 'Solid.',
            gradedAt: DateTime(2026, 5, 9),
          ),
        ),
      );
      await tester.tap(find.text('open attempt'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('review-fully-marked')), findsOneWidget);
      expect(find.byKey(const Key('essay-marked-q-essay')), findsOneWidget);
      expect(find.textContaining('Already marked'), findsOneWidget);
      // The mark already awarded is in the field, ready to be corrected rather
      // than typed again from nothing.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('essay-marks-q-essay')))
            .controller!
            .text,
        '4',
      );
    });
  });
}

/// Pumps a SnackBar's whole lifetime out, so no timer is left pending when the
/// test ends — an error toast is on screen for six seconds by design.
Future<void> letSnackBarExpire(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pump(const Duration(milliseconds: 300));
}

/// A viewport tall enough to build every card of a long list: the default
/// 800×600 test surface only paints what fits, and these screens are lists of
/// tall cards.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// The authoring and marking repository, recording every write so a test can
/// assert exactly what the server would have been told.
class _FakeAuthoring implements QuestionAuthoringRepository {
  List<AuthoredExam> exams = const <AuthoredExam>[];
  List<AuthoredQuestion> questions = const <AuthoredQuestion>[];
  List<AttemptGrading> attempts = const <AttemptGrading>[];

  final List<({String title, int durationMinutes, bool isPublished})> created =
      <({String title, int durationMinutes, bool isPublished})>[];
  final List<({String examId, QuestionDraft draft})> createdQuestions =
      <({String examId, QuestionDraft draft})>[];
  final List<String> deletedQuestions = <String>[];
  final List<String> deletedExams = <String>[];
  final List<({String examId, bool isPublished})> publishCalls =
      <({String examId, bool isPublished})>[];
  final List<({String submissionId, Map<String, dynamic> grades})> gradeCalls =
      <({String submissionId, Map<String, dynamic> grades})>[];

  /// What `grade_submission()` answers with: whole marks, nothing left to mark —
  /// the shape of a paper that has just been finished.
  GradingOutcome outcome = const GradingOutcome(
    finalScore: 9,
    gradedAnswers: 1,
    ungradedAnswers: 0,
  );

  @override
  Future<List<AuthoredExam>> listMyExams() async => exams;

  @override
  Future<AuthoredExam> createExam({
    required String title,
    required int durationMinutes,
    required bool isPublished,
  }) async {
    created.add((
      title: title,
      durationMinutes: durationMinutes,
      isPublished: isPublished,
    ));
    return AuthoredExam(
      exam: Exam(
        id: 'exam-new',
        title: title,
        createdBy: 'lecturer',
        durationMinutes: durationMinutes,
        isPublished: isPublished,
      ),
      questionCount: 0,
      attemptCount: 0,
    );
  }

  @override
  Future<void> setPublished({
    required String examId,
    required bool isPublished,
  }) async {
    publishCalls.add((examId: examId, isPublished: isPublished));
  }

  @override
  Future<void> deleteExam(String examId) async {
    deletedExams.add(examId);
  }

  @override
  Future<List<AuthoredQuestion>> listQuestions(String examId) async =>
      questions;

  @override
  Future<AuthoredQuestion> createQuestion({
    required String examId,
    required QuestionDraft draft,
  }) async {
    createdQuestions.add((examId: examId, draft: draft));
    return _rowOf('q-new', examId, draft);
  }

  @override
  Future<AuthoredQuestion> updateQuestion({
    required String questionId,
    required QuestionDraft draft,
  }) async =>
      _rowOf(questionId, 'exam-9', draft);

  @override
  Future<void> deleteQuestion(String questionId) async {
    deletedQuestions.add(questionId);
  }

  @override
  Future<List<AttemptGrading>> listAttempts(String examId) async => attempts;

  @override
  Future<GradingOutcome> saveGrades({
    required String submissionId,
    required Map<String, dynamic> grades,
  }) async {
    gradeCalls.add((submissionId: submissionId, grades: grades));
    return outcome;
  }

  /// The row the server would hand back for a stored draft.
  static AuthoredQuestion _rowOf(
          String id, String examId, QuestionDraft draft) =>
      AuthoredQuestion(
        id: id,
        examId: examId,
        questionText: draft.questionText.trim(),
        questionType: draft.questionType,
        options: draft.options,
        correctOption: draft.correctOption,
        correctTextAnswer: draft.correctTextAnswer,
        points: draft.points,
      );
}
