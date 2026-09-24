import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../domain/entities/exam.dart';
import '../../domain/entities/submission.dart';
import '../providers/exam_providers.dart';
import '../widgets/published_exam_list.dart';
import 'exam_taking_page.dart';

/// Builds the exam session screen for a started submission.
///
/// Injectable so widget tests can assert the routing contract (which examId and
/// submissionId were handed over) without opening a camera.
typedef ExamPageBuilder = Widget Function(String examId, String submissionId);

/// The student home: every published exam (CS101, MAT201, …) and the state of
/// this student's own attempt at each one.
///
/// Tapping an exam starts or resumes its submission and pushes the session
/// screen — [ExamTakingPage] by default, which is where the camera/mock feed,
/// question navigation, kiosk pinning and the browser guards live. An attempt
/// that is already `submitted` or `disqualified` is reported instead of being
/// reopened: the server owns that state, and re-sitting a closed attempt would
/// only produce a rejected write.
class StudentExamPortalPage extends ConsumerStatefulWidget {
  const StudentExamPortalPage({
    super.key,
    this.studentName,
    this.examPageBuilder,
    this.onSignOut,
  });

  /// Greeting name; the gate passes `users.name` ("Aisha Bello").
  final String? studentName;

  /// Defaults to [ExamTakingPage].
  final ExamPageBuilder? examPageBuilder;

  /// Sign-out shown in the app bar (the gate owns the Supabase call).
  final VoidCallback? onSignOut;

  @override
  ConsumerState<StudentExamPortalPage> createState() =>
      _StudentExamPortalPageState();
}

class _StudentExamPortalPageState extends ConsumerState<StudentExamPortalPage> {
  /// Exam whose submission is currently being created — one at a time, so a
  /// double tap cannot start two sessions.
  String? _openingExamId;

  Future<void> _openExam(Exam exam) async {
    if (_openingExamId != null) return;
    setState(() => _openingExamId = exam.id);

    try {
      final submission = await ref
          .read(examRepositoryProvider)
          .startOrResumeSubmission(exam.id);
      if (!mounted) return;

      if (submission.status != SubmissionStatus.ongoing) {
        _showMessage(switch (submission.status) {
          SubmissionStatus.disqualified =>
            'Your "${exam.title}" attempt was disqualified. '
                'Speak to your supervisor before retaking it.',
          SubmissionStatus.submitted =>
            'You have already submitted "${exam.title}".',
          SubmissionStatus.ongoing => '', // handled above
        });
        return;
      }

      final builder = widget.examPageBuilder;
      await Navigator.of(context).push(
        MaterialPageRoute(
          // The default session screen gets the exam duration and the
          // submission's start time, which is what the countdown runs on; the
          // injectable builder stays a plain (examId, submissionId) factory so
          // widget tests can swap it out.
          builder: (_) => builder != null
              ? builder(exam.id, submission.id)
              : ExamTakingPage(
                  examId: exam.id,
                  submissionId: submission.id,
                  durationMinutes: exam.durationMinutes,
                  startedAt: submission.startedAt,
                ),
        ),
      );
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not start "${exam.title}". Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _openingExamId = null);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 6),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // Only used to keep the greeting honest if `users.name` is empty.
    final fallback = SupabaseService.instance.currentUser?.email;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // the gate is the only parent
        title: const Text('Student Exam Portal'),
        actions: [
          IconButton(
            key: const Key('portal-refresh'),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(publishedExamsProvider),
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onSignOut != null)
            IconButton(
              key: const Key('portal-sign-out'),
              tooltip: 'Sign out',
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PortalGreeting(name: widget.studentName ?? fallback),
          const Divider(height: 1),
          Expanded(
            child: PublishedExamList(
              onOpen: _openExam,
              openingExamId: _openingExamId,
              emptyMessage: 'No exams are available for you right now.',
            ),
          ),
        ],
      ),
    );
  }
}

class _PortalGreeting extends StatelessWidget {
  const _PortalGreeting({this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clean = (name ?? '').trim();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clean.isEmpty ? 'Welcome' : 'Welcome, $clean',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Pick an exam to begin. Your camera and the exam guards start as '
            'soon as the session opens.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
