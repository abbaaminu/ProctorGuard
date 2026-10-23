import '../../domain/entities/attempt_grading.dart';
import '../entities/authored_exam.dart';
import '../entities/authored_question.dart';

/// A refusal from the authoring or grading endpoints, already written for a
/// lecturer to read (the console renders [message] verbatim).
class AuthoringException implements Exception {
  const AuthoringException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The lecturer console's data access: the papers an account owns, the questions
/// inside one, and the marks on the attempts handed in against it.
///
/// Owner-scoped by the database rather than by this interface — `exams` and
/// `questions` both key their write policies on `created_by = auth.uid()` — so
/// every method here is a thin, honest wrapper: it never checks permissions
/// itself, it reports what the server answered.
abstract class QuestionAuthoringRepository {
  /// The papers this account created, newest first. Published papers by other
  /// authors are deliberately not in this list: this is a *mine* view, and
  /// `exams_select` would otherwise hand staff every paper in the institution.
  Future<List<AuthoredExam>> listMyExams();

  /// Creates a draft (or published) paper owned by the caller. The server fills
  /// `created_by` from the session; this never sends it.
  ///
  /// [startsAt] / [endsAt] are the *optional* window (`exams.starts_at` /
  /// `exams.ends_at`), sent only when they are set: leaving a bound out stores
  /// NULL, which is the unscheduled paper the column defaults to. They are
  /// instants, so the implementation sends them as UTC; the console's pickers
  /// produce local ones and the two ends are validated against each other before
  /// this is called (the database's `exams_window_ordered` check is the second
  /// line of defence, not the first).
  /// [faculty] / [department] / [level] are the paper's target cohort, sent only
  /// when set. An omitted label is stored NULL, and NULL means *not narrowed
  /// here*: `exams_select` only restricts the labels a paper actually states, so
  /// an untargeted paper is offered exactly as it was before targeting existed.
  /// The strings come from `AcademicCatalog` in the form, but nothing here
  /// enforces that -- a cohort spelling imported from a roster is still a valid
  /// label.
  Future<AuthoredExam> createExam({
    required String title,
    required int durationMinutes,
    required bool isPublished,
    DateTime? startsAt,
    DateTime? endsAt,
    String? faculty,
    String? department,
    String? level,
  });

  /// Publishes a paper (making it visible to students and startable) or takes it
  /// back to draft. Unpublishing does not disturb an attempt already in
  /// progress — only new starts are refused.
  Future<void> setPublished({
    required String examId,
    required bool isPublished,
  });

  /// Deletes a paper **and everything under it** — its questions, every attempt
  /// against it, their marks and their incident rows, all by cascade. The
  /// console asks for confirmation in those words.
  Future<void> deleteExam(String examId);

  /// The paper's questions in the order they were written, with their answer
  /// keys: the one screen that is allowed to hold a key.
  Future<List<AuthoredQuestion>> listQuestions(String examId);

  Future<AuthoredQuestion> createQuestion({
    required String examId,
    required QuestionDraft draft,
  });

  Future<AuthoredQuestion> updateQuestion({
    required String questionId,
    required QuestionDraft draft,
  });

  Future<void> deleteQuestion(String questionId);

  /// Every handed-in attempt against [examId], newest first, each carrying the
  /// whole paper so the grading screen can show every answer next to its marks.
  /// Attempts still in progress are not listed: their answers can still change.
  Future<List<AttemptGrading>> listAttempts(String examId);

  /// Saves the marks in [grades] — a JSON object keyed by question id — and
  /// returns what the server made of them. Only the paper's owner (or an
  /// administrator) may call this; the server refuses anybody else.
  Future<GradingOutcome> saveGrades({
    required String submissionId,
    required Map<String, dynamic> grades,
  });
}
