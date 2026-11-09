import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../exam/domain/entities/exam.dart';
import '../../domain/entities/supervisor_assignment.dart';
import '../../domain/repositories/supervision_repository.dart';

/// Supabase-backed [SupervisionRepository] — plain PostgREST calls, authorised
/// entirely by `public.supervisor_exam_assignments`'s own policies and by
/// `guard_supervisor_assignment()`.
///
/// There is no Edge Function here on purpose: assigning a paper is a row in a table
/// an administrator may write (`supervisor_assignments_insert_admin`), not an
/// `auth.users` change, so it needs no service_role key. The insert deliberately
/// omits `assigned_by` — the column defaults to `auth.uid()` and the policy re-checks
/// it, so *who* assigned the paper is the database's answer rather than this client's
/// claim (the rule `session_reset_logs.actor_id` follows).
class SupervisionRepositoryImpl implements SupervisionRepository {
  SupervisionRepositoryImpl(this._client);

  /// The table, named once so the console's messages and the query cannot drift.
  static const String assignmentsTable = 'supervisor_exam_assignments';

  final SupabaseClient _client;

  @override
  Future<List<SupervisorAssignment>> listAssignments() async {
    try {
      final rows = await _client
          .from(assignmentsTable)
          .select('exam_id, supervisor_id, assigned_at')
          .order('assigned_at');
      return (rows as List)
          .cast<Map<String, dynamic>>()
          .map(SupervisorAssignment.fromMap)
          .toList();
    } on PostgrestException catch (error) {
      throw SupervisionException(_messageFrom(error));
    } catch (_) {
      throw const SupervisionException(
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  @override
  Future<List<Exam>> listExams() async {
    try {
      // No `is_published` filter: an administrator may assign an invigilator to a
      // paper that is still a draft, and `exams_select` hands them every row.
      final rows = await _client
          .from('exams')
          .select()
          .order('created_at', ascending: false);
      return (rows as List)
          .cast<Map<String, dynamic>>()
          .map(Exam.fromMap)
          .toList();
    } on PostgrestException catch (error) {
      throw SupervisionException(_messageFrom(error));
    } catch (_) {
      throw const SupervisionException(
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  @override
  Future<void> assign({
    required String examId,
    required String supervisorId,
  }) async {
    try {
      await _client.from(assignmentsTable).insert({
        'exam_id': examId,
        'supervisor_id': supervisorId,
      });
    } on PostgrestException catch (error) {
      throw SupervisionException(_messageFrom(error));
    } catch (_) {
      throw const SupervisionException(
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  @override
  Future<void> unassign({
    required String examId,
    required String supervisorId,
  }) async {
    try {
      await _client
          .from(assignmentsTable)
          .delete()
          .eq('exam_id', examId)
          .eq('supervisor_id', supervisorId);
    } on PostgrestException catch (error) {
      throw SupervisionException(_messageFrom(error));
    } catch (_) {
      throw const SupervisionException(
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  /// The database's refusal, in words an administrator can act on.
  ///
  /// The three codes that matter are the policies' own: `42501` is RLS (not an
  /// administrator), `23514` is `guard_supervisor_assignment()` (the account is not a
  /// supervisor), and `23503` is a foreign key (the paper or the account was deleted
  /// between the read and the write). `23505` is the primary key, i.e. already
  /// assigned.
  static String _messageFrom(PostgrestException error) => switch (error.code) {
        '42501' => 'Only an administrator may assign supervisors.',
        '23514' =>
          'That account is not a supervisor. Change its role first, then assign '
              'it a paper.',
        '23503' => 'That paper or account no longer exists. Refresh the list.',
        '23505' => 'That supervisor is already assigned to this paper.',
        _ => 'The server refused the assignment: ${error.message}',
      };
}
