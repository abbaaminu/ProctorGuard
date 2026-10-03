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
}
