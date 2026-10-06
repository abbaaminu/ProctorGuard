import 'package:equatable/equatable.dart';

import '../../../exam/domain/entities/exam.dart';

/// One exam as the lecturer console lists it: the `public.exams` row plus the
/// two counts the tile shows.
///
/// Both counts come from PostgREST's embedded aggregates in the same round trip
/// (`.select('…, questions(count), exam_submissions(count)')`), which is also why
/// they are plain numbers here rather than lists the console would have to
/// flatten.
class AuthoredExam extends Equatable {
  const AuthoredExam({
    required this.exam,
    required this.questionCount,
    required this.attemptCount,
  });

  factory AuthoredExam.fromMap(Map<String, dynamic> map) => AuthoredExam(
        exam: Exam.fromMap(map),
        questionCount: _count(map['questions']),
        attemptCount: _count(map['exam_submissions']),
      );

  final Exam exam;
  final int questionCount;
  final int attemptCount;

  /// A paper with nothing in it cannot be sat: publishing one would put an exam
  /// in the students' list whose session has no questions. The console asks this
  /// before offering "Publish", so the rule is answered once, in the model.
  bool get hasQuestions => questionCount > 0;

  /// Whether the console should offer to publish this paper at all — a published
  /// exam is always allowed back to draft (unpublishing hides it from students
  /// who have not started; it does not disturb an attempt already in progress).
  bool get canPublish => exam.isPublished || hasQuestions;

  String get statusLabel => exam.isPublished ? 'Published' : 'Draft';

  /// "6 questions · 3 attempts", the tile's one line of counting.
  String get countsLabel =>
      '$questionCount ${questionCount == 1 ? 'question' : 'questions'} · '
      '$attemptCount ${attemptCount == 1 ? 'attempt' : 'attempts'}';

  /// PostgREST answers an embedded count as `[{'count': 3}]`; anything else
  /// (a plain number, a missing embed) is read as zero rather than throwing out
  /// of the list, because a count is decoration on a tile.
  static int _count(Object? value) {
    if (value is num) return value.toInt();
    if (value is List && value.isNotEmpty) {
      final first = value.first;
      if (first is Map && first['count'] is num) {
        return (first['count'] as num).toInt();
      }
    }
    return 0;
  }

  @override
  List<Object?> get props => [exam, questionCount, attemptCount];
}
