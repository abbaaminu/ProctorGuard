import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/question_pack_parser.dart';
import '../../domain/entities/authored_question.dart';
import '../../domain/entities/question_pack.dart';
import '../../domain/repositories/question_authoring_repository.dart';
import '../providers/question_authoring_providers.dart';

/// A question file the lecturer chose, already read off disk.
///
/// The contents arrive as a string rather than bytes so the widget (and a test)
/// only has to deal with the file's text; the decoding lives in
/// [_BulkQuestionUploadWidgetState._pickWithPlatform].
class QuestionFile {
  const QuestionFile({required this.name, required this.contents});

  /// The file's name, shown so the lecturer can see which batch is on screen —
  /// "questions.json" is not a guarantee about its contents.
  final String name;

  final String contents;
}

/// Picks the question file, or null when the lecturer closed the picker.
typedef QuestionFilePicker = Future<QuestionFile?> Function();

/// Bulk question creation from a JSON or CSV file, opened from the authoring
/// console.
///
/// The flow is the same four visible steps as the student roster import: choose
/// a file, see what was read (and which entries were skipped, and why), add
/// them, then read what was stored. A single "import" button would make a typo
/// in the fourth question look like a silent success.
///
/// Nothing is sent until *Add questions* is pressed, and the questions are
/// created one at a time through the same
/// [QuestionAuthoringRepository.createQuestion] the editor uses — so every
/// uploaded row passes the local shape check and the database's own
/// `questions_answer_key_shape` exactly as a typed one does. There is no batch
/// endpoint to call, and inventing one would be a second write path to keep in
/// step with the policy on `questions`.
///
/// [pickFile] exists so a widget test can hand over a file without the platform
/// picker.
class BulkQuestionUploadWidget extends ConsumerStatefulWidget {
  const BulkQuestionUploadWidget({
    super.key,
    required this.examId,
    this.pickFile,
    this.onImported,
  });

  /// The paper the questions are being added to.
  final String examId;

  /// Replaces the platform file picker. Tests pass a function that answers a
  /// [QuestionFile]; production leaves it null.
  final QuestionFilePicker? pickFile;

  /// Called once at least one question has been stored, so the page behind this
  /// card can refetch the paper (and the console its question counts).
  final VoidCallback? onImported;

  @override
  ConsumerState<BulkQuestionUploadWidget> createState() =>
      _BulkQuestionUploadWidgetState();
}

class _BulkQuestionUploadWidgetState
    extends ConsumerState<BulkQuestionUploadWidget> {
  /// The chosen file's name, or null before the first pick.
  String? _fileName;

  /// What the parser made of the chosen file, or null before the first pick.
  QuestionPackParse? _parse;

  /// A file that could not be read, or an addition that stopped early.
  String? _error;

  bool _reading = false;
  bool _adding = false;

  /// How many drafts this run has stored, and how many there are to store — the
  /// two numbers the progress bar and the button label need.
  int _added = 0;
  int _total = 0;

  /// Whether the whole file has been added, so a second press cannot add the
  /// same questions twice.
  bool _done = false;

  bool get _busy => _reading || _adding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parse = _parse;
    final drafts = parse?.drafts ?? const <QuestionDraft>[];
    final problems = parse?.problems ?? const <QuestionPackProblem>[];
    final canAdd = !_busy && !_done && drafts.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Upload a question file', style: theme.textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'A JSON array of question objects, or a CSV whose first line is '
          '${QuestionPackParser.templateHeader}. Separate a question\'s '
          'options with ${QuestionPackParser.optionSeparator}; a true/false '
          'answer is true or false.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              key: const Key('question-pack-pick'),
              onPressed: _busy ? null : _chooseFile,
              icon: const Icon(Icons.folder_open_outlined, size: 18),
              label: Text(
                _fileName == null ? 'Choose file' : 'Choose another file',
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
                  key: const Key('question-pack-file-name'),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
        if (parse != null) ...[
          const SizedBox(height: 12),
          _PackSummary(ready: drafts.length, skipped: problems.length),
          if (parse.fileError != null) ...[
            const SizedBox(height: 12),
            _PackNotice(
              key: const Key('question-pack-header-error'),
              icon: Icons.error_outline,
              message: parse.fileError!,
            ),
          ],
          if (problems.isNotEmpty) ...[
            const SizedBox(height: 12),
            _PackProblemList(problems: problems),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('question-pack-add'),
            onPressed: canAdd ? _add : null,
            icon: _adding
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.playlist_add_outlined, size: 18),
            label: Text(_addLabel(drafts.length)),
          ),
          if (_adding) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              key: const Key('question-pack-progress'),
              value: _total == 0 ? null : _added / _total,
            ),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          _PackNotice(
            key: const Key('question-pack-error'),
            icon: Icons.error_outline,
            message: _error!,
          ),
        ],
        if (_done) ...[
          const SizedBox(height: 12),
          _PackNotice(
            key: const Key('question-pack-added'),
            icon: Icons.check_circle_outline,
            message: 'Added $_added ${_questionWord(_added)} to this paper.',
            success: true,
          ),
        ],
      ],
    );
  }

  /// The add button's label: what is about to happen, what is happening, or what
  /// just happened.
  String _addLabel(int ready) {
    if (_adding) return 'Adding $_added of $_total…';
    if (_done) return 'Added $_added ${_questionWord(_added)}';
    return 'Add $ready ${_questionWord(ready)}';
  }

  /// "1 question" / "3 questions".
  static String _questionWord(int count) => count == 1 ? 'question' : 'questions';

  /// Reads a file and parses it, replacing any earlier choice.
  ///
  /// A cancelled picker changes nothing: a lecturer who opens the dialog and
  /// closes it again should still see the file they had.
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

      final parse = QuestionPackParser.parse(picked.contents);
      setState(() {
        _reading = false;
        _fileName = picked.name;
        _parse = parse;
        _total = parse.drafts.length;
        _added = 0;
        // A new file is a new import: the count from the last run is cleared so
        // it cannot read as though these questions are already on the paper.
        _done = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = 'That file could not be opened. Choose it again, or export '
            'the questions once more and upload that.';
      });
    }
  }

  /// The platform picker, used when no [BulkQuestionUploadWidget.pickFile] was
  /// supplied.
  ///
  /// `file_picker` 12 returns a [PlatformFile] rather than a path, and its bytes
  /// are read on demand — which is what makes this work on the web, where the
  /// picker (rightly) hands out no path at all.
  Future<QuestionFile?> _pickWithPlatform() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Choose the questions file',
      type: FileType.custom,
      allowedExtensions: const <String>['json', 'csv', 'txt'],
    );
    if (file == null) return null;

    return QuestionFile(
      name: file.name,
      // Malformed input is replaced rather than thrown on: one stray byte in a
      // question should not hide the rest of the file from the parser, which
      // reports what it cannot use far more precisely.
      contents: utf8.decode(await file.readAsBytes(), allowMalformed: true),
    );
  }

  /// Stores the parsed drafts, one at a time.
  ///
  /// Sequential on purpose: each question is its own row with its own answer-key
  /// shape, and firing forty inserts at once would make a failure impossible to
  /// attribute to the question that caused it. A failure stops the run — the
  /// questions before it are on the paper and are reported as such, so nothing
  /// is silently half-added.
  Future<void> _add() async {
    final parse = _parse;
    if (parse == null || parse.drafts.isEmpty || _busy || _done) return;

    final total = parse.drafts.length;
    setState(() {
      _adding = true;
      _error = null;
      _added = 0;
      _total = total;
    });

    var added = 0;
    try {
      final repository = ref.read(questionAuthoringRepositoryProvider);
      for (final draft in parse.drafts) {
        await repository.createQuestion(examId: widget.examId, draft: draft);
        added++;
        if (!mounted) return;
        setState(() => _added = added);
      }

      if (!mounted) return;
      setState(() => _done = true);
      widget.onImported?.call();
      _showMessage(
        'Added $added ${_questionWord(added)} to the paper.',
      );
    } on AuthoringException catch (error) {
      if (!mounted) return;
      // Whatever was stored stays stored, so the paper behind this card is
      // refetched either way.
      if (added > 0) widget.onImported?.call();
      setState(() => _error = _stopMessage(error.message, added, total));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// The sentence for a run that stopped part-way: how far it got, and what to
  /// do next. Without the count a lecturer cannot tell whether one question or
  /// the whole file is missing from the paper.
  String _stopMessage(String reason, int added, int total) {
    if (added == 0) return reason;
    return '$reason $added of $total questions were added before the import '
        'stopped; they are on the paper. Remove the ones already added from '
        'the file and upload the rest.';
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

/// "3 questions ready to add · 1 skipped".
///
/// Kept above the button rather than in its label: what a file holds is the
/// thing a lecturer checks before pressing anything.
class _PackSummary extends StatelessWidget {
  const _PackSummary({required this.ready, required this.skipped});

  final int ready;
  final int skipped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      key: const Key('question-pack-summary'),
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
                ? 'No questions in this file.'
                : '$ready ${_BulkQuestionUploadWidgetState._questionWord(ready)}'
                    ' ready to add.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (skipped > 0)
          Chip(
            key: const Key('question-pack-skipped-count'),
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

/// A sentence in a tinted box: a file error, a stopped import, or the count of
/// what was added. A box rather than a SnackBar because the lecturer may need to
/// read it while correcting the file.
class _PackNotice extends StatelessWidget {
  const _PackNotice({
    super.key,
    required this.icon,
    required this.message,
    this.success = false,
  });

  final IconData icon;
  final String message;

  /// Green (the primary container) for a run that finished, red otherwise.
  final bool success;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = success
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.errorContainer;
    final foreground = success
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onErrorContainer;

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

/// The entries the parser refused, so a file can be corrected before the rest of
/// it is added without them.
///
/// Capped: a file with 300 bad rows has one problem (a column in the wrong
/// place), and listing all 300 would bury the sentence that says so. The count
/// is always the true one.
class _PackProblemList extends StatelessWidget {
  const _PackProblemList({required this.problems});

  static const int _shown = 6;

  final List<QuestionPackProblem> problems;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = problems.take(_shown).toList(growable: false);

    return Column(
      key: const Key('question-pack-problems'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'These entries will not be added:',
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
