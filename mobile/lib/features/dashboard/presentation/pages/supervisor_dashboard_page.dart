import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart';

/// Streams `proctoring_logs` and `exam_submissions` for a given exam via
/// Supabase Realtime, so supervisors see violations and status changes as
/// they happen — no polling.
final examSubmissionsStreamProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, examId) {
  return SupabaseService.instance.client
      .from('exam_submissions')
      .stream(primaryKey: ['id'])
      .eq('exam_id', examId)
      .order('started_at');
});

final liveViolationFeedProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, examId) {
  // proctoring_logs doesn't carry exam_id directly (normalized via
  // submission_id), so the dashboard filters client-side against the
  // submission IDs it already holds for this exam. For high-volume exams,
  // replace with a Postgres view joining logs -> submissions -> exam_id
  // and stream that view instead.
  return SupabaseService.instance.client
      .from('proctoring_logs')
      .stream(primaryKey: ['id'])
      .order('timestamp', ascending: false)
      .limit(200);
});

class SupervisorDashboardPage extends ConsumerWidget {
  final String examId;
  final String examTitle;
  const SupervisorDashboardPage({super.key, required this.examId, required this.examTitle});

  Color _statusColor(String status) => switch (status) {
        'ongoing' => Colors.blue,
        'submitted' => Colors.green,
        'disqualified' => Colors.red,
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final submissions = ref.watch(examSubmissionsStreamProvider(examId));
    final allLogs = ref.watch(liveViolationFeedProvider(examId));

    return Scaffold(
      appBar: AppBar(title: Text('Live Monitor — $examTitle')),
      body: Row(
        children: [
          // ---- Student status grid --------------------------------------
          Expanded(
            flex: 3,
            child: submissions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (rows) {
                final submissionIds = rows.map((r) => r['id'] as String).toSet();
                return ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final s = rows[i];
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _statusColor(s['status'] as String),
                          child: Text(
                            (s['status'] as String).substring(0, 1).toUpperCase(),
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text('Student: ${s['student_id']}'),
                        subtitle: Text(
                          'Status: ${s['status']}'
                          '${s['score'] != null ? ' • Score: ${s['score']}' : ''}',
                        ),
                        trailing: allLogs.when(
                          data: (logs) {
                            final count = logs
                                .where((l) => submissionIds.contains(l['submission_id']))
                                .where((l) => l['submission_id'] == s['id'])
                                .length;
                            return Text('$count flags');
                          },
                          loading: () => const SizedBox.shrink(),
                          error: (_, _) => const SizedBox.shrink(),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const VerticalDivider(width: 1),
          // ---- Live violation feed ---------------------------------------
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Live Violation Feed',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                Expanded(
                  child: allLogs.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Error: $e')),
                    data: (logs) => ListView.builder(
                      itemCount: logs.length,
                      itemBuilder: (context, i) {
                        final log = logs[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.flag, color: Colors.orange, size: 18),
                          title: Text(log['action_type'] as String),
                          subtitle: Text(log['timestamp'] as String),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
