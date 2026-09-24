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

  /// `exam_submissions.started_at` — the anchor the exam countdown runs on, so
  /// a resumed attempt keeps its remaining time instead of restarting.
  final DateTime? startedAt;

  const Submission({
    required this.id,
    required this.studentId,
    required this.examId,
    required this.answers,
    required this.status,
    this.score,
    this.startedAt,
  });

  factory Submission.fromMap(Map<String, dynamic> map) => Submission(
        id: map['id'] as String,
        studentId: map['student_id'] as String,
        examId: map['exam_id'] as String,
        answers: Map<String, dynamic>.from(map['answers'] as Map? ?? {}),
        status: SubmissionStatus.fromDb(map['status'] as String),
        score: map['score'] as num?,
        startedAt: parseTimestamp(map['started_at']),
      );

  /// PostgREST sends `timestamptz` as an ISO-8601 string; anything else (null,
  /// a shape change) is treated as "unknown" rather than throwing, because a
  /// missing clock must not take the exam screen down with it.
  static DateTime? parseTimestamp(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;

  @override
  List<Object?> get props =>
      [id, studentId, examId, answers, status, score, startedAt];
}
