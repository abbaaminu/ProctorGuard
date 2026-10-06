import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/home_button.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../../exam/domain/entities/submission.dart';
import '../../domain/entities/attempt_grading.dart';
import '../../domain/repositories/question_authoring_repository.dart';
import '../providers/question_authoring_providers.dart';
import 'attempt_review_page.dart';

/// Every handed-in attempt on one paper, and how much of it still needs marks.
///
/// "Waiting for marks" is derived rather than looking at `status`: an attempt
/// whose paper contains an essay is only *partly* graded when it is handed in
/// (`submit_exam()` scores everything it holds a key for and nothing else), so
/// the queue a lecturer needs to work through is exactly "which essays have no
/// `question_grades` row yet".
class AttemptGradingPage extends ConsumerStatefulWidget {
  const AttemptGradingPage({
    super.key,
    required this.examId,
    required this.examTitle,
  });

  final String examId;
  final String examTitle;

  @override
  ConsumerState<AttemptGradingPage> createState() => _AttemptGradingPageState();
}

class _AttemptGradingPageState extends ConsumerState<AttemptGradingPage> {
  Future<void> _openAttempt(AttemptGrading attempt) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttemptReviewPage(
          examId: widget.examId,
          examTitle: widget.examTitle,
          attempt: attempt,
        ),
      ),
    );
    // The marks (and the totals on this list) changed, so the list is refetched
    // rather than patched: the server recomputed `score`, and guessing it here
    // would mean two answers to one question.
    if (mounted) ref.invalidate(examAttemptsProvider(widget.examId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final attempts = ref.watch(examAttemptsProvider(widget.examId));

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Marks'),
        actions: [
          const HomeButton(key: Key('grading-home')),
          IconButton(
            key: const Key('grading-back'),
            tooltip: 'Back to my papers',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            key: const Key('grading-refresh'),
            tooltip: 'Refresh',
            onPressed: () =>
                ref.invalidate(examAttemptsProvider(widget.examId)),
            icon: const Icon(Icons.refresh),
          ),
        ],
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
                  'Attempts that have been handed in. Open one to see every '
                  'answer and to award the marks on its essays.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: attempts.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _GradingError(
                message: error is AuthoringException
                    ? error.message
                    : 'Could not load this paper’s attempts.',
                onRetry: () =>
                    ref.invalidate(examAttemptsProvider(widget.examId)),
              ),
              data: (rows) => rows.isEmpty
                  ? const _NoAttempts()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _AttemptCard(
                        attempt: rows[index],
                        onOpen: () => _openAttempt(rows[index]),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One handed-in attempt: whose it is, how much of the paper is marked, and the
/// total the server holds so far.
class _AttemptCard extends StatelessWidget {
  const _AttemptCard({required this.attempt, required this.onOpen});

  final AttemptGrading attempt;
  final VoidCallback onOpen;

  /// A disqualified attempt has no score by design (`submit_exam()` nulls it —
  /// a score would imply it counts), so it is labelled rather than shown as 0,
  /// which would read like a failed paper.
  String get _scoreLine =>
      attempt.submission.status == SubmissionStatus.disqualified
          ? 'Disqualified — not marked'
          : '${formatMarks(attempt.score ?? 0)} of '
              '${formatMarks(attempt.maxScore)} marks';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = attempt.submission.id;
    final answered = attempt.lines.where((line) => line.isAnswered).length;

    return Card(
      key: Key('attempt-$id'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: attempt.isAwaitingMarks
              ? theme.colorScheme.tertiaryContainer
              : theme.colorScheme.secondaryContainer,
          child: Icon(
            attempt.isAwaitingMarks
                ? Icons.rate_review_outlined
                : Icons.done_all,
          ),
        ),
        title: Text(attempt.studentName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text('$answered of ${attempt.lines.length} answered'),
            Text(
              _scoreLine,
              key: Key('attempt-score-$id'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        trailing: attempt.isAwaitingMarks
            ? Chip(
                key: Key('attempt-waiting-$id'),
                visualDensity: VisualDensity.compact,
                backgroundColor: theme.colorScheme.tertiaryContainer,
                label: Text(
                  attempt.essaysToGrade == 1
                      ? '1 to mark'
                      : '${attempt.essaysToGrade} to mark',
                ),
              )
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

/// The attempts could not be read: the repository's own sentence, with a retry.
class _GradingError extends StatelessWidget {
  const _GradingError({required this.message, required this.onRetry});

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
              key: const Key('grading-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('grading-retry'),
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

/// Nobody has handed this paper in yet.
class _NoAttempts extends StatelessWidget {
  const _NoAttempts();

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
              Icons.inbox_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Nothing to mark yet.',
              key: const Key('grading-empty'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text(
              'An attempt appears here as soon as a student hands it in.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
