import 'package:equatable/equatable.dart';

import '../../../exam/domain/entities/question.dart';
import '../../../exam/domain/entities/submission.dart';
import 'authored_question.dart';

/// One line of a marked paper: the question, what the student stored under it,
/// and — for an essay — the marks a previous pass (if any) left on it.
///
/// [isCorrect] is the **automatic** verdict for the three auto-graded shapes,
/// computed from the same two values `auto_graded_score()` compares. It exists so
/// the review screen can say what the server scored without another round trip,
/// and it is display only: the number that counts is `Submission.score`, which
/// the server wrote and which this class never recalculates.
class GradeLine extends Equatable {
  const GradeLine({
    required this.question,
    required this.rawAnswer,
    this.awarded,
    this.feedback,
    this.gradedAt,
  });

  final AuthoredQuestion question;

  /// The student's stored answer, exactly as `exam_submissions.answers` holds
  /// it: a number for a multiple-choice tap, a string for everything typed or
  /// tapped true/false, and absent (null) when nothing was stored at all.
  final Object? rawAnswer;

  /// Marks awarded by hand. Null until an essay has been marked, and always null
  /// for an auto-graded line — that mark lives in `Submission.score` instead.
  final double? awarded;

  final String? feedback;
  final DateTime? gradedAt;

  bool get isEssay => question.questionType.isSubjective;

  /// Whether anything was stored for this question. An unanswered question is
  /// not a wrong answer: it never scored, and the review says so.
  bool get isAnswered => rawAnswer != null;

  /// True when an essay already carries marks.
  bool get isMarked => awarded != null;

  double get points => question.points;

  /// The student's answer as a lecturer reads it. Multiple choice is rendered as
  /// the option *text* (a stored index means nothing on its own), a tapped
  /// true/false as the word, and a typed answer as written.
  String? get answerText {
    final raw = rawAnswer;
    if (raw == null) return null;

    if (question.questionType.isMultipleChoice) {
      final index = raw is num ? raw.toInt() : int.tryParse('$raw');
      if (index == null) return '$raw';
      if (index < 0 || index >= question.options.length) {
        // A stored index this paper no longer has (its options were edited after
        // the attempt closed). Shown rather than hidden: dropping it silently
        // would make a wrong answer look unanswered.
        return 'Option ${index + 1} (no longer on the paper)';
      }
      return question.options[index];
    }

    final text = '$raw'.trim();
    if (question.questionType.isTrueFalse) {
      return switch (text.toLowerCase()) {
        'true' => 'True',
        'false' => 'False',
        _ => text,
      };
    }
    return text;
  }

  /// The right answer, for the shapes that have one. Null for an essay, which
  /// has no key at all.
  String? get expectedText =>
      question.questionType.isSubjective ? null : question.answerSummary;

  /// The automatic verdict — see the class comment. Null for an essay (nothing
  /// automatic decides it) and for an unanswered question (which did not score,
  /// rather than scoring zero).
  bool? get isCorrect {
    if (isEssay || !isAnswered) return null;

    switch (question.questionType) {
      case QuestionType.multipleChoice:
        final index = rawAnswer is num
            ? (rawAnswer as num).toInt()
            : int.tryParse('$rawAnswer');
        final expected = question.correctOption;
        if (index == null || expected == null) return false;
        return index == expected;
      case QuestionType.trueFalse:
      case QuestionType.fillInTheBlank:
        // The comparison the server makes: trimmed and case-insensitive, so
        // "  http " counts for "HTTP".
        final key = (question.correctTextAnswer ?? '').trim().toLowerCase();
        if (key.isEmpty) return false;
        return '$rawAnswer'.trim().toLowerCase() == key;
      case QuestionType.subjective:
        return null;
    }
  }

  @override
  List<Object?> get props => [question, rawAnswer, awarded, feedback, gradedAt];
}

/// One attempt as the grading screen needs it: the submission, the student's
/// name, and every question of the paper with the answer stored under it.
class AttemptGrading extends Equatable {
  const AttemptGrading({
    required this.submission,
    required this.studentName,
    required this.lines,
  });

  final Submission submission;

  /// `profiles.full_name` of the student, or a short form of their id when the
  /// profile row could not be read — never blank, because the screen's whole job
  /// is to say whose paper this is.
  final String studentName;

  final List<GradeLine> lines;

  /// The essays, in paper order: the only lines a person can mark.
  List<GradeLine> get essayLines =>
      lines.where((line) => line.isEssay).toList(growable: false);

  int get essaysGraded => essayLines.where((line) => line.isMarked).length;

  int get essaysToGrade => essayLines.length - essaysGraded;

  /// An attempt is waiting for marks while any essay of its paper is unmarked.
  /// Nothing in the status column says this — which is exactly why it is derived
  /// from the rows rather than from `status`.
  bool get isAwaitingMarks => essaysToGrade > 0;

  /// What the attempt can be worth: every question's weight added up.
  double get maxScore =>
      lines.fold<double>(0, (total, line) => total + line.points);

  /// The server's running total (automatic marks plus whatever has been
  /// awarded), as `exam_submissions.score` holds it.
  double? get score => submission.score?.toDouble();

  /// The marks this screen is about to send, keyed by question id in the shape
  /// `grade_submission()` takes. Unmarked essays are left out — the RPC only
  /// touches what it is handed, and an empty object is a no-op rather than an
  /// instruction to clear somebody's marks.
  Map<String, dynamic> gradePayload() => <String, dynamic>{
        for (final line in essayLines)
          if (line.isMarked)
            line.question.id: <String, dynamic>{
              'awarded': line.awarded,
              'feedback': line.feedback ?? '',
            },
      };

  @override
  List<Object?> get props => [submission, studentName, lines];
}

/// The outcome of a save, straight from the RPC's own row: the recomputed total
/// and how much of the paper is marked. The screen reports these rather than its
/// own arithmetic, so what a lecturer reads is what the database stored.
class GradingOutcome extends Equatable {
  const GradingOutcome({
    required this.finalScore,
    required this.gradedAnswers,
    required this.ungradedAnswers,
  });

  factory GradingOutcome.fromMap(Map<String, dynamic> map) => GradingOutcome(
        finalScore: (map['final_score'] as num?)?.toDouble() ?? 0,
        gradedAnswers: (map['graded_answers'] as num?)?.toInt() ?? 0,
        ungradedAnswers: (map['ungraded_answers'] as num?)?.toInt() ?? 0,
      );

  final double finalScore;
  final int gradedAnswers;
  final int ungradedAnswers;

  /// What the console says afterwards, in one sentence.
  String get summary => ungradedAnswers == 0
      ? 'Marked. The attempt now totals ${formatMarks(finalScore)}.'
      : 'Saved. ${formatMarks(finalScore)} so far, $ungradedAnswers '
          '${ungradedAnswers == 1 ? 'essay' : 'essays'} still to mark.';

  @override
  List<Object?> get props => [finalScore, gradedAnswers, ungradedAnswers];
}

/// Marks are whole numbers in a lecture hall and fractions on a rubric, so they
/// print without a trailing `.0` unless there is one to show.
String formatMarks(double marks) =>
    marks == marks.roundToDouble() ? '${marks.round()}' : marks.toString();
