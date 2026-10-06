import 'package:equatable/equatable.dart';

/// `public.questions.question_type` — the four shapes one question row can take.
enum QuestionType {
  /// `options` are the tap targets; the answer is an option index. Graded
  /// automatically by `submit_exam()`.
  multipleChoice,

  /// A statement the student accepts or rejects. `options` is empty; the answer
  /// key is the word 'true' or 'false' in `correct_text_answer`, and the
  /// student's own answer is the same word, written through
  /// `merge_submission_text_answer` as a JSON string. Graded automatically.
  trueFalse,

  /// No options: the student types an answer into a text field and the server
  /// grades it case-insensitively after trimming. Graded automatically.
  fillInTheBlank,

  /// A free-text answer with **no** answer key at all: an essay. Nothing grades
  /// it automatically by design — the paper's owner reads it and awards the
  /// marks through `grade_submission()`, which is why an attempt containing one
  /// appears in the lecturer console's marking list.
  subjective;

  static QuestionType fromDb(String? value) => switch (value) {
        'true_false' => QuestionType.trueFalse,
        'fill_in_the_blank' => QuestionType.fillInTheBlank,
        'multiple_choice' => QuestionType.multipleChoice,
        'subjective' => QuestionType.subjective,
        // An unrecognised type must not take the exam screen down. The question
        // still renders (and, with no options, simply cannot be answered)
        // instead of throwing out of the question feed. The answer-key shape
        // check in the database is what stops a row like that existing.
        _ => QuestionType.multipleChoice,
      };

  String get dbValue => switch (this) {
        QuestionType.multipleChoice => 'multiple_choice',
        QuestionType.trueFalse => 'true_false',
        QuestionType.fillInTheBlank => 'fill_in_the_blank',
        QuestionType.subjective => 'subjective',
      };

  /// Name for a lecturer-facing screen (the authoring console's type picker and
  /// the review grid's "by hand" rows).
  String get label => switch (this) {
        QuestionType.multipleChoice => 'Multiple choice',
        QuestionType.trueFalse => 'True / false',
        QuestionType.fillInTheBlank => 'Fill in the blank',
        QuestionType.subjective => 'Essay',
      };

  /// How the type is marked, in one word: the console labels a paper with it so
  /// "why is this attempt still waiting" is answerable at a glance.
  String get markingLabel =>
      isAutoGraded ? 'Marked automatically' : 'Marked by hand';

  bool get isMultipleChoice => this == QuestionType.multipleChoice;

  bool get isTrueFalse => this == QuestionType.trueFalse;

  bool get isFillInTheBlank => this == QuestionType.fillInTheBlank;

  /// An essay: no key, so a person awards the marks.
  bool get isSubjective => this == QuestionType.subjective;

  /// Whether `submit_exam()` can score this shape on its own. True for every
  /// type but [subjective], and the reason an attempt with an essay in it is
  /// only ever *partly* graded when the student hands it in.
  bool get isAutoGraded => !isSubjective;

  /// Whether the student answers this by typing (rather than by tapping an
  /// option), which is what decides the input widget and the answer-write RPC.
  /// A true/false tap is typed as far as the database is concerned: it stores
  /// the word, not an option index.
  bool get usesTextAnswer =>
      this == QuestionType.fillInTheBlank || this == QuestionType.subjective;
}

/// Uses the `questions_public` view — never carries `correct_option` or
/// `correct_text_answer` on the client, so grading logic cannot leak into the
/// student's device.
class Question extends Equatable {
  final String id;
  final String examId;
  final String questionText;
  final QuestionType questionType;
  final List<String> options;

  const Question({
    required this.id,
    required this.examId,
    required this.questionText,
    this.questionType = QuestionType.multipleChoice,
    this.options = const <String>[],
  });

  factory Question.fromMap(Map<String, dynamic> map) => Question(
        id: map['id'] as String,
        examId: map['exam_id'] as String,
        questionText: map['question_text'] as String,
        questionType: QuestionType.fromDb(map['question_type'] as String?),
        // A typed row stores an empty array (or, on a pre-types row, nothing at
        // all), so a missing `options` is an empty list rather than a crash.
        options:
            List<String>.from((map['options'] as List?) ?? const <String>[]),
      );

  bool get isFillInTheBlank => questionType == QuestionType.fillInTheBlank;

  bool get isTrueFalse => questionType == QuestionType.trueFalse;
  bool get isSubjective => questionType == QuestionType.subjective;

  /// True when the student answers by typing: the two shapes that share the
  /// text field, the "Save & next" action and `merge_submission_text_answer`.
  /// Deliberately excludes true/false, which is a pair of tap targets even
  /// though the server stores its answer as a word.
  bool get usesTextAnswer => questionType.usesTextAnswer;

  @override
  List<Object?> get props => [id, examId, questionText, questionType, options];
}
