import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../../core/widgets/responsive_layout.dart';
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../domain/entities/exam.dart';
import '../../domain/entities/exam_submit_result.dart';
import '../../domain/entities/submission.dart';
import '../providers/exam_providers.dart';
import '../widgets/exam_instructions_dialog.dart';
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
    this.clock,
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

  /// The instant a scheduled paper is judged against, defaulting to the wall
  /// clock. Injectable for the same reason the list's own seam is: a widget test
  /// asserts "this paper has not opened yet" without waiting for a real window.
  final DateTime Function()? clock;

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

    // The window, re-checked here as well as on the tile: the list was rendered
    // from an earlier `now`, so a paper that closed in the meantime would still
    // be tappable. The server refuses the attempt row either way
    // (`submissions_insert_own_ongoing`), but a sentence beats a 42501.
    final reason = exam.closedReason((widget.clock ?? DateTime.now)());
    if (reason != null) {
      _showMessage('“${exam.title}” is not open right now. $reason');
      return;
    }

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
      // The session screen hands its result back through the pop. That is what
      // makes the result *instant* for a paper with no essay on it: `submit_exam`
      // has already graded it by the time the student is back on this list, so the
      // mark is shown here instead of being left for a "results will be released"
      // that has nothing left to wait for.
      final result = await Navigator.of(context).push<ExamSubmitResult>(
        MaterialPageRoute<ExamSubmitResult>(
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
                  // Identity for the exam surface: the session screen has no
                  // profile provider of its own, and the portal already holds both
                  // (the gate passes `profiles.full_name` in as `studentName`).
                  candidateName: widget.studentName,
                  examTitle: exam.title,
                  candidateEmail: SupabaseService.instance.currentUser?.email,
                ),
        ),
      );
      if (!mounted || result == null) return;
      _showResult(exam, result);
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

  /// What the student is told the moment an attempt closes.
  ///
  /// An objective paper is already marked when the session screen hands the result
  /// back ([ExamSubmitResult.hasFinalScore]), so the score *is* the answer and it
  /// is shown without a "results will be released later" hedge that has nothing
  /// left to wait for. A paper with an essay on it says the opposite, in the same
  /// place and with the same emphasis: the number the server returned is only the
  /// automatic half, and a lecturer marks the written answers afterwards.
  void _showResult(Exam exam, ExamSubmitResult result) {
    final theme = Theme.of(context);

    final String title;
    final String body;
    final IconData icon;

    if (result.isDisqualified) {
      title = 'Attempt disqualified';
      body = 'Your "${exam.title}" attempt was closed as disqualified, so it '
          'was not marked. Your supervisor can show you what happened, and can '
          'reset the attempt if the decision was wrong.';
      icon = Icons.gpp_bad_outlined;
    } else if (result.hasFinalScore) {
      title = 'Your result';
      body = 'You scored ${result.scoreLabel} on "${exam.title}". That is your '
          'final mark — every question on the paper was marked automatically.';
      icon = Icons.emoji_events_outlined;
    } else {
      title = 'Answers submitted';
      body = 'Your answers to "${exam.title}" are in. The written answers are '
          'marked by your lecturer, so your score is not final yet — it appears '
          'here once they are done.';
      icon = Icons.mark_email_read_outlined;
    }

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('exam-result-dialog'),
        icon: Icon(icon, size: 40, color: theme.colorScheme.primary),
        title: Text(title),
        content: Text(body),
        actions: [
          FilledButton(
            key: const Key('exam-result-done'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
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
            key: const Key('portal-instructions'),
            tooltip: 'Exam instructions',
            // Available before any paper is chosen: what the proctor does, and
            // what the paper's own rules are, are worth reading before deciding
            // which one to sit.
            onPressed: () => showExamInstructions(context),
            icon: const Icon(Icons.menu_book_outlined),
          ),
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
                // A student may not start a paper outside its window; the
                // supervisor's picker (the other caller) deliberately does not
                // lock, because monitoring a closed sitting is its purpose.
                lockWhenNotOpen: true,
                clock: widget.clock,
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
