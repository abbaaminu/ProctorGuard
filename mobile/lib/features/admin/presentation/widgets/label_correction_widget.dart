import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/student_label_csv.dart';
import '../../domain/entities/managed_account.dart';
import '../../domain/entities/profile_labels.dart';
import '../../domain/entities/student_roster.dart';
import '../../domain/repositories/admin_user_repository.dart';
import '../providers/admin_providers.dart';
import 'roster_file.dart';

/// Bulk correction of the academic labels from a CSV, embedded in the admin
/// console.
///
/// The fourth file-driven step, next to the roster import, and it exists for one
/// reason: `exams_select` compares `faculty / department / level`, and the
/// `guard_profile_labels()` trigger stops a *student* repairing their own row. A
/// class imported with no level — or with "300 Level" stored as text — therefore
/// cannot see a paper aimed at its cohort until somebody holding the roster fixes
/// it. Doing that one account at a time is thirty dialogs; this is one file.
///
/// It resolves addresses against the roster the page is showing
/// ([StudentLabelCsv.resolve]), so the steps stay visible: choose a file, read
/// what will change (and what was skipped, and why), send it in pages of
/// [AdminUserRepository.maxStudentPageSize], then read what the server refused.
/// [pickFile] exists so a widget test can hand over a file without the platform
/// picker.
class LabelCorrectionWidget extends ConsumerStatefulWidget {
  const LabelCorrectionWidget({super.key, this.pickFile});

  /// Replaces the platform file picker. Tests pass a function that answers a
  /// [RosterFile]; production leaves it null.
  final RosterFilePicker? pickFile;

  @override
  ConsumerState<LabelCorrectionWidget> createState() =>
      _LabelCorrectionWidgetState();
}

class _LabelCorrectionWidgetState extends ConsumerState<LabelCorrectionWidget> {
  /// The chosen file's name, or null before the first pick.
  String? _fileName;

  /// What the parser made of the chosen file, or null before the first pick.
  LabelFixPlan? _plan;

  /// A file that could not be read, or a run that stopped early.
  String? _error;

  bool _reading = false;
  bool _applying = false;

  /// Rows sent so far, and the number there are to send — the two numbers the
  /// progress bar needs.
  int _sent = 0;
  int _total = 0;

  /// What the pages answered, accumulated: rows corrected and rows refused.
  LabelFixOutcome _outcome = const LabelFixOutcome();

  bool get _busy => _reading || _applying;

  /// Reads a file and resolves it, replacing any earlier choice.
  ///
  /// It has to be resolved against [roster] — the file names people by address
  /// and the function selects rows by id — so a file chosen while the roster is
  /// still loading is refused here rather than sent with nothing resolved.
  Future<void> _chooseFile(List<ManagedAccount> roster) async {
    if (_busy) return;
    setState(() {
      _reading = true;
      _error = null;
    });

    try {
      final picked = await (widget.pickFile ?? _pickWithPlatform)();
      if (!mounted) return;
      // A cancelled picker changes nothing: the administrator who opens the
      // dialog and closes it again should still see the file they had.
      if (picked == null) {
        setState(() => _reading = false);
        return;
      }

      final plan = StudentLabelCsv.resolve(picked.contents, roster);
      setState(() {
        _reading = false;
        _fileName = picked.name;
        _plan = plan;
        _total = plan.corrections.length;
        _sent = 0;
        // A new file is a new correction: the previous run's outcome stays on
        // screen only until the file that produced it is replaced.
        _outcome = const LabelFixOutcome();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = 'That file could not be opened. Choose it again, or copy the '
            'rows into a new CSV and correct that.';
      });
    }
  }

  /// The platform picker, used when no [LabelCorrectionWidget.pickFile] was
  /// supplied.
  Future<RosterFile?> _pickWithPlatform() =>
      pickRosterFile(dialogTitle: 'Choose the label corrections');

  /// Sends the resolved corrections, one page at a time.
  ///
  /// Pages are sequential for the same reason as the roster import: the
  /// function writes one row per entry, and twenty parallel requests would be a
  /// worse experience for everybody on the project than a progress bar. A page
  /// that fails stops the run — the rest of the file stays unsent, and the rows
  /// already corrected stay listed, because the server has already applied them.
  Future<void> _apply() async {
    final plan = _plan;
    if (plan == null || plan.corrections.isEmpty || _busy) return;

    final total = plan.corrections.length;
    setState(() {
      _applying = true;
      _error = null;
      _sent = 0;
      _total = total;
      _outcome = const LabelFixOutcome();
    });

    var outcome = const LabelFixOutcome();
    try {
      final repository = ref.read(adminUserRepositoryProvider);
      const pageSize = AdminUserRepository.maxStudentPageSize;

      for (var start = 0; start < total; start += pageSize) {
        final end = start + pageSize < total ? start + pageSize : total;
        final answer = await repository.correctStudentLabels(
          plan.corrections.sublist(start, end),
        );
        outcome += answer;
        if (!mounted) return;
        setState(() {
          _outcome = outcome;
          _sent = end;
        });
      }

      if (!mounted) return;
      // The roster is what the next file resolves against, so it must show the
      // labels that were just written.
      ref.invalidate(managedAccountsProvider);
      _showMessage(
        outcome.failedCount == 0
            ? 'Corrected ${outcome.updatedCount} '
                '${outcome.updatedCount == 1 ? 'student' : 'students'}.'
            : 'Corrected ${outcome.updatedCount}; ${outcome.failedCount} could '
                'not be corrected. The reason for each is listed above.',
        isError: outcome.failedCount > 0,
      );
    } on AdminAccountException catch (error) {
      if (!mounted) return;
      // A page can fail after earlier pages were written; refresh either way so
      // the corrected rows show their new labels.
      ref.invalidate(managedAccountsProvider);
      setState(() {
        _outcome = outcome;
        _error = _stopMessage(error.message, outcome, total);
      });
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  /// The sentence for a run that stopped part-way: how far it got, and what to
  /// do next. Without the count an administrator cannot tell whether one student
  /// or the whole class is still wrong.
  String _stopMessage(String reason, LabelFixOutcome outcome, int total) {
    if (outcome.updatedCount == 0) return reason;
    return '$reason ${outcome.updatedCount} of $total students were corrected '
        'before the run stopped. Correct the same file again to retry — rows '
        'that are already right will simply be written again.';
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roster = ref.watch(managedAccountsProvider);
    final accounts = roster.valueOrNull ?? const <ManagedAccount>[];
    final plan = _plan;
    final corrections = plan?.corrections ?? const <StudentLabelCorrection>[];
    final problems = plan?.problems ?? const <StudentRosterProblem>[];
    // Nothing can be resolved (or sent) against a roster that is still loading
    // or failed to load: an address that matches no row would be reported as a
    // problem with the file, which would be misleading.
    final canPick = !_busy && roster.hasValue;
    final canApply = !_busy && corrections.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sell_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Correct class labels',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'A CSV of email addresses and the labels to fix. Published papers '
              'reach a student through these labels, so a blank one hides the '
              'papers aimed at their class. Leave a column out to keep it as it '
              'is; leave a cell empty to clear it. Header: '
              '${StudentLabelCsv.templateHeader}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('label-fix-pick'),
                  onPressed: canPick ? () => _chooseFile(accounts) : null,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: Text(
                    _fileName == null ? 'Choose CSV' : 'Choose another file',
                  ),
                ),
                const SizedBox(width: 12),
                if (_reading)
                  const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (_fileName != null)
                  Expanded(
                    child: Text(
                      _fileName!,
                      key: const Key('label-fix-file-name'),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            if (!roster.hasValue) ...[
              const SizedBox(height: 12),
              _FixNotice(
                key: const Key('label-fix-roster-pending'),
                icon: roster.hasError
                    ? Icons.error_outline
                    : Icons.hourglass_empty,
                message: roster.hasError
                    ? 'The account list could not be read, so no address in a '
                        'file can be matched. Reload the accounts and try again.'
                    : 'Reading the account list…',
              ),
            ],
            if (plan != null)
              ..._chosenFile(plan, corrections, problems, canApply),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _FixNotice(
                key: const Key('label-fix-error'),
                icon: Icons.error_outline,
                message: _error!,
              ),
            ],
            if (!_outcome.isEmpty) ...[
              const SizedBox(height: 16),
              _OutcomeView(outcome: _outcome),
            ],
          ],
        ),
      ),
    );
  }

  /// The part of the card that only exists once a file has been read: what it
  /// holds, what was skipped, and the button that sends it.
  List<Widget> _chosenFile(
    LabelFixPlan plan,
    List<StudentLabelCorrection> corrections,
    List<StudentRosterProblem> problems,
    bool canApply,
  ) =>
      <Widget>[
        const SizedBox(height: 12),
        _FixSummary(ready: corrections.length, skipped: problems.length),
        if (plan.headerError != null) ...[
          const SizedBox(height: 12),
          _FixNotice(
            key: const Key('label-fix-header-error'),
            icon: Icons.error_outline,
            message: plan.headerError!,
          ),
        ],
        if (problems.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ProblemList(problems: problems),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('label-fix-apply'),
          onPressed: canApply ? _apply : null,
          icon: _applying
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.done_all_outlined, size: 18),
          label: Text(
            _applying
                ? 'Correcting $_sent of $_total…'
                : 'Correct ${corrections.length} '
                    '${corrections.length == 1 ? 'student' : 'students'}',
          ),
        ),
        if (_applying) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            key: const Key('label-fix-progress'),
            value: _total == 0 ? null : _sent / _total,
          ),
        ],
      ];
}

/// "3 students will be corrected · 1 skipped".
///
/// Above the button rather than inside its label: what a file holds is the thing
/// an administrator checks before pressing anything.
class _FixSummary extends StatelessWidget {
  const _FixSummary({required this.ready, required this.skipped});

  final int ready;
  final int skipped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      key: const Key('label-fix-summary'),
      children: [
        Icon(
          ready > 0 ? Icons.check_circle_outline : Icons.info_outline,
          size: 18,
          color: ready > 0
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ready == 0
                ? 'No corrections in this file.'
                : '$ready ${ready == 1 ? 'student' : 'students'} will be '
                    'corrected.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (skipped > 0)
          Chip(
            key: const Key('label-fix-skipped-count'),
            visualDensity: VisualDensity.compact,
            avatar: Icon(
              Icons.warning_amber_outlined,
              size: 16,
              color: theme.colorScheme.error,
            ),
            label: Text('$skipped skipped'),
          ),
      ],
    );
  }
}

/// A sentence in a tinted box: a header error, a run that stopped early, or the
/// state of the roster a file has to be resolved against. A box rather than a
/// SnackBar because the administrator may need to read it while editing the
/// file.
class _FixNotice extends StatelessWidget {
  const _FixNotice({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Every line the file parser refused, with the number a spreadsheet shows.
class _ProblemList extends StatelessWidget {
  const _ProblemList({required this.problems});

  final List<StudentRosterProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      key: const Key('label-fix-problems'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final problem in problems)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Line ${problem.line}: ${problem.message}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

/// What the pages answered: how many rows were corrected, how many were
/// refused, and the server's sentence for each refusal — beside the rows it did
/// write, rather than instead of them.
class _OutcomeView extends StatelessWidget {
  const _OutcomeView({required this.outcome});

  final LabelFixOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updated = outcome.updatedCount;
    final failed = outcome.failedCount;

    return Column(
      key: const Key('label-fix-outcome'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          updated == 0
              ? 'No labels were corrected.'
              : '$updated ${updated == 1 ? 'student' : 'students'} corrected',
          style: theme.textTheme.titleSmall,
        ),
        if (failed > 0) ...[
          const SizedBox(height: 4),
          Text(
            '$failed ${failed == 1 ? 'row was' : 'rows were'} not corrected',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const SizedBox(height: 4),
          for (var at = 0; at < outcome.failed.length; at++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${outcome.failed[at].email} — ${outcome.failed[at].error}',
                key: Key('label-fix-failed-$at'),
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

