import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/proctor_consent.dart';
import '../../domain/repositories/consent_repository.dart';

/// The Supabase-backed consent repository.
///
/// Two reads and one RPC, all against the objects
/// `supabase/migrations/20261106090000_proctoring_consents.sql` creates. The
/// reads go through PostgREST so RLS decides what the student may see
/// (`consents_select_own_or_supervisor`); the write goes through
/// `record_consent()`, which is the only writer of `proctoring_consents` - a
/// direct insert would fail the "own row only" policy anyway, and would not stamp
/// the transport User-Agent.
class ConsentRepositoryImpl implements ConsentRepository {
  ConsentRepositoryImpl(this._client);

  final SupabaseClient _client;

  @override
  Future<bool> hasCurrentConsent(String examId) async {
    final uid = _client.auth.currentUser?.id;
    // No session, no acceptance - and no request worth making: the insert policy
    // would refuse everything anyway.
    if (uid == null) return false;

    final rows = await _client
        .from('proctoring_consents')
        .select('id')
        .eq('student_id', uid)
        .eq('consent_version', ProctorConsentConfig.version)
        // Either shape the policy accepts: this paper, or a general acceptance.
        .or('exam_id.eq.$examId,exam_id.is.null')
        .limit(1);
    return (rows as List).isNotEmpty;
  }

  @override
  Future<String?> currentServerVersion() async {
    final row = await _client
        .from('proctoring_consent_config')
        .select('current_version')
        .eq('id', 1)
        .maybeSingle();
    return row?['current_version'] as String?;
  }

  @override
  Future<ConsentRecord> recordConsent({
    String? examId,
    required String version,
  }) async {
    // The argument names are the RPC's own (`p_exam_id`, `p_version`); the
    // contract is pinned in `mobile/test/schema_contract_test.dart`.
    final response = await _client.rpc('record_consent', params: {
      'p_exam_id': examId,
      'p_version': version,
    });
    return ConsentRecord.fromRpc(response);
  }
}
