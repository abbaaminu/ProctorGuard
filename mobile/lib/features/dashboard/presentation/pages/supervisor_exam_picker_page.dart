import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../exam/domain/entities/exam.dart';
import '../../../exam/presentation/providers/exam_providers.dart';
import '../../../exam/presentation/widgets/published_exam_list.dart';
import 'supervisor_dashboard_page.dart';

/// The supervisor home: pick an exam, then watch it live.
///
/// Deliberately the same list widget as the student portal — a supervisor sees
/// the same published exams their students do (RLS already scopes the rows), but
/// tapping one opens [SupervisorDashboardPage] instead of a session.
class SupervisorExamPickerPage extends ConsumerStatefulWidget {
  const SupervisorExamPickerPage({
    super.key,
    this.supervisorName,
    this.onSignOut,
  });

  /// Greeting name; the gate passes `profiles.full_name` ("Dr. Ada Nwosu").
  final String? supervisorName;

  /// Sign-out shown in the app bar (the gate owns the Supabase call).
  final VoidCallback? onSignOut;

  @override
  ConsumerState<SupervisorExamPickerPage> createState() =>
      _SupervisorExamPickerPageState();
}

class _SupervisorExamPickerPageState
    extends ConsumerState<SupervisorExamPickerPage> {
  void _openMonitor(Exam exam) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SupervisorDashboardPage(
          examId: exam.id,
          examTitle: exam.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fallback = SupabaseService.instance.currentUser?.email;
    final name = (widget.supervisorName ?? fallback ?? '').trim();

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Supervisor Console'),
        actions: [
          IconButton(
            key: const Key('supervisor-refresh'),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(publishedExamsProvider),
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onSignOut != null)
            IconButton(
              key: const Key('supervisor-sign-out'),
              tooltip: 'Sign out',
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Welcome' : 'Welcome, $name',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Pick an exam to open its live monitor.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: PublishedExamList(
              onOpen: _openMonitor,
              emptyMessage: 'No published exams to monitor yet.',
            ),
          ),
        ],
      ),
    );
  }
}
