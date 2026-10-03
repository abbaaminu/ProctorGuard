import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dashboard_providers.dart';

class AnalyticsPage extends ConsumerWidget {
  const AnalyticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(analyticsReportProvider);
    final theme = Theme.of(context);
    final gutter = MediaQuery.sizeOf(context).width >= 900 ? 32.0 : 16.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            key: const Key('analytics-refresh'),
            tooltip: 'Refresh analytics',
            onPressed: () => ref.invalidate(analyticsReportProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: report.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: EdgeInsets.all(gutter),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined),
                const SizedBox(height: 8),
                Text('Could not load analytics.\n$error',
                    textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => ref.invalidate(analyticsReportProvider),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () => ref.refresh(analyticsReportProvider.future),
          child: ListView(
            padding: EdgeInsets.all(gutter),
            children: [
              Text(
                'Exam outcomes and integrity. Incident counts cover the last '
                '$analyticsWindowDays days.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _MetricCard(label: 'Attempts', value: '${data.attempts}'),
                  _MetricCard(label: 'Completed', value: '${data.completed}'),
                  _MetricCard(label: 'Incidents (${analyticsWindowDays}d)',
                      value: '${data.incidents}'),
                  _MetricCard(
                    label: 'Disqualification rate',
                    value: '${data.disqualificationRate}%',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Per-exam breakdown',
                          style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        data.averageScore == null
                            ? 'Nothing graded yet'
                            : 'Mean score ${data.averageScore!.toStringAsFixed(1)} pts',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              if (data.exams.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('No exams yet.')),
                )
              else
                for (final exam in data.exams)
                  Card(
                    key: Key('analytics-exam-${exam.examId}'),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(exam.title,
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 10),
                          Text(
                            '${exam.attempts} attempts · ${exam.ongoing} in progress · '
                            '${exam.completed} completed · ${exam.disqualified} disqualified',
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Disqualification rate ${exam.disqualificationRate}% · '
                            '${exam.incidents} incident(s) · '
                            'Average score ${exam.averageScore?.toStringAsFixed(1) ?? '—'} pts',
                          ),
                          const SizedBox(height: 8),
                          LinearProgressIndicator(
                            value: exam.disqualificationRate / 100,
                            semanticsLabel:
                                'Disqualification rate ${exam.disqualificationRate} percent',
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 190,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Text(value, style: Theme.of(context).textTheme.headlineSmall),
              ],
            ),
          ),
        ),
      );
}
