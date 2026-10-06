import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/home_button.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../domain/entities/attempt_grading.dart';
import '../../domain/repositories/question_authoring_repository.dart';
import '../providers/question_authoring_providers.dart';

/// One attempt, marked: every question with the answer the student stored, the
/// automatic verdict for the shapes that have a key, and a marks box for the
/// essays.
///
/// This is the "their respective grading views" half of the console. Three
/// shapes are shown *graded* — the server decided them when the attempt closed,
/// and this screen only reports that decision next to the question, so what a
/// lecturer reads is the same rule `auto_graded_score()` applied. An essay has
/// no such decision: it gets a marks field and a feedback box, and saving them
/// hands the values to `grade_submission()`, which validates them against the
/// question's weight and recomputes the attempt's total.
///
/// Nothing here computes a score: the running total that moves after a save is
/// the server's, echoed back by the RPC's own row.
class AttemptReviewPage extends ConsumerStatefulWidget {
  const AttemptReviewPage({
    super.key,
    required this.examId,
    required this.examTitle,
    required this.attempt,
  });

  final String examId;
  final String examTitle;
  final AttemptGrading attempt;

  @override
  ConsumerState<AttemptReviewPage> createState() => _AttemptReviewPageState();
}

class _AttemptReviewPageState extends ConsumerState<AttemptReviewPage> {
  /// One marks box per essay, seeded from what has already been awarded, plus
  /// the remark. Keyed by question id; built once, because the paper does not
  /// change under a page that is marking it.
  late final Map<String, TextEditingController> _marks = {
    for (final line in widget.attempt.essayLines)
      line.question.id: TextEditingController(
        text: line.awarded == null ? '' : formatMarks(line.awarded!),
      ),
  };

  late final Map<String, TextEditingController> _feedback = {
    for (final line in widget.attempt.essayLines)
      line.question.id: TextEditingController(text: line.feedback ?? ''),
  };

  /// Per-question refusal from the last Save, so each field can carry its own
  /// sentence (a marks value is only wrong in relation to that question's
  /// weight).
  final Map<String, String> _errors = <String, String>{};

  bool _saving = false;

  @override
  void dispose() {
    for (final controller in _marks.values) {
      controller.dispose();
    }
    for (final controller in _feedback.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// The grades the form is holding, or null when at least one box cannot be
  /// sent — with [_errors] filled in in that case.
  ///
  /// An empty box means "not marked", not zero: it is left out of the payload, so
  /// a first pass over a paper can save the essays that have been read without
  /// silently awarding nothing for the ones that have not.
  Map<String, dynamic>? _collect() {
    final errors = <String, String>{};
    final grades = <String, dynamic>{};

    for (final line in widget.attempt.essayLines) {
      final id = line.question.id;
      final text = _marks[id]?.text.trim() ?? '';
      if (text.isEmpty) continue;

      final value = double.tryParse(text);
      if (value == null) {
        errors[id] = 'Enter a number of marks.';
        continue;
      }
      if (value < 0 || value > line.points) {
        errors[id] = 'Between 0 and ${formatMarks(line.points)}.';
        continue;
      }

      grades[id] = <String, dynamic>{
        'awarded': value,
        'feedback': _feedback[id]?.text ?? '',
      };
    }

    _errors
      ..clear()
      ..addAll(errors);
    return errors.isEmpty ? grades : null;
  }

  Future<void> _save() async {
    if (_saving) return;

    final grades = _collect();
    if (grades == null) {
      setState(() {});
      return;
    }
    if (grades.isEmpty) {
      _showMessage('Enter marks for at least one essay before saving.');
      return;
    }

    setState(() => _saving = true);
    // Captured before the await: the page is popped on success, so the messenger
    // and navigator have to be the ones this screen was built with.
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final errorColour = Theme.of(context).colorScheme.error;

    try {
      final outcome =
          await ref.read(questionAuthoringRepositoryProvider).saveGrades(
                submissionId: widget.attempt.submission.id,
                grades: grades,
              );
      if (!mounted) return;

      // The list behind this page is refetched rather than patched: the server
      // recomputed the attempt's total, and this screen must not guess it.
      ref.invalidate(examAttemptsProvider(widget.examId));
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(outcome.summary)));
      navigator.pop();
    } on AuthoringException catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(error.message),
          backgroundColor: errorColour,
          duration: const Duration(seconds: 6),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final attempt = widget.attempt;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Mark a paper'),
        actions: [
          const HomeButton(key: Key('review-home')),
          IconButton(
            key: const Key('review-back'),
            tooltip: 'Back to the attempts',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 12),
          child: FilledButton.icon(
            key: const Key('grading-save'),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving…' : 'Save marks'),
          ),
        ),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 16),
        children: [
          _AttemptSummary(attempt: attempt, examTitle: widget.examTitle),
          const SizedBox(height: 12),
          for (var i = 0; i < attempt.lines.length; i++)
            _ReviewLine(
              index: i,
              total: attempt.lines.length,
              line: attempt.lines[i],
              marksController: _marks[attempt.lines[i].question.id],
              feedbackController: _feedback[attempt.lines[i].question.id],
              error: _errors[attempt.lines[i].question.id],
              enabled: !_saving,
            ),
        ],
      ),
    );
  }
}

/// Who sat this paper and how far its marking has come: the frame every line
/// below is read in.
class _AttemptSummary extends StatelessWidget {
  const _AttemptSummary({required this.attempt, required this.examTitle});

  final AttemptGrading attempt;
  final String examTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = attempt.score;

    return Card(
      key: const Key('review-summary'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(attempt.studentName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              examTitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    '${formatMarks(score ?? 0)} of '
                    '${formatMarks(attempt.maxScore)} marks',
                  ),
                ),
                if (attempt.isAwaitingMarks)
                  Chip(
                    key: const Key('review-to-mark'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.tertiaryContainer,
                    avatar: const Icon(Icons.rate_review_outlined, size: 16),
                    label: Text(
                      attempt.essaysToGrade == 1
                          ? '1 essay to mark'
                          : '${attempt.essaysToGrade} essays to mark',
                    ),
                  )
                else if (attempt.essayLines.isNotEmpty)
                  Chip(
                    key: const Key('review-fully-marked'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    avatar: const Icon(Icons.done_all, size: 16),
                    label: const Text('All essays marked'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One question of the paper as it was answered: what the student stored, what
/// the server made of it (for the shapes it grades), and — for an essay — the two
/// fields that produce its mark.
class _ReviewLine extends StatelessWidget {
  const _ReviewLine({
    required this.index,
    required this.total,
    required this.line,
    required this.marksController,
    required this.feedbackController,
    required this.error,
    required this.enabled,
  });

  final int index;
  final int total;
  final GradeLine line;
  final TextEditingController? marksController;
  final TextEditingController? feedbackController;
  final String? error;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final question = line.question;
    final id = question.id;

    return Card(
      key: Key('review-line-$id'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Question ${index + 1} of $total',
                  style: theme.textTheme.labelLarge,
                ),
                Chip(
                  key: Key('review-type-$id'),
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
            const SizedBox(height: 8),
            Text(question.questionText, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Text('Answer', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            if (!line.isAnswered)
              Text(
                'No answer was stored for this question.',
                key: Key('line-unanswered-$id'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  line.answerText ?? '',
                  key: Key('line-answer-$id'),
                ),
              ),
            const SizedBox(height: 12),
            ..._outcome(theme),
          ],
        ),
      ),
    );
  }

  /// The automatic half of "their respective grading views": the verdict
  /// `submit_exam()` reached at the close, shown next to the question it decided
  /// it about (and the key it compared against, so the decision is auditable).
  /// An essay gets its fields instead, because no key decides it.
  List<Widget> _outcome(ThemeData theme) {
    final id = line.question.id;
    if (line.isEssay) return _essayFields(theme);

    final correct = line.isCorrect;
    final colour = switch (correct) {
      true => Colors.green,
      false => theme.colorScheme.error,
      null => theme.colorScheme.onSurfaceVariant,
    };
    final icon = switch (correct) {
      true => Icons.check_circle_outline,
      false => Icons.cancel_outlined,
      null => Icons.remove_circle_outline,
    };
    final sentence = switch (correct) {
      true => 'Correct',
      false => 'Incorrect',
      null => 'Not answered — this question did not score.',
    };

    return [
      Row(
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              sentence,
              key: Key('line-verdict-$id'),
              style: theme.textTheme.bodyMedium?.copyWith(color: colour),
            ),
          ),
        ],
      ),
      if (line.expectedText != null) ...[
        const SizedBox(height: 4),
        Text(
          'Expected: ${line.expectedText}',
          key: Key('line-expected-$id'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ];
  }

  /// The essay's grading view: the mark, the remark, and what an earlier pass
  /// left on it — so a re-mark reads as a correction rather than as a blank
  /// slate.
  List<Widget> _essayFields(ThemeData theme) {
    final id = line.question.id;

    return [
      TextField(
        key: Key('essay-marks-$id'),
        controller: marksController,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          labelText: 'Marks',
          helperText: 'Out of ${formatMarks(line.points)}',
          prefixIcon: const Icon(Icons.star_outline),
          border: const OutlineInputBorder(),
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            error!,
            key: Key('essay-marks-error-$id'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      const SizedBox(height: 12),
      TextField(
        key: Key('essay-feedback-$id'),
        controller: feedbackController,
        enabled: enabled,
        minLines: 2,
        maxLines: 4,
        // Matches the cap `grade_submission()` applies to a row a report reads.
        maxLength: 2000,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Feedback to the student (optional)',
          hintText: 'What was strong, and what would earn more marks.',
          border: OutlineInputBorder(),
        ),
      ),
      if (line.isMarked)
        Text(
          'Already marked'
          '${line.gradedAt == null ? '' : ' on ${_shortDate(line.gradedAt!)}'}'
          ' — saving again corrects this mark.',
          key: Key('essay-marked-$id'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
    ];
  }
}

/// `dd/MM/yyyy` for a mark's own timestamp. Local, because the only person who
/// reads it is the lecturer who awarded it.
String _shortDate(DateTime value) => '${value.day.toString().padLeft(2, '0')}/'
    '${value.month.toString().padLeft(2, '0')}/'
    '${value.year}';
