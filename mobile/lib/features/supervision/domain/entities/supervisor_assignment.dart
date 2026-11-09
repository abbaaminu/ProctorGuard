import 'package:equatable/equatable.dart';

/// One row of `public.supervisor_exam_assignments` — "this supervisor runs this
/// paper".
///
/// The row is the whole of a supervisor's reach: `can_supervise_exam(exam_id)` in
/// `supabase/schema.sql` answers "an administrator, or a supervisor assigned to this
/// paper", and every policy that used to name the *tier* (`is_exam_supervisor()`)
/// now asks that predicate with the paper the row belongs to. No row, no reach — so
/// an empty `supervisor_exam_assignments` is not a neutral state, it is a supervisor
/// who can see nothing, which is what the console's empty state says.
///
/// Deliberately only the two ids and the timestamp: the screen joins them against
/// the exams it lists and the supervisor accounts it already reads, so this entity
/// carries no copy of a title or a name that could go stale between two reads.
class SupervisorAssignment extends Equatable {
  const SupervisorAssignment({
    required this.examId,
    required this.supervisorId,
    this.assignedAt,
  });

  factory SupervisorAssignment.fromMap(Map<String, dynamic> map) =>
      SupervisorAssignment(
        examId: map['exam_id'] as String,
        supervisorId: map['supervisor_id'] as String,
        assignedAt:
            DateTime.tryParse(map['assigned_at'] as String? ?? ''),
      );

  final String examId;
  final String supervisorId;

  /// `assigned_at`, or null when the response omits it. Display only: the row's
  /// identity is the pair.
  final DateTime? assignedAt;

  @override
  List<Object?> get props => [examId, supervisorId];
}
