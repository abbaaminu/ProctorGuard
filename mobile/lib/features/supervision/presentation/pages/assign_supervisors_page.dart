import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/home_button.dart';
import '../../../admin/domain/entities/managed_account.dart';
import '../../../admin/presentation/providers/admin_providers.dart';
import '../../../auth/domain/entities/user_profile.dart';
import '../../../exam/domain/entities/exam.dart';
import '../../domain/entities/supervisor_assignment.dart';
import '../../domain/repositories/supervision_repository.dart';
import '../providers/supervision_providers.dart';

/// The admin console's **Assign supervisors** screen.
///
/// The write half of the supervisor scope: `public.supervisor_exam_assignments`
/// decides which papers a supervisor may see, read and intervene in
/// (`can_supervise_exam()` in `supabase/schema.sql`), and this is where an
/// administrator says which. A supervisor with no row signs in to an empty console —
/// which is the state `SupervisorExamPickerPage` names, not a bug.
///
/// Deliberately a plain list of papers rather than a wizard: the rows are
/// `(paper, supervisor)` pairs, an administrator usually assigns a sitting once and
/// comes back to it when somebody swaps, and "who runs this paper" is the question
/// they arrive with. Drafts are listed too — a sitting is invigilated before its
/// paper is published, and `exams_select` gives an administrator every row.
///
/// Both halves of the screen are reads the console already had: the papers come from
/// `exams` and the people from the roster (`managedAccountsProvider`, which the admin
/// dashboard lists anyway). Nothing here can widen a role: the insert policy is
/// `is_admin()` and `guard_supervisor_assignment()` refuses any account that is not a
/// supervisor, so the "no supervisor accounts" state is a prompt to create one, not a
/// gap this screen could fill itself.
class AssignSupervisorsPage extends ConsumerWidget {
  const AssignSupervisorsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exams = ref.watch(supervisionExamsProvider);
    final assignments = ref.watch(supervisorAssignmentsProvider);
    final accounts = ref.watch(managedAccountsProvider);

    void refresh() {
      ref.invalidate(supervisionExamsProvider);
      ref.invalidate(supervisorAssignmentsProvider);
      ref.invalidate(managedAccountsProvider);
    }

    final error = exams.error ?? assignments.error ?? accounts.error;

    return Scaffold(
      key: const Key('assign-supervisors-page'),
      appBar: AppBar(
        title: const Text('Assign supervisors'),
        actions: [
          // Same affordance, same place, on every screen of this console - see
          // `HomeButton`.
          const HomeButton(key: Key('assign-supervisors-home')),
          IconButton(
            key: const Key('assign-supervisors-refresh'),
            tooltip: 'Refresh',
            onPressed: refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text(
              'A supervisor can open, read and act on exactly the papers listed '
              'here. An administrator can open every paper without being assigned.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: error != null
                ? _AssignmentsError(error: '$error', onRetry: refresh)
                : _body(
                    ref,
                    exams.valueOrNull,
                    assignments.valueOrNull,
                    accounts.valueOrNull,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _body(
    WidgetRef ref,
    List<Exam>? examRows,
    List<SupervisorAssignment>? rows,
    List<ManagedAccount>? accounts,
  ) {
    if (examRows == null || rows == null || accounts == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (examRows.isEmpty) {
      return const _AssignmentsEmpty(
        key: Key('assign-supervisors-empty'),
        message: 'There are no papers to assign yet. Author one in the lecturer '
            'console first (a draft counts - it can be invigilated before it is '
            'published).',
      );
    }

    // One list of supervisors, in the order the dialog offers them.
    final supervisors = accounts
        .where((account) => account.role == UserRole.supervisor)
        .toList()
      ..sort((a, b) =>
          _label(a).toLowerCase().compareTo(_label(b).toLowerCase()));

    final byId = {for (final account in accounts) account.id: account};
    final assigned = <String, List<ManagedAccount>>{};
    for (final row in rows) {
      final account = byId[row.supervisorId];
      // A row whose account the caller cannot read (deleted a moment ago, or a
      // trimmed select) is skipped rather than rendered as an empty chip.
      if (account == null) continue;
      (assigned[row.examId] ??= <ManagedAccount>[]).add(account);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (supervisors.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'No supervisor accounts yet. Create one with the Supervisor role in '
              'this console, then come back to assign it a paper.',
              key: Key('assign-supervisors-no-supervisors'),
            ),
          ),
        for (final exam in examRows)
          _ExamAssignmentTile(
            exam: exam,
            assigned: assigned[exam.id] ?? const <ManagedAccount>[],
            supervisors: supervisors,
            onChanged: () => ref.invalidate(supervisorAssignmentsProvider),
          ),
      ],
    );
  }

  static String _label(ManagedAccount account) =>
      supervisorLabel(fullName: account.fullName, email: account.email);
}

/// One paper, the supervisors on it, and the control that opens the picker.
class _ExamAssignmentTile extends StatelessWidget {
  const _ExamAssignmentTile({
    required this.exam,
    required this.assigned,
    required this.supervisors,
    required this.onChanged,
  });

  final Exam exam;
  final List<ManagedAccount> assigned;
  final List<ManagedAccount> supervisors;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = assigned.map(AssignSupervisorsPage._label).toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        key: Key('assign-exam-${exam.id}'),
        leading: CircleAvatar(
          child: Icon(exam.isPublished
              ? Icons.assignment_turned_in_outlined
              : Icons.edit_note),
        ),
        title: Text(exam.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(exam.isPublished ? 'Published' : 'Draft - not published yet'),
            Text(
              names.isEmpty
                  ? 'No supervisor assigned: nobody but an administrator can open '
                      'this paper.'
                  : 'Supervisor${names.length == 1 ? '' : 's'}: ${names.join(', ')}',
              key: Key('assign-names-${exam.id}'),
              style: names.isEmpty
                  ? theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)
                  : theme.textTheme.bodySmall,
            ),
          ],
        ),
        isThreeLine: true,
        trailing: TextButton(
          key: Key('assign-manage-${exam.id}'),
          onPressed: () => _open(context),
          child: const Text('Manage'),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _AssignSupervisorsDialog(
        exam: exam,
        supervisors: supervisors,
        assignedIds: assigned.map((account) => account.id).toSet(),
      ),
    );
    if (changed == true) onChanged();
  }
}

/// The picker behind "Manage": every supervisor account, ticked where that account
/// already runs this paper.
///
/// Each tick is written immediately — there is no Save, because a "Save" on a dialog
/// an administrator closes by accident would be a silent revoke. A refusal (the
/// policies', or the guard's) leaves the tick where it was and says why, so the dialog
/// never shows a state the database does not hold.
class _AssignSupervisorsDialog extends ConsumerStatefulWidget {
  const _AssignSupervisorsDialog({
    required this.exam,
    required this.supervisors,
    required this.assignedIds,
  });

  final Exam exam;
  final List<ManagedAccount> supervisors;
  final Set<String> assignedIds;

  @override
  ConsumerState<_AssignSupervisorsDialog> createState() =>
      _AssignSupervisorsDialogState();
}

class _AssignSupervisorsDialogState
    extends ConsumerState<_AssignSupervisorsDialog> {
  late final Set<String> _assigned = {...widget.assignedIds};
  bool _busy = false;
  bool _changed = false;

  Future<void> _toggle(ManagedAccount account, bool granted) async {
    if (_busy) return;
    setState(() => _busy = true);
    final repository = ref.read(supervisionRepositoryProvider);
    try {
      if (granted) {
        await repository.assign(examId: widget.exam.id, supervisorId: account.id);
      } else {
        await repository.unassign(
          examId: widget.exam.id,
          supervisorId: account.id,
        );
      }
      if (!mounted) return;
      setState(() {
        _changed = true;
        if (granted) {
          _assigned.add(account.id);
        } else {
          _assigned.remove(account.id);
        }
      });
    } on SupervisionException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(error.message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('Who runs "${widget.exam.title}"?'),
      content: SizedBox(
        width: 420,
        child: widget.supervisors.isEmpty
            ? const Text(
                'No supervisor accounts to assign yet.',
                key: Key('assign-dialog-no-supervisors'),
              )
            : ListView(
                shrinkWrap: true,
                children: [
                  for (final account in widget.supervisors)
                    CheckboxListTile(
                      key: Key('assign-toggle-${widget.exam.id}-${account.id}'),
                      value: _assigned.contains(account.id),
                      onChanged: _busy
                          ? null
                          : (value) => _toggle(account, value ?? false),
                      title: Text(supervisorLabel(
                        fullName: account.fullName,
                        email: account.email,
                      )),
                      subtitle:
                          account.email.isEmpty ? null : Text(account.email),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    'Un-ticking a supervisor ends their access to this paper '
                    'immediately: its roster, incidents, stills and decisions '
                    'disappear from their console.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const Key('assign-done'),
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Centred failure state for the screen (offline, RLS, a missing table) —
/// deliberately not a silent empty list, which would read as "no papers exist".
class _AssignmentsError extends StatelessWidget {
  const _AssignmentsError({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            const Text('Could not load the papers.', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              error,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('assign-supervisors-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centred placeholder for "there is nothing to assign yet".
class _AssignmentsEmpty extends StatelessWidget {
  const _AssignmentsEmpty({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );
}
