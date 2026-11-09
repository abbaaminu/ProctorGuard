import '../../../exam/domain/entities/exam.dart';
import '../entities/supervisor_assignment.dart';

/// A failure the administrator should read verbatim.
///
/// [message] is always user-facing prose: the repository translates
/// PostgREST/network failures into it so the page can put it straight in a SnackBar
/// instead of the raw server string — the same shape `AdminAccountException` and
/// `DashboardException` use.
class SupervisionException implements Exception {
  const SupervisionException(this.message);

  final String message;

  @override
  String toString() => 'SupervisionException: $message';
}

/// Who supervises which paper — the table behind Task 3's scope.
///
/// An **administrator** is the only tier that writes it: the insert/delete policies
/// on `public.supervisor_exam_assignments` are `is_admin()`, and a
/// `guard_supervisor_assignment()` trigger refuses a row whose account is not a
/// `supervisor`. The app cannot widen that — this repository only offers the
/// controls, the database decides.
///
/// A **supervisor** reads their own rows (`supervisor_assignments_select_own_or_admin`)
/// — which is what the supervisor console's list would need if it ever wanted to
/// explain an empty state beyond "nothing is assigned to you" — and reaches the
/// papers, attempts, incidents, stills and decisions those rows name, because every
/// policy asks `can_supervise_exam()`.
abstract class SupervisionRepository {
  /// Every assignment the caller may read: all of them for an administrator, the
  /// caller's own for a supervisor, none for a lecturer.
  Future<List<SupervisorAssignment>> listAssignments();

  /// Every paper the caller may see, **drafts included** (`exams_select` gives an
  /// administrator every row). Drafts matter here: a sitting is usually invigilated
  /// before its paper is published, and an assignment made that morning should not
  /// have to wait for the publication.
  Future<List<Exam>> listExams();

  /// Grants [supervisorId] the paper [examId].
  ///
  /// Throws [SupervisionException] when the caller is not an administrator, when the
  /// account is not a supervisor (the guard's refusal), or when the request never
  /// reached the server. Assigning the same pair twice is a no-op at the database
  /// (the primary key is `(exam_id, supervisor_id)`).
  Future<void> assign({required String examId, required String supervisorId});

  /// Revokes it. A delete of zero rows (already revoked, or not the caller's to
  /// touch) is not an error — the page refetches and shows what the server holds.
  Future<void> unassign({required String examId, required String supervisorId});
}
