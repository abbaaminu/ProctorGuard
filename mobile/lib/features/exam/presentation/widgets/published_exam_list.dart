import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/exam.dart';
import '../providers/exam_providers.dart';

/// Loading / error / empty / list states for [publishedExamsProvider], shared by
/// the student portal and the supervisor picker so both react to a slow or
/// unreachable backend identically.
class PublishedExamList extends ConsumerWidget {
  const PublishedExamList({
    super.key,
    required this.onOpen,
    this.openingExamId,
    this.emptyMessage = 'No exams have been published yet.',
  });

  /// Called with the exam the user tapped; the caller starts the submission (or
  /// opens the monitor) and navigates.
  final void Function(Exam exam) onOpen;

  /// Exam currently being opened: its tile shows a spinner and taps are ignored,
  /// so a double tap cannot create two submissions.
  final String? openingExamId;

  final String emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exams = ref.watch(publishedExamsProvider);

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
  });

  final Exam exam;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        key: Key('exam-${exam.id}'),
        enabled: enabled,
        leading: const CircleAvatar(child: Icon(Icons.assignment_outlined)),
        title: Text(exam.title),
        subtitle: Text('${exam.durationMinutes} minutes'),
        trailing: busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right),
        onTap: enabled ? onTap : null,
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
