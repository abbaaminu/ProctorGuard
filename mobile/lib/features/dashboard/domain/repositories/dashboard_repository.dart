import '../entities/analytics_report.dart';
import '../entities/submission_reset_result.dart';

class DashboardException implements Exception {
  const DashboardException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class DashboardRepository {
  Future<AnalyticsReport> getAnalytics();

  /// Deletes the attempt and its cascaded incidents so the student may retry.
  /// Snapshot objects are removed through Storage after the database delete.
  Future<SubmissionResetResult> resetSubmission(String submissionId);

  /// Decides a `flagged_for_review` attempt: [decision] is `'disqualify'` or
  /// `'clear'`, and [note] is recorded on the review trail.
  ///
  /// Calls `resolve_flagged_attempt`, so the tier check, the audit row and the
  /// resulting status are the server's - the console only offers the control. The
  /// new status is returned as the server wrote it (`disqualified` / `submitted`,
  /// or the stored status when the attempt was already resolved).
  ///
  /// Throws [DashboardException] when the server refuses (a lecturer on somebody
  /// else's paper, an attempt that is not flagged).
  Future<String> resolveFlaggedAttempt(
    String submissionId, {
    required String decision,
    String? note,
  });
}
