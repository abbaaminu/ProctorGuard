import '../entities/heartbeat.dart';
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

  /// Reports that this client is still running and still watching: calls
  /// `record_heartbeat`, the only writer of `proctor_heartbeats` and of
  /// `exam_submissions.last_heartbeat_at`.
  ///
  /// The RPC - not this client - decides whether the beat is stored: it re-checks
  /// that [submissionId] belongs to the caller, refuses an attempt that is no
  /// longer `ongoing`, stores at most one beat per 8 seconds, and dedupes on
  /// [clientEventId]. Two of those answers (`duplicate`, `throttled`) are normal;
  /// see [HeartbeatOutcome].
  ///
  /// [cameraOk] and [monitoringOk] are what make a heartbeat more than a ping: a
  /// beat with `cameraOk: false` is "the monitor is up but it is blind", which an
  /// empty violation feed used to hide completely.
  ///
  /// Throws when the beat could not be delivered at all, so the caller can count
  /// the failure and try again on its next tick. Nothing here is queued for later:
  /// see `ProctoringHeartbeatService` for why a replayed beat is worse than a
  /// missing one.
  Future<HeartbeatAck> recordHeartbeat({
    required String submissionId,
    bool cameraOk = true,
    bool monitoringOk = true,
    String? appVersion,
    DateTime? clientTime,
    String? clientEventId,
  });
}
