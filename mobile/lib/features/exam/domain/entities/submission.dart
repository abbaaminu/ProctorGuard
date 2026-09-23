import 'package:equatable/equatable.dart';

enum SubmissionStatus {
  ongoing,
  submitted,
  disqualified;

  static SubmissionStatus fromDb(String v) => switch (v) {
        'ongoing' => SubmissionStatus.ongoing,
        'submitted' => SubmissionStatus.submitted,
        'disqualified' => SubmissionStatus.disqualified,
        _ => throw ArgumentError('Unknown status: $v'),
      };

  String get dbValue => name;
}

class Submission extends Equatable {
  final String id;
  final String studentId;
  final String examId;
  final Map<String, dynamic> answers;
  final SubmissionStatus status;
  final num? score;

  const Submission({
    required this.id,
    required this.studentId,
    required this.examId,
    required this.answers,
    required this.status,
    this.score,
  });

  factory Submission.fromMap(Map<String, dynamic> map) => Submission(
        id: map['id'] as String,
        studentId: map['student_id'] as String,
        examId: map['exam_id'] as String,
        answers: Map<String, dynamic>.from(map['answers'] as Map? ?? {}),
        status: SubmissionStatus.fromDb(map['status'] as String),
        score: map['score'] as num?,
      );

  @override
  List<Object?> get props => [id, studentId, examId, answers, status, score];
}
