import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/violation.dart';
import '../../domain/repositories/proctoring_repository.dart';

/// Data-layer adapter for the unified production schema.
///
/// Contract this file depends on (`supabase/schema.sql`):
///  * `public.register_violation(p_submission_id uuid, p_action_type text,
///    p_snapshot_url text default null) returns table(warning_count int,
///    disqualified boolean)` — the RPC owns the insert, the 3-strike count and
///    the automatic `exam_submissions.status = 'disqualified'` flip.
///  * `public.proctoring_logs(submission_id uuid, action_type text,
///    timestamp timestamptz default now(), snapshot_url text)`; the client never
///    inserts into it directly so the strike rule can't be bypassed.
///  * `action_type` is a text check constraint whose five allowed values are
///    produced by [ViolationType.dbValue].
class ProctoringRepositoryImpl implements ProctoringRepository {
  final SupabaseClient _client;
  ProctoringRepositoryImpl(this._client);

  @override
  Future<({int warningCount, bool disqualified})> logViolation({
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
}
