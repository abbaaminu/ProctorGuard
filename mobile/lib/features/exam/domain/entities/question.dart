import 'package:equatable/equatable.dart';

/// `public.questions.question_type` — the two shapes one question row can take.
enum QuestionType {
  /// `options` are the tap targets; the answer is an option index.
  multipleChoice,

  /// No options: the student types an answer into a text field and the server
  /// grades it case-insensitively after trimming.
  fillInTheBlank;

  static QuestionType fromDb(String? value) => switch (value) {
        'fill_in_the_blank' => QuestionType.fillInTheBlank,
        'multiple_choice' => QuestionType.multipleChoice,
        // An unrecognised type must not take the exam screen down. The question
        // still renders (and, with no options, simply cannot be answered)
        // instead of throwing out of the question feed.
        _ => QuestionType.multipleChoice,
      };

  String get dbValue => switch (this) {
        QuestionType.multipleChoice => 'multiple_choice',
        QuestionType.fillInTheBlank => 'fill_in_the_blank',
      };
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
        // A fill-in-the-blank row stores an empty array (or, on a pre-types
        // row, nothing at all), so a missing `options` is an empty list rather
        // than a crash.
        options: List<String>.from((map['options'] as List?) ?? const <String>[]),
      );

  bool get isFillInTheBlank => questionType == QuestionType.fillInTheBlank;

  @override
  List<Object?> get props => [id, examId, questionText, questionType, options];
}
