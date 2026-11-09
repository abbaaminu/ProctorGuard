import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../exam/domain/entities/exam.dart';
import '../../domain/entities/supervisor_assignment.dart';
import '../../domain/repositories/supervision_repository.dart';

/// The supervision repository.
///
/// Throws until overridden — `main()` overrides it with
/// `SupervisionRepositoryImpl(Supabase.instance.client)`, the arrangement
/// `adminUserRepositoryProvider` and `dashboardRepositoryProvider` use, so a widget
/// test can inject a fake without a backend.
final supervisionRepositoryProvider = Provider<SupervisionRepository>(
  (ref) => throw UnimplementedError(
    'supervisionRepositoryProvider must be overridden with a '
    'SupervisionRepository (see main.dart / ProviderScope overrides).',
  ),
);

/// Every paper an administrator may assign a supervisor to — drafts included.
///
/// `autoDispose`, so reopening the screen reads the list again instead of showing
/// the copy it cached the first time, and invalidated after every assignment so the
/// "who runs this paper" line never disagrees with the table.
final supervisionExamsProvider = FutureProvider.autoDispose<List<Exam>>(
  (ref) => ref.watch(supervisionRepositoryProvider).listExams(),
);

/// Every `(paper, supervisor)` row the caller may read.
final supervisorAssignmentsProvider =
    FutureProvider.autoDispose<List<SupervisorAssignment>>(
  (ref) => ref.watch(supervisionRepositoryProvider).listAssignments(),
);

/// A short label for a supervisor account, from the roster the admin console
/// already reads.
///
/// Kept here rather than on the page so the dialog and the exam tile name the same
/// person the same way, and so a missing name falls back to the address (never to an
/// empty chip).
String supervisorLabel({required String fullName, required String email}) {
  final name = fullName.trim();
  if (name.isNotEmpty) return name;
  final address = email.trim();
  return address.isEmpty ? 'Unnamed account' : address;
}
