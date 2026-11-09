import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../../core/widgets/home_button.dart';
import '../../../exam/domain/entities/exam.dart';
import '../../../exam/presentation/providers/exam_providers.dart';
import '../../../exam/presentation/widgets/published_exam_list.dart';
import 'analytics_page.dart';
import 'supervisor_dashboard_page.dart';

/// The supervisor home: pick an exam, then watch it live.
///
/// Deliberately the same list widget as the student portal — but *not* the same rows:
/// since `20261109090000_supervisor_exam_assignments.sql` a supervisor reaches exactly
/// the papers an administrator assigned to them (`can_supervise_exam()`), and
/// `exams_select` narrows this list accordingly. `PublishedExamList` therefore shows
/// the sittings this account is responsible for rather than the institution's, and the
/// empty state below is the case where nothing has been assigned yet — an empty list
/// here means "nobody put you on a paper", not "no papers exist".
class SupervisorExamPickerPage extends ConsumerStatefulWidget {
  const SupervisorExamPickerPage({
    super.key,
    this.supervisorName,
    this.onSignOut,
    this.canResetAttempts = false,
    this.canResetAnyAttempt = true,
  });

  /// Greeting name; the gate passes `profiles.full_name` ("Dr. Ada Nwosu").
  final String? supervisorName;

  /// Sign-out shown in the app bar (the gate owns the Supabase call).
  final VoidCallback? onSignOut;
  /// Whether the signed-in account may reset an attempt at all
  /// (`UserRole.canResetAttempts`, i.e. `is_attempt_resetter()`).
  final bool canResetAttempts;

  /// Whether it may reset an attempt on a paper it did **not** write.
  ///
  /// `true` for the intervention tier (admin, supervisor) and `false` for a
  /// lecturer, who may only reset the papers they wrote (`owns_exam(exam_id)`). The
  /// policy behind it is `can_supervise_exam(exam_id) or owns_exam(exam_id)`
  /// (`submissions_delete_supervisor`), and for a supervisor `can_supervise_exam()`
  /// means *the papers assigned to them* - which is exactly the list this picker
  /// offers, so "any attempt" here reads "any attempt on a sitting I was given". The
  /// monitor still asks the paper's own `created_by` before offering the control, so
  /// the icon and the policy agree instead of disagreeing after a tap.
  final bool canResetAnyAttempt;

  @override
  ConsumerState<SupervisorExamPickerPage> createState() =>
      _SupervisorExamPickerPageState();
}

class _SupervisorExamPickerPageState
    extends ConsumerState<SupervisorExamPickerPage> {
  Future<void> _openMonitor(Exam exam) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SupervisorDashboardPage(
          examId: exam.id,
          examTitle: exam.title,
          canResetAttempts: widget.canResetAttempts,
          // The role gate says whether the account may reset at all; this says
          // whether *this paper* is one of them. `owns_exam(exam_id)` is what the
          // DELETE policy enforces, so the control is offered only when it would
          // succeed.
          canResetThisExam: widget.canResetAnyAttempt ||
              exam.createdBy == SupabaseService.instance.currentUser?.id,
        ),
      ),
    );
    // A sitting watched and left is not a sitting unchanged: an attempt may have
    // been reset, or a paper published while the monitor was open. Refetch the
    // list on the way back instead of leaving it to the refresh button.
    if (mounted) ref.invalidate(publishedExamsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final fallback = SupabaseService.instance.currentUser?.email;
    final name = (widget.supervisorName ?? fallback ?? '').trim();

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Supervisor Console'),
        actions: [
          // The supervisor/lecturer landing page. Pressing it here is a no-op
          // (there is nothing above it), and staying put is what keeps the
          // console's controls in the same place on every one of its screens.
          const HomeButton(key: Key('supervisor-home')),
          IconButton(
            key: const Key('supervisor-analytics'),
            tooltip: 'Analytics',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AnalyticsPage(),
              ),
            ),
            icon: const Icon(Icons.analytics_outlined),
          ),
          IconButton(
            key: const Key('supervisor-refresh'),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(publishedExamsProvider),
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onSignOut != null)
            IconButton(
              key: const Key('supervisor-sign-out'),
              tooltip: 'Sign out',
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Welcome' : 'Welcome, $name',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Pick an exam to open its live monitor.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Only the papers you are assigned to are listed. An administrator '
                  'assigns supervisors to papers.',
                  key: const Key('supervisor-scope-note'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: PublishedExamList(
              onOpen: _openMonitor,
              // The list is already scoped server-side (`exams_select` asks
              // `can_supervise_exam()`), so an empty one means nothing was assigned -
              // or nothing assigned has been published yet. The message names the
              // assignment because that is the action a supervisor cannot take
              // themselves.
              emptyMessage: 'No exam has been assigned to you yet.\n\n'
                  'An administrator assigns supervisors to papers. Once you are on '
                  'one (and it is published), it appears here.',
            ),
          ),
        ],
      ),
    );
  }
}
