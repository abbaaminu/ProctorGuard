import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../../core/widgets/responsive_layout.dart';
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../domain/entities/exam.dart';
import '../../domain/entities/submission.dart';
import '../providers/exam_providers.dart';
import '../widgets/published_exam_list.dart';
import 'exam_hardware_gate_page.dart';
import 'exam_taking_page.dart';

/// Builds the exam session screen for a started submission.
///
/// Injectable so widget tests can assert the routing contract (which examId and
/// submissionId were handed over) without opening a camera.
typedef ExamPageBuilder = Widget Function(String examId, String submissionId);

/// Runs the mandatory hardware check and reports whether the student may start.
///
/// Injectable for the same reason [ExamPageBuilder] is: the real screen opens a
/// camera and asks the OS for permissions, which a widget test cannot do. The
/// portal calls this **before** creating a submission, so a refused gate leaves
/// no `ongoing` attempt behind.
typedef HardwareGateRequest = Future<bool> Function(
  BuildContext context,
  Exam exam,
);

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
    this.hardwareGate,
    this.onSignOut,
  });

  /// Greeting name; the gate passes `profiles.full_name` ("Aisha Bello").
  final String? studentName;

  /// Defaults to [ExamTakingPage].
  final ExamPageBuilder? examPageBuilder;

  /// Defaults to pushing [ExamHardwareGatePage]. Returns true only when a real
  /// camera *and* microphone were verified.
  final HardwareGateRequest? hardwareGate;

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

    // The hardware gate runs *first*: no submission row is created and no
    // session screen is pushed until a real camera and microphone have been
    // verified. Refusing here (or backing out of the gate) leaves the student on
    // the list with nothing written to the server.
    final gate = widget.hardwareGate ?? _pushHardwareGate;
    final verified = await gate(context, exam);
    if (!mounted || !verified) return;

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

  /// The production gate: pushes [ExamHardwareGatePage] and reports whether the
  /// student may start. A dismissed screen (system back, `false`) counts as "not
  /// verified".
  Future<bool> _pushHardwareGate(BuildContext context, Exam exam) async {
    final verified = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ExamHardwareGatePage(exam: exam),
      ),
    );
    return verified ?? false;
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
    // Only used to keep the greeting honest if `profiles.full_name` is empty.
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
          // A centred, readable column: on a desktop browser the greeting and the
          // tiles would otherwise stretch the whole width of the monitor.
          ResponsiveContent(
            maxWidth: 720,
            alignment: Alignment.center,
            padding: EdgeInsets.fromLTRB(
              ResponsiveSizing.horizontalPadding(context),
              16,
              ResponsiveSizing.horizontalPadding(context),
              12,
            ),
            child: _PortalGreeting(name: widget.studentName ?? fallback),
          ),
          const Divider(height: 1),
          Expanded(
            child: ResponsiveContent(
              maxWidth: 720,
              padding: EdgeInsets.symmetric(
                horizontal: ResponsiveSizing.horizontalPadding(context),
              ),
              child: PublishedExamList(
                onOpen: _openExam,
                openingExamId: _openingExamId,
                emptyMessage: 'No exams are available for you right now.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The greeting, sized to whatever width the wrapper gives it (the wrapper owns
/// the gutters, so a desktop browser and a phone share this layout).
class _PortalGreeting extends StatelessWidget {
  const _PortalGreeting({this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final clean = (name ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          clean.isEmpty ? 'Welcome' : 'Welcome, $clean',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Pick an exam to begin. You will be asked to check that your camera '
          'and microphone work before the exam starts — the exam guards then '
          'run for the whole session.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
