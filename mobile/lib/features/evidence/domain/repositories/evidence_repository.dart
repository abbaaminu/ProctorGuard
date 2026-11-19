import '../entities/attempt_evidence.dart';

/// What the Evidence screen asks of the database: the incidents of one paper, and
/// a signed URL for one still when it is about to be shown.
///
/// Two methods, because they answer two different questions and fail
/// independently: the list is one RPC (and is what the scope is enforced on),
/// while a still is a Storage signature that can fail on its own without hiding
/// the incident row it belongs to.
abstract class EvidenceRepository {
  /// Every incident on one paper, grouped per attempt.
  ///
  /// The server decides what the caller may see (`can_reach_exam`); this call
  /// cannot widen it, so an empty list means "no incidents, or none of your
  /// business" and the page does not need to tell the two apart.
  Future<List<AttemptEvidence>> listExamEvidence(String examId);

  /// A short-lived URL for one stored still, or null when it cannot be minted.
  ///
  /// [snapshotUrl] is the `proctoring_logs.snapshot_url` value as the RPC
  /// returned it: the bucket-relative path this build writes, or an older public
  /// URL. Both are normalised before signing. Never throws: a still that cannot
  /// be signed is a tile that says so, not a page that fails.
  Future<String?> signedStillUrl(String snapshotUrl);
}

/// What the Evidence screen reports when a read fails.
///
/// Carries the sentence to show rather than a code, the same shape as
/// `AuthoringException` and `DashboardException`: the page prints
/// [message] and offers a retry, and nothing above it has to interpret a
/// transport error.
class EvidenceException implements Exception {
  const EvidenceException(this.message);

  final String message;

  @override
  String toString() => message;
}
