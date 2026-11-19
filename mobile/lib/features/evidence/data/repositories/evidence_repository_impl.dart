import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/supabase_service.dart';
import '../../../../core/utils/proctor_log.dart';
import '../../../../core/utils/read_timeout.dart';
import '../../domain/entities/attempt_evidence.dart';
import '../../domain/repositories/evidence_repository.dart';

/// The Supabase-backed Evidence repository.
///
/// One RPC for the whole paper (`public.exam_evidence`, see
/// `supabase/migrations/20261114090000_exam_evidence.sql`) and one Storage call
/// per still, made only when a tile is actually built - so opening a paper with
/// sixty incidents does not mint sixty URLs that all expire before anybody
/// scrolls to the twentieth.
class EvidenceRepositoryImpl implements EvidenceRepository {
  EvidenceRepositoryImpl(this._client, {this.readTimeout = defaultReadTimeout});

  final SupabaseClient _client;

  /// The deadline on the one read this repository makes. Per call, not per
  /// attempt: the function answers a whole paper in one round trip, so there is
  /// nothing to page and nothing to keep alive across pages. See
  /// `core/utils/read_timeout.dart`.
  final Duration readTimeout;

  @override
  Future<List<AttemptEvidence>> listExamEvidence(String examId) async {
    try {
      final rows = await withReadTimeout(() async {
        final answer = await _client.rpc(
          'exam_evidence',
          params: <String, dynamic>{'p_exam_id': examId},
        );
        return (answer as List<dynamic>).cast<Map<String, dynamic>>();
      }, timeout: readTimeout);
      return AttemptEvidence.group(rows);
    } on PostgrestException catch (error) {
      throw EvidenceException(_friendly(error));
    } on ReadTimeoutException catch (error) {
      throw EvidenceException(error.message);
    } catch (error) {
      throw EvidenceException('Could not read the evidence: $error');
    }
  }

  @override
  Future<String?> signedStillUrl(String snapshotUrl) async {
    final object = SupabaseService.snapshotObjectPath(snapshotUrl);
    if (object == null) return null;

    try {
      // The bucket's own policy is the authority on this signature, not this
      // client: `createSignedUrl` asks Storage for a URL for an object the caller
      // may read, and Storage refuses the rest.
      return await _client.storage
          .from(SupabaseService.snapshotBucket)
          .createSignedUrl(object, SupabaseService.snapshotUrlTtl.inSeconds);
    } catch (error) {
      proctorLog('Could not sign evidence still $object: $error');
      return null;
    }
  }

  /// A read that failed, in words the screen can print.
  ///
  /// The PGRST202 case gets its own sentence: a project that has not run the
  /// evidence migration answers "Could not find the function
  /// public.exam_evidence", and the one useful thing to say is which file to
  /// apply - the same courtesy `SupabaseService.claimSession` pays for
  /// `20261111090000_single_session.sql`.
  static String _friendly(PostgrestException error) {
    if (error.code == 'PGRST202') {
      return 'This project has no exam_evidence() yet — apply '
          'supabase/migrations/20261114090000_exam_evidence.sql.';
    }
    return 'Could not read the evidence: ${error.message}';
  }
}
