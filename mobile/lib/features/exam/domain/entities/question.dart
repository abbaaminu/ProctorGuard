import 'package:equatable/equatable.dart';

/// Uses the `questions_public` view — never carries `correct_option` on the
/// client, so grading logic cannot leak into the student's device.
class Question extends Equatable {
  final String id;
  final String examId;
  final String questionText;
  final List<String> options;

  const Question({
    required this.id,
    required this.examId,
    required this.questionText,
    required this.options,
  });

  factory Question.fromMap(Map<String, dynamic> map) => Question(
        id: map['id'] as String,
        examId: map['exam_id'] as String,
        questionText: map['question_text'] as String,
        options: List<String>.from(map['options'] as List),
      );

  @override
  List<Object?> get props => [id, examId, questionText, options];
}
