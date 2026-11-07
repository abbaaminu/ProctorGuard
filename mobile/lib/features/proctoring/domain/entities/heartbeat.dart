import 'package:equatable/equatable.dart';

/// What `public.record_heartbeat()` did with one beat.
///
/// All three mean the same thing to the attempt - *this client is alive right
/// now* - and the server stamps `exam_submissions.last_heartbeat_at` for every
/// one of them. They are kept apart because only one of them stored a row, and a
/// diagnostic that cannot tell "stored" from "replayed/too early" cannot answer
/// why a coverage report looks thin.
enum HeartbeatOutcome {
  /// A new row is in `proctor_heartbeats`.
  recorded,

  /// The `client_event_id` was already stored: a replay of a beat the server
  /// has. Nothing inserted, and nothing to fix.
  duplicate,

  /// Inside the server's rate-limit window (8s, against a 15s cadence), so the
  /// insert was skipped while `last_heartbeat_at` was still refreshed. Expected
  /// when two tabs, a resume and a timer collide; not an error.
  throttled,

  /// An outcome this client does not know - a newer server, or a response that
  /// lost the field. Treated as "the server answered", which is all a beat needs
  /// to prove, rather than as a failure.
  unknown;

  /// Maps the RPC's text back to the enum, never throwing: a beat that reached
  /// the server has done its job even if this build cannot name the answer.
  static HeartbeatOutcome fromDb(String? value) => switch (value) {
        'recorded' => HeartbeatOutcome.recorded,
        'duplicate' => HeartbeatOutcome.duplicate,
        'throttled' => HeartbeatOutcome.throttled,
        _ => HeartbeatOutcome.unknown,
      };

  /// Whether this beat added a row to the series. Only `recorded` does; the
  /// other two prove liveness without growing the table.
  bool get stored => this == HeartbeatOutcome.recorded;
}

/// The server's answer to one heartbeat.
///
/// Deliberately small: the client sends a beat to say "still here" and has no
/// decision to make on the reply. [beatCount] and [recordedAt] are for
/// diagnostics (the exam page can show "server time 14:22:31, 84 beats") and for
/// tests to prove the mapping, not for any branch in the app.
class HeartbeatAck extends Equatable {
  const HeartbeatAck({
    required this.outcome,
    this.recordedAt,
    this.beatCount,
  });

  final HeartbeatOutcome outcome;

  /// `received_at` of the beat the server matched - this one when it was stored,
  /// the earlier copy for a `duplicate`, the previous beat for a `throttled`.
  /// Null when the response could not be read.
  final DateTime? recordedAt;

  /// How many beats the server holds for the attempt after this call.
  final int? beatCount;

  /// Whether the attempt was alive for the server's purposes.
  ///
  /// Always true: a reply of any shape means the request reached the database
  /// and `record_heartbeat()` stamped `last_heartbeat_at`. The getter exists so
  /// call sites read as intent instead of as `ack.outcome != ...`.
  bool get provesLiveness => true;

  @override
  List<Object?> get props => [outcome, recordedAt, beatCount];
}
