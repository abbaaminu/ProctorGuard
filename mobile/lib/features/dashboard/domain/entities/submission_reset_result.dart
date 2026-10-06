/// The outcome of a supervisor's attempt reset: what was removed, and what was
/// not.
///
/// The reset is destructive and already committed by the time this is returned
/// — the attempt row is gone, and its `proctoring_logs` cascaded with it — so a
/// failure *after* that point cannot be reported by throwing: the console would
/// read it as "the reset failed" and offer a retry against an attempt that no
/// longer exists. Both warnings therefore ride along on the successful outcome,
/// and each one says exactly which half of the job did not finish.
class SubmissionResetResult {
  const SubmissionResetResult({
    required this.incidents,
    required this.snapshots,
    this.storageWarning,
    this.auditWarning,
  });

  /// `proctoring_logs` rows the cascade removed with the attempt.
  final int incidents;

  /// Snapshot objects the Storage purge removed. Only what was *actually*
  /// removed is counted, so a failed purge reads as [storageWarning] plus zero
  /// rather than as a number that never happened.
  final int snapshots;

  /// Set when the attempt was deleted but its snapshot objects could not be
  /// removed from Storage, leaving images in the bucket with no row pointing at
  /// them.
  final String? storageWarning;

  /// Set when the attempt was deleted but the audit row recording *who* did it
  /// could not be written to `public.session_reset_logs` (schema.sql §7). The
  /// reset stands; the trail has a gap.
  final String? auditWarning;
}
