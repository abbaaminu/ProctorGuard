import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/exam.dart';
import '../providers/exam_providers.dart';

/// Loading / error / empty / list states for [publishedExamsProvider], shared by
/// the student portal and the supervisor picker so both react to a slow or
/// unreachable backend identically.
///
/// The two callers differ in exactly one way, which [lockWhenNotOpen] names: a
/// **student** may not start a paper outside its `starts_at` / `ends_at` window,
/// so the portal locks those tiles and says why, while a **supervisor** monitors
/// whatever the picker offers — a sitting that has not opened yet, or one that
/// closed an hour ago, is exactly the kind of paper they open the monitor on.
class PublishedExamList extends ConsumerWidget {
  const PublishedExamList({
    super.key,
    required this.onOpen,
    this.openingExamId,
    this.emptyMessage = 'No exams have been published yet.',
    this.lockWhenNotOpen = false,
    this.clock,
  });

  /// Called with the exam the user tapped; the caller starts the submission (or
  /// opens the monitor) and navigates.
  final void Function(Exam exam) onOpen;

  /// Exam currently being opened: its tile shows a spinner and taps are ignored,
  /// so a double tap cannot create two submissions.
  final String? openingExamId;

  final String emptyMessage;

  /// Lock the tiles whose window has not opened, or has closed. Set by the
  /// student portal; false for the supervisor's picker (see the class comment).
  final bool lockWhenNotOpen;

  /// The instant a tile's window is judged against, defaulting to the wall
  /// clock. Injectable so a widget test can hold "now" still instead of racing
  /// it — the same seam `HardwareVerifier` and `RoleGate.currentUserId` use.
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exams = ref.watch(publishedExamsProvider);
    final now = (clock ?? DateTime.now)();

    return RefreshIndicator(
      onRefresh: () async => ref.invalidate(publishedExamsProvider),
      child: exams.when(
        loading: () => _scrollable(const CircularProgressIndicator()),
        error: (error, _) => _scrollable(
          _ExamListError(
            onRetry: () => ref.invalidate(publishedExamsProvider),
          ),
        ),
        data: (rows) => rows.isEmpty
            ? _scrollable(Text(emptyMessage))
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: rows.length,
                itemBuilder: (context, i) => _ExamTile(
                  exam: rows[i],
                  busy: openingExamId == rows[i].id,
                  enabled: openingExamId == null,
                  lockReason: lockWhenNotOpen
                      ? rows[i].closedReason(now)
                      : null,
                  onTap: () => onOpen(rows[i]),
                ),
              ),
      ),
    );
  }

  /// Keeps pull-to-refresh working in every state: the non-list states have no
  /// inherent scroll extent, so they get a minimum-height scrollable.
  Widget _scrollable(Widget child) => LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: child,
              ),
            ),
          ),
        ),
      );
}

class _ExamTile extends StatelessWidget {
  const _ExamTile({
    required this.exam,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.lockReason,
  });

  final Exam exam;
  final bool busy;
  final bool enabled;

  /// Why this paper cannot be started yet, or null when it can. Non-null makes
  /// the tile inert: there is nothing to tap until the window opens (or, for a
  /// closed paper, ever again), so the tile says so instead of offering a tap
  /// that the server would refuse.
  final String? lockReason;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locked = lockReason != null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        key: Key('exam-${exam.id}'),
        enabled: enabled && !locked,
        leading: locked
            ? CircleAvatar(
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.lock_clock,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : const CircleAvatar(child: Icon(Icons.assignment_outlined)),
        title: Text(exam.title),
        // Two lines rather than one string: the duration is what the student
        // plans the sitting around, the window is when it is offered, and a
        // scheduled paper has both.
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${exam.durationMinutes} minutes'),
            if (exam.isScheduled)
              Text(
                exam.scheduleLabel,
                key: Key('exam-window-${exam.id}'),
              ),
            if (locked)
              Text(
                lockReason!,
                key: Key('exam-locked-${exam.id}'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
          ],
        ),
        isThreeLine: exam.isScheduled || locked,
        trailing: busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : locked
                ? const Icon(Icons.lock_outline)
                : const Icon(Icons.chevron_right),
        onTap: enabled && !locked ? onTap : null,
      ),
    );
  }
}

class _ExamListError extends StatelessWidget {
  const _ExamListError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.cloud_off_outlined, size: 40, color: theme.colorScheme.error),
        const SizedBox(height: 12),
        Text('Could not load exams', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'Check your connection and try again.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('exams-retry'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    );
  }
}
