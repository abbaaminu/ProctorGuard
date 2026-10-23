import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/student_roster_csv.dart';
import '../../domain/entities/student_roster.dart';
import '../../domain/repositories/admin_user_repository.dart';
import '../providers/admin_providers.dart';

/// A roster file the administrator chose, already read off disk.
///
/// The contents arrive as a string rather than bytes so the widget (and a test)
/// only has to deal with the file's text; the decoding lives in
/// [_BulkStudentUploadWidgetState._pickWithPlatform].
class RosterFile {
  const RosterFile({required this.name, required this.contents});

  /// The file's name, shown so the administrator can see which list is on
  /// screen — "students.csv" is not a guarantee about its contents.
  final String name;

  final String contents;
}

/// Picks the roster file, or null when the administrator closed the picker.
typedef RosterFilePicker = Future<RosterFile?> Function();

/// Bulk student creation from a CSV, embedded in the admin console.
///
/// The flow is deliberately four visible steps rather than one button: choose a
/// file, see what was read (and what was skipped, and why), send it, then read
/// the passwords. A single "import" button would make a typo in row 40 look like
/// a silent success.
///
/// Nothing is sent until the administrator presses *Upload*, and the file never
/// leaves the app in one piece: it goes up in pages of
/// [AdminUserRepository.maxStudentPageSize] rows, because the Edge Function
/// refuses larger bodies. [pickFile] exists so a widget test can hand over a file
/// without the platform picker.
class BulkStudentUploadWidget extends ConsumerStatefulWidget {
  const BulkStudentUploadWidget({super.key, this.pickFile});

  /// Replaces the platform file picker. Tests pass a function that answers a
  /// [RosterFile]; production leaves it null.
  final RosterFilePicker? pickFile;

  @override
  ConsumerState<BulkStudentUploadWidget> createState() =>
      _BulkStudentUploadWidgetState();
}

class _BulkStudentUploadWidgetState
    extends ConsumerState<BulkStudentUploadWidget> {
  /// The chosen file's name, or null before the first pick.
  String? _fileName;

  /// What the parser made of the chosen file, or null before the first pick.
  StudentRosterParse? _parse;

  /// A file that could not be read, or an upload that stopped early.
  String? _error;

  bool _reading = false;
  bool _uploading = false;

  /// Rows sent so far, and the number there are to send — the two numbers the
  /// progress bar needs.
  int _sent = 0;
  int _total = 0;

  /// What the pages answered, accumulated: rows created and rows refused.
  StudentRosterOutcome _outcome = const StudentRosterOutcome();

  bool get _busy => _reading || _uploading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parse = _parse;
    final rows = parse?.rows ?? const <NewStudentAccount>[];
    final problems = parse?.problems ?? const <StudentRosterProblem>[];
    final canUpload = !_busy && rows.isNotEmpty;

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
                  Icons.upload_file_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Upload a student list',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'A CSV whose first line is ${StudentRosterCsv.templateHeader}. '
              'Each row becomes a student account with a temporary password.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('roster-pick'),
                  onPressed: _busy ? null : _chooseFile,
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
                      key: const Key('roster-file-name'),
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
            if (parse != null) ...[
              const SizedBox(height: 12),
              _Summary(ready: rows.length, skipped: problems.length),
              if (parse.headerError != null) ...[
                const SizedBox(height: 12),
                _RosterNotice(
                  key: const Key('roster-header-error'),
                  icon: Icons.error_outline,
                  message: parse.headerError!,
                ),
              ],
              if (problems.isNotEmpty) ...[
                const SizedBox(height: 12),
                _ProblemList(problems: problems),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('roster-upload'),
                onPressed: canUpload ? _upload : null,
                icon: _uploading
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.person_add_alt_1_outlined, size: 18),
                label: Text(
                  _uploading
                      ? 'Uploading $_sent of $_total…'
                      : 'Create ${rows.length} student '
                          '${rows.length == 1 ? 'account' : 'accounts'}',
                ),
              ),
              if (_uploading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const Key('roster-progress'),
                  value: _total == 0 ? null : _sent / _total,
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _RosterNotice(
                key: const Key('roster-error'),
                icon: Icons.error_outline,
                message: _error!,
              ),
            ],
            if (!_outcome.isEmpty) ...[
              const SizedBox(height: 16),
              _OutcomeView(outcome: _outcome, onCopy: _copyPasswords),
            ],
          ],
        ),
      ),
    );
  }

  /// Reads a file and parses it, replacing any earlier choice.
  ///
  /// A cancelled picker changes nothing: an administrator who opens the dialog
  /// and closes it again should still see the file they had.
  Future<void> _chooseFile() async {
    if (_busy) return;
    setState(() {
      _reading = true;
      _error = null;
    });

    try {
      final picked = await (widget.pickFile ?? _pickWithPlatform)();
      if (!mounted) return;
      if (picked == null) {
        setState(() => _reading = false);
        return;
      }

      final parse = StudentRosterCsv.parse(picked.contents);
      setState(() {
        _reading = false;
        _fileName = picked.name;
        _parse = parse;
        _total = parse.rows.length;
        _sent = 0;
        // A new file is a new import: the previous run's passwords stay on
        // screen only until the file that produced them is replaced, so they
        // cannot be handed over for the wrong class.
        _outcome = const StudentRosterOutcome();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = 'That file could not be opened. Choose it again, or copy the '
            'rows into a new CSV and upload that.';
      });
    }
  }

  /// The platform picker, used when no [BulkStudentUploadWidget.pickFile] was
  /// supplied.
  ///
  /// `file_picker` 12 returns a [PlatformFile] rather than a path, and its bytes
  /// are read on demand — which is what makes this work on the web, where the
  /// picker (rightly) hands out no path at all.
  Future<RosterFile?> _pickWithPlatform() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose the student list',
      type: FileType.custom,
      allowedExtensions: const <String>['csv', 'txt'],
    );
    if (file == null) return null;

    return RosterFile(
      name: file.name,
      // Malformed input is replaced rather than thrown on: one stray byte in a
      // name should not hide the rest of the class from the parser, which
      // reports what it cannot use far more precisely.
      contents: utf8.decode(await file.readAsBytes(), allowMalformed: true),
    );
  }

  /// Sends the parsed rows, one page at a time.
  ///
  /// Pages are sequential on purpose: the function creates one account per row,
  /// and firing twenty requests at it at once would be a worse experience for
  /// everyone on the project than a progress bar. A page that fails stops the
  /// run — the rest of the file stays unsent, and the rows already created stay
  /// listed, because their passwords are the only copy that exists.
  Future<void> _upload() async {
    final parse = _parse;
    if (parse == null || parse.rows.isEmpty || _busy) return;

    final total = parse.rows.length;
    setState(() {
      _uploading = true;
      _error = null;
      _sent = 0;
      _total = total;
      _outcome = const StudentRosterOutcome();
    });

    var outcome = const StudentRosterOutcome();
    try {
      final repository = ref.read(adminUserRepositoryProvider);
      const pageSize = AdminUserRepository.maxStudentPageSize;

      for (var start = 0; start < total; start += pageSize) {
        final end = start + pageSize < total ? start + pageSize : total;
        final answer =
            await repository.createStudentAccounts(parse.rows.sublist(start, end));
        outcome += answer;
        if (!mounted) return;
        setState(() {
          _outcome = outcome;
          _sent = end;
        });
      }

      // The roster is the only proof the accounts exist, so refetch it rather
      // than trust the answer alone.
      ref.invalidate(managedAccountsProvider);
      if (!mounted) return;
      if (outcome.failedCount == 0) {
        _showMessage(
          'Created ${outcome.createdCount} student '
          '${outcome.createdCount == 1 ? 'account' : 'accounts'}. Copy the '
          'passwords now — they are not shown again.',
        );
      } else {
        _showMessage(
          'Created ${outcome.createdCount}; ${outcome.failedCount} could not be '
          'created. The reason for each is listed above.',
          isError: true,
        );
      }
    } on AdminAccountException catch (error) {
      if (!mounted) return;
      // A page can fail after earlier pages succeeded; refresh either way so the
      // rows that were created appear in the roster.
      ref.invalidate(managedAccountsProvider);
      setState(() {
        _outcome = outcome;
        _error = _stopMessage(error.message, outcome, total);
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// The sentence for an upload that stopped part-way: how far it got, and what
  /// to do next. Without the count an administrator cannot tell whether one
  /// account or the whole class is missing.
  String _stopMessage(
    String reason,
    StudentRosterOutcome outcome,
    int total,
  ) {
    if (outcome.createdCount == 0) return reason;
    return '$reason ${outcome.createdCount} of $total students were created '
        'before the upload stopped; their passwords are below. Upload the same '
        'file again to retry — the accounts that already exist will be '
        'reported as taken.';
  }

  Future<void> _copyPasswords() async {
    final sheet = _outcome.handoverSheet;
    if (sheet.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: sheet));
    _showMessage(
      'Copied ${_outcome.createdCount} '
      '${_outcome.createdCount == 1 ? 'password' : 'passwords'} — one '
      'address and password per line.',
    );
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
}


/// "12 students ready to upload · 2 lines skipped".
///
/// Kept above the button rather than in the button's label: what a file holds is
/// the thing an administrator checks before pressing anything.
class _Summary extends StatelessWidget {
  const _Summary({required this.ready, required this.skipped});

  final int ready;
  final int skipped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      key: const Key('roster-summary'),
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
                ? 'No student rows in this file.'
                : '$ready ${ready == 1 ? 'student' : 'students'} ready to upload.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (skipped > 0)
          Chip(
            key: const Key('roster-skipped-count'),
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

/// A sentence in a tinted box: a header error, a stopped upload, or a reason a
/// line was skipped. A box rather than a SnackBar because the administrator may
/// need to read it while editing the file.
class _RosterNotice extends StatelessWidget {
  const _RosterNotice({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = theme.colorScheme.errorContainer;
    final foreground = theme.colorScheme.onErrorContainer;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// The lines the parser refused, so a file can be corrected before the rest of
/// the class is uploaded without them.
///
/// Capped: a file with 300 bad rows has one problem (a column in the wrong
/// place), and listing all 300 would bury the sentence that says so. The count
/// is always the true one.
class _ProblemList extends StatelessWidget {
  const _ProblemList({required this.problems});

  static const int _shown = 6;

  final List<StudentRosterProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = problems.take(_shown).toList(growable: false);

    return Column(
      key: const Key('roster-problems'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'These lines will not be uploaded:',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        for (final problem in visible)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Line ${problem.line}: ${problem.message}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (problems.length > visible.length)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '…and ${problems.length - visible.length} more. Fix them and '
              'choose the file again.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}


/// What the server said, kept on screen until a different file is chosen.
///
/// The created rows are the important half: each password is shown once and
/// cannot be looked up again, so they are listed in full rather than summarised,
/// with one control that copies the lot as `email<TAB>password` lines.
class _OutcomeView extends StatelessWidget {
  const _OutcomeView({required this.outcome, required this.onCopy});

  /// Failures are capped: the row count above is the true one, and a file whose
  /// every e-mail already exists would otherwise push the created passwords —
  /// the part that cannot be recovered — off the screen.
  static const int _shownFailures = 40;

  final StudentRosterOutcome outcome;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = outcome.created;
    final failed = outcome.failed;
    final shownFailures =
        failed.take(_shownFailures).toList(growable: false);

    return Column(
      key: const Key('roster-outcome'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (created.isNotEmpty) ...[
          Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${created.length} student '
                  '${created.length == 1 ? 'account' : 'accounts'} created',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                key: const Key('roster-copy'),
                onPressed: onCopy,
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('Copy all'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'These passwords are shown once. Copy them now — leaving this page '
            'loses them, and only the account holder can be given a new one.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          for (var at = 0; at < created.length; at++)
            Container(
              key: ValueKey<String>('roster-created-$at'),
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      created[at].account.email,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 12),
                  SelectableText(
                    created[at].temporaryPassword.isEmpty
                        ? '(no password returned)'
                        : created[at].temporaryPassword,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (failed.isNotEmpty) ...[
          if (created.isNotEmpty) const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                Icons.report_problem_outlined,
                size: 20,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${failed.length} ${failed.length == 1 ? 'row was' : 'rows were'} '
                  'not created',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final row in shownFailures)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${row.email} — ${row.error}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (failed.length > shownFailures.length)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '…and ${failed.length - shownFailures.length} more, all for the '
                'same reasons. Remove them from the file and upload it again.',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

