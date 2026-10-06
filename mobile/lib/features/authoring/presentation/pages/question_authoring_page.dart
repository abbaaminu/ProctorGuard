import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/home_button.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../domain/entities/attempt_grading.dart' show formatMarks;
import '../../domain/entities/authored_question.dart';
import '../../domain/repositories/question_authoring_repository.dart';
import '../providers/question_authoring_providers.dart';
import '../widgets/question_editor_dialog.dart';

/// One paper's questions: add, edit, delete, and read the answer keys back.
///
/// This is the only screen in the app that shows a key, and it does so because
/// the person looking at it wrote the paper. Everything is owner-scoped by the
/// database (`questions_write_owner` / `questions_update_owner` /
/// `questions_delete_owner` all key on the exam's `created_by`), so the page does
/// not re-check ownership — it reports the refusal if there is one.
class QuestionAuthoringPage extends ConsumerStatefulWidget {
  const QuestionAuthoringPage({
    super.key,
    required this.examId,
    required this.examTitle,
  });

  final String examId;
  final String examTitle;

  @override
  ConsumerState<QuestionAuthoringPage> createState() =>
      _QuestionAuthoringPageState();
}

class _QuestionAuthoringPageState extends ConsumerState<QuestionAuthoringPage> {
  /// The question whose delete is in flight, and whether a save is in flight:
  /// both block a second write, because the list they act on is about to change.
  String? _busyId;
  bool _saving = false;

  void _showMessage(String message, {bool isError = true}) {
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

  /// The editor, for a new question or an existing one.
  ///
  /// It answers with a [QuestionDraft] or with nothing: the dialog owns every
  /// field, so this page never holds a half-filled question of its own.
  Future<void> _openEditor({AuthoredQuestion? existing}) async {
    if (_saving) return;

    final draft = await showDialog<QuestionDraft>(
      context: context,
      builder: (_) => QuestionEditorDialog(existing: existing),
    );
    if (draft == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final repository = ref.read(questionAuthoringRepositoryProvider);
      if (existing == null) {
        await repository.createQuestion(examId: widget.examId, draft: draft);
      } else {
        await repository.updateQuestion(questionId: existing.id, draft: draft);
      }
      if (!mounted) return;
      ref.invalidate(examQuestionsProvider(widget.examId));
      _showMessage(
        existing == null ? 'Question added.' : 'Question updated.',
        isError: false,
      );
    } on AuthoringException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteQuestion(AuthoredQuestion question) async {
    if (_busyId != null || _saving) return;

    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this question?'),
        content: Text(
          question.questionType.isSubjective
              ? 'Its wording is removed from the paper, and any marks already '
                  'awarded for it are deleted with it (the foreign key '
                  'cascades). Attempt totals are not recalculated — re-mark the '
                  'papers it belonged to.'
              : 'Its wording and answer key are removed from the paper. An '
                  'attempt that already answered it keeps its stored answer, '
                  'but the question no longer scores.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('question-delete-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete question'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() => _busyId = question.id);
    try {
      await ref
          .read(questionAuthoringRepositoryProvider)
          .deleteQuestion(question.id);
      if (!mounted) return;
      ref.invalidate(examQuestionsProvider(widget.examId));
      _showMessage('Question deleted.', isError: false);
    } on AuthoringException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final questions = ref.watch(examQuestionsProvider(widget.examId));

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Questions'),
        actions: [
          const HomeButton(key: Key('questions-home')),
          // One step back to the paper's own console, which is where this page
          // was opened from — the browser has no back gesture to rely on.
          IconButton(
            key: const Key('questions-back'),
            tooltip: 'Back to my papers',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            key: const Key('questions-refresh'),
            tooltip: 'Refresh',
            onPressed: () =>
                ref.invalidate(examQuestionsProvider(widget.examId)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12),
          child: FilledButton.icon(
            key: const Key('question-add'),
            onPressed: _saving ? null : () => _openEditor(),
            icon: const Icon(Icons.add),
            label: const Text('Add question'),
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.examTitle, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Every shape the paper holds is authored here: options, a '
                  'true/false statement, an accepted wording, or an essay that '
                  'you mark by hand.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: questions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _QuestionsError(
                message: error is AuthoringException
                    ? error.message
                    : 'Could not load this paper.',
                onRetry: () =>
                    ref.invalidate(examQuestionsProvider(widget.examId)),
              ),
              data: (rows) => rows.isEmpty
                  ? const _NoQuestions()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _QuestionCard(
                        index: index,
                        question: rows[index],
                        busy: _busyId == rows[index].id,
                        enabled: _busyId == null && !_saving,
                        onEdit: () => _openEditor(existing: rows[index]),
                        onDelete: () => _deleteQuestion(rows[index]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One authored question, with its key read back in plain words — the whole
/// reason this screen exists next to the exam the student sees.
class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.index,
    required this.question,
    required this.busy,
    required this.enabled,
    required this.onEdit,
    required this.onDelete,
  });

  /// Zero-based position in the paper; shown as `Question 1…`.
  final int index;
  final AuthoredQuestion question;
  final bool busy;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = question.id;

    return Card(
      key: Key('question-tile-$id'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Question ${index + 1}',
                        style: theme.textTheme.labelLarge,
                      ),
                      Chip(
                        key: Key('question-type-chip-$id'),
                        visualDensity: VisualDensity.compact,
                        label: Text(question.questionType.label),
                      ),
                      Text(
                        '${formatMarks(question.points)} '
                        '${question.points == 1 ? 'mark' : 'marks'}',
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(question.questionText),
            if (question.options.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (var i = 0; i < question.options.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    '${String.fromCharCode(65 + i)}. ${question.options[i]}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  question.questionType.isSubjective
                      ? Icons.edit_note
                      : Icons.check_circle_outline,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Answer: ${question.answerSummary}',
                    key: Key('question-answer-summary-$id'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    key: Key('question-edit-$id'),
                    onPressed: enabled ? onEdit : null,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit'),
                  ),
                  IconButton(
                    key: Key('question-delete-$id'),
                    tooltip: 'Delete question',
                    onPressed: enabled ? onDelete : null,
                    color: theme.colorScheme.error,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The paper could not be read: the repository's own sentence, with a retry.
class _QuestionsError extends StatelessWidget {
  const _QuestionsError({required this.message, required this.onRetry});

  final String message;
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
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              key: const Key('questions-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('questions-retry'),
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

/// An empty paper: the state a lecturer meets right after creating one, so the
/// copy says what to do rather than reporting a problem.
class _NoQuestions extends StatelessWidget {
  const _NoQuestions();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.help_outline,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'This paper has no questions yet.',
              key: const Key('questions-empty'),
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'A published paper with no questions cannot be sat, so add at '
              'least one before publishing.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
