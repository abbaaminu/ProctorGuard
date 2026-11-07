import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/heartbeat.dart';
import '../../domain/entities/violation.dart';
import '../../domain/repositories/proctoring_repository.dart';

/// Data-layer adapter for the unified production schema.
///
/// Contract this file depends on (`supabase/schema.sql`):
///  * `public.register_violation(p_submission_id uuid, p_action_type text,
///    p_snapshot_url text default null, p_client_timestamp timestamptz default
///    null, p_client_event_id uuid default null) returns table(warning_count int,
///    disqualified boolean, flagged boolean)` — the RPC owns the insert, the
///    weighted count and the automatic flip to `flagged_for_review`.
///  * `public.proctoring_logs(submission_id uuid, action_type text,
///    timestamp timestamptz default now(), snapshot_url text)`; the client never
///    inserts into it directly so the escalation rule can't be bypassed.
///  * `action_type` is a text check constraint whose allowed values are produced by
///    [ViolationType.dbValue].
///  * `public.record_heartbeat(p_submission_id uuid, p_camera_ok boolean default
///    true, p_monitoring_ok boolean default true, p_app_version text default null,
///    p_client_time timestamptz default null, p_client_event_id uuid default null)
///    returns table(outcome text, recorded_at timestamptz, beat_count int)` — the
///    counterpart of `register_violation`: it records that the client was *there*,
///    re-checks ownership and `status = 'ongoing'`, rate-limits to one stored beat
///    per 8s and stamps `exam_submissions.last_heartbeat_at`. `proctor_heartbeats`
///    has no insert policy at all, so this RPC is the only way in.
class ProctoringRepositoryImpl implements ProctoringRepository {
  final SupabaseClient _client;
  ProctoringRepositoryImpl(this._client);

  @override
  Future<({int warningCount, bool disqualified, bool flagged})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async {
    // p_snapshot_url is optional server-side; when the evidence upload failed
    // (or the session is a mock one) it is null and the log row just carries
    // no picture.
    //
    // p_client_timestamp and p_client_event_id are what make the offline retry
    // honest: the first records *when the violation happened* (the row's
    // `timestamp` stays the server's receipt time, which is the column the
    // dashboard orders by), and the second is the idempotency key that stops a
    // replayed row from becoming a second strike (see the unique index on
    // proctoring_logs.client_event_id).
    final rows = await _client.rpc('register_violation', params: {
      'p_submission_id': submissionId,
      'p_action_type': violation.type.dbValue,
      'p_snapshot_url': violation.snapshotUrl,
      'p_client_timestamp': violation.timestamp.toUtc().toIso8601String(),
      'p_client_event_id': violation.clientEventId,
    }) as List<dynamic>;

    final row = rows.first as Map<String, dynamic>;
    return (
      warningCount: row['warning_count'] as int,
      disqualified: row['disqualified'] as bool,
      // Absent on a server that predates the weighted rule: an old backend can
      // only answer "disqualified or not", and guessing `flagged` from the count
      // would end sessions the backend has not ended.
      flagged: row['flagged'] as bool? ?? false,
    );
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) {
    return _client
        .from('proctoring_logs')
        .stream(primaryKey: ['id'])
        .eq('submission_id', submissionId)
        .order('timestamp');
  }

  @override
  Future<HeartbeatAck> recordHeartbeat({
    required String submissionId,
    bool cameraOk = true,
    bool monitoringOk = true,
    String? appVersion,
    DateTime? clientTime,
    String? clientEventId,
  }) async {
    // Same argument names as the SQL, and every one of them is a plain value: the
    // RPC decides the outcome, so there is nothing here for a patched client to
    // gain by lying beyond the two booleans - which are the point of the feature
    // and are documented as unverifiable in the README.
    final rows = await _client.rpc('record_heartbeat', params: {
      'p_submission_id': submissionId,
      'p_camera_ok': cameraOk,
      'p_monitoring_ok': monitoringOk,
      'p_app_version': appVersion,
      'p_client_time': clientTime?.toUtc().toIso8601String(),
      'p_client_event_id': clientEventId,
    }) as List<dynamic>;

    final row = rows.first as Map<String, dynamic>;
    return HeartbeatAck(
      outcome: HeartbeatOutcome.fromDb(row['outcome'] as String?),
      // Read defensively: the columns are part of the contract, but a beat that
      // reached the server has already done its job, and failing to parse the
      // answer would turn that success into a failure the retry loop acts on.
      recordedAt: switch (row['recorded_at']) {
        final String value => DateTime.tryParse(value),
        final DateTime value => value,
        _ => null,
      },
      beatCount: switch (row['beat_count']) {
        final int value => value,
        final num value => value.toInt(),
        final String value => int.tryParse(value),
        _ => null,
      },
    );
  }
}
