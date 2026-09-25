import '../entities/exam.dart';
import '../entities/question.dart';
import '../entities/submission.dart';

abstract class ExamRepository {
  Future<List<Exam>> getPublishedExams();
  Future<List<Question>> getQuestions(String examId);

  /// Creates (or resumes, if one already exists — see `unique(student_id,
  /// exam_id)` in schema) the submission row for the current student.
  Future<Submission> startOrResumeSubmission(String examId);

  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  });

  /// Saves a free-text answer (fill-in-the-blank) through
  /// `merge_submission_text_answer`. The value is stored as a JSON string under
  /// the question id and graded case-insensitively after trimming by
  /// `submit_exam`.
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  });

  Future<void> submitExam(String submissionId);

  /// Used by the escalation logic in section 3 — auto-submits with
  /// 'disqualified' status. In practice this is a side effect of
  /// `register_violation` on the backend, so the client just refreshes
  /// local state after the RPC call rather than issuing a second write.
  Future<void> markDisqualified(String submissionId);
}
