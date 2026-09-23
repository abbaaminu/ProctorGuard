import '../entities/violation.dart';

abstract class ProctoringRepository {
  /// Calls the `register_violation` RPC so the 3-strike disqualification
  /// rule is enforced server-side and can't be bypassed by a patched client.
  /// Returns the authoritative warning count and whether the backend has
  /// already flipped the submission to 'disqualified'.
  Future<({int warningCount, bool disqualified})> logViolation({
    required String submissionId,
    required Violation violation,
  });

  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId);
}
