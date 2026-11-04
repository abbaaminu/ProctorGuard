import '../entities/violation.dart';

abstract class ProctoringRepository {
  /// Calls the `register_violation` RPC, so the weighted escalation rule is
  /// enforced server-side and can't be bypassed by a patched client.
  ///
  /// Returns the authoritative evidence count, whether the attempt is
  /// `disqualified`, and whether it is `flagged_for_review` - the weighted
  /// threshold state, where the server has closed the sitting and a supervisor has
  /// to decide (`resolve_flagged_attempt`). `flagged` is read defensively (a server
  /// that predates the column answers without it) and is never inferred from the
  /// count: only the server knows the weights.
  Future<({int warningCount, bool disqualified, bool flagged})> logViolation({
    required String submissionId,
    required Violation violation,
  });

  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId);
}
