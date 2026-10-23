import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../../core/utils/academic_catalog.dart';
import '../../../../core/widgets/home_button.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../../auth/domain/entities/user_profile.dart';
import '../../../dashboard/presentation/pages/supervisor_exam_picker_page.dart';
import '../../../exam/domain/entities/exam.dart';
import '../../domain/entities/authored_exam.dart';
import '../../domain/repositories/question_authoring_repository.dart';
import '../providers/question_authoring_providers.dart';
import 'attempt_grading_page.dart';
import 'question_authoring_page.dart';

/// The lecturer home: the papers **this account owns**, and the two things a
/// lecturer does with one — author its questions, and mark what came back.
///
/// The ownership filter is the point of the screen rather than a convenience.
/// `exams_select` would show every member of staff every paper in the
/// institution, but only the author may change a paper or award marks on it
/// (`exams_update_owner`, `questions_update_owner`, and the owner check inside
/// `grade_submission()`), so a console listing papers it cannot act on would be
/// an invitation to a refusal.
///
/// Invigilation is deliberately *not* duplicated here: a lecturer's monitoring
/// and attempt-reset tools are the supervisor console's, one tap away in the app
/// bar ([_openMonitor]). Lecturers share `is_staff()` with supervisors for
/// reading, and share the *reset* tier with them too (`is_attempt_resetter()`),
/// because resetting an attempt on the paper they wrote is their repair for a
/// wrong key or a mis-aimed disqualification. What stays narrower is the
/// intervention tier: `is_exam_supervisor()` still guards writing to somebody
/// else's attempt row in place (a status change, an after-the-fact re-grade), and
/// the paper is theirs to mark.
class LecturerConsolePage extends ConsumerStatefulWidget {
  const LecturerConsolePage({
    super.key,
    this.lecturerName,
    this.onSignOut,
  });

  /// Greeting name; the gate passes the signed-in profile's `full_name`.
  final String? lecturerName;

  /// Sign-out shown in the app bar (the gate owns the Supabase call).
  final VoidCallback? onSignOut;

  @override
  ConsumerState<LecturerConsolePage> createState() =>
      _LecturerConsolePageState();
}

class _LecturerConsolePageState extends ConsumerState<LecturerConsolePage> {
  /// The paper whose action is in flight, so exactly one row is disabled — the
  /// same shape the admin roster uses for its own per-row work.
  String? _busyId;

  void _showMessage(String message, {bool isError = true}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  Future<void> _createExam() async {
    if (_busyId != null) return;

    final request = await showDialog<_NewExamRequest>(
      context: context,
      builder: (_) => const _NewExamDialog(),
    );
    if (request == null || !mounted) return;

    setState(() => _busyId = 'new');
    try {
      final created =
          await ref.read(questionAuthoringRepositoryProvider).createExam(
                title: request.title,
                durationMinutes: request.durationMinutes,
                isPublished: request.isPublished,
                // Null for an unscheduled paper — the repository omits the key
                // rather than sending null, so the column keeps its NULL default.
                startsAt: request.startsAt,
                endsAt: request.endsAt,
                // The target cohort, likewise omitted when the author left the
                // dropdowns alone: NULL there is "not narrowed", and the policy
                // reads it as "offered to everybody it used to be".
                faculty: request.faculty,
                department: request.department,
                level: request.level,
              );
      if (!mounted) return;
      ref.invalidate(myAuthoredExamsProvider);
      final target = created.exam.targetLabel;
      _showMessage(
        request.isPublished
            ? '“${created.exam.title}” is published'
                '${target == null ? '' : ' to $target'}. Add its questions '
                'before students sit it.'
            : '“${created.exam.title}” is saved as a draft'
                '${target == null ? '' : ' for $target'}. Publish it when its '
                'questions are ready.',
        isError: false,
      );
    } on AuthoringException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _openQuestions(AuthoredExam exam) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QuestionAuthoringPage(
          examId: exam.exam.id,
          examTitle: exam.exam.title,
        ),
      ),
    );
    // The question count on the tile is part of this list, so it is refetched
    // rather than patched locally.
    if (mounted) ref.invalidate(myAuthoredExamsProvider);
  }

  Future<void> _openGrading(AuthoredExam exam) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AttemptGradingPage(
          examId: exam.exam.id,
          examTitle: exam.exam.title,
        ),
      ),
    );
    if (mounted) ref.invalidate(myAuthoredExamsProvider);
  }

  /// The supervisor console: the live monitor and the reset control, which is
  /// the invigilation half of a lecturer's job. The flag is asked of the role
  /// rather than hard-coded, so this screen and the role gate cannot disagree:
  /// `UserRole.lecturer.canResetAttempts` is the schema's own rule
  /// (`is_attempt_resetter()` names admin, supervisor and lecturer), not a
  /// preference of this screen.
  void _openMonitor() {
    final fallback = widget.lecturerName ??
        SupabaseService.instance.currentUser?.email ??
        '';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SupervisorExamPickerPage(
          supervisorName: fallback,
          canResetAttempts: UserRole.lecturer.canResetAttempts,
        ),
      ),
    );
  }

  Future<void> _togglePublished(AuthoredExam exam) async {
    if (_busyId != null) return;
    final publish = !exam.exam.isPublished;

    // Publishing an empty paper would hand students a session with no questions,
    // so it is refused here with the fix named rather than allowed and then
    // discovered on the exam screen.
    if (publish && !exam.hasQuestions) {
      _showMessage(
        'Add at least one question before publishing “${exam.exam.title}”.',
      );
      return;
    }

    setState(() => _busyId = exam.exam.id);
    try {
      await ref
          .read(questionAuthoringRepositoryProvider)
          .setPublished(examId: exam.exam.id, isPublished: publish);
      if (!mounted) return;
      ref.invalidate(myAuthoredExamsProvider);
      _showMessage(
        publish
            ? '“${exam.exam.title}” is published — students can start it.'
            : '“${exam.exam.title}” is back to draft. Attempts already in '
                'progress are not disturbed.',
        isError: false,
      );
    } on AuthoringException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _deleteExam(AuthoredExam exam) async {
    if (_busyId != null) return;

    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete “${exam.exam.title}”?'),
        content: Text(
          'Its ${exam.questionCount} '
          '${exam.questionCount == 1 ? 'question' : 'questions'}, '
          '${exam.attemptCount} '
          '${exam.attemptCount == 1 ? 'attempt' : 'attempts'}, every answer, '
          'every mark and every proctoring incident go with it. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('exam-delete-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete paper'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() => _busyId = exam.exam.id);
    try {
      await ref
          .read(questionAuthoringRepositoryProvider)
          .deleteExam(exam.exam.id);
      if (!mounted) return;
      ref.invalidate(myAuthoredExamsProvider);
      _showMessage('Deleted “${exam.exam.title}”.', isError: false);
    } on AuthoringException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = SupabaseService.instance.currentUser?.email;
    final name = (widget.lecturerName ?? fallback ?? '').trim();
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final exams = ref.watch(myAuthoredExamsProvider);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Lecturer Console'),
        actions: [
          // The landing page: there is nothing above it to pop, and one Home
          // control in the same place on every screen this console opens (see
          // [HomeButton]).
          const HomeButton(key: Key('lecturer-home')),
          IconButton(
            key: const Key('lecturer-monitor'),
            tooltip: 'Open the proctoring console',
            onPressed: _openMonitor,
            icon: const Icon(Icons.visibility_outlined),
          ),
          IconButton(
            key: const Key('lecturer-refresh'),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(myAuthoredExamsProvider),
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onSignOut != null)
            IconButton(
              key: const Key('lecturer-sign-out'),
              tooltip: 'Sign out',
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('lecturer-new-exam'),
        onPressed: _busyId == null ? _createExam : null,
        icon: const Icon(Icons.add),
        label: const Text('New paper'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Welcome' : 'Welcome, $name',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Author the papers you own, then mark what comes back.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: exams.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ConsoleError(
                message: error is AuthoringException
                    ? error.message
                    : 'Could not load your papers.',
                onRetry: () => ref.invalidate(myAuthoredExamsProvider),
              ),
              data: (rows) => RefreshIndicator(
                onRefresh: () async => ref.invalidate(myAuthoredExamsProvider),
                child: rows.isEmpty
                    ? const _NoPapers()
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        // Room for the floating action, so the last paper is
                        // never hidden behind it.
                        padding: const EdgeInsets.only(bottom: 88),
                        itemCount: rows.length,
                        itemBuilder: (context, index) => _ExamCard(
                          exam: rows[index],
                          busy: _busyId == rows[index].exam.id,
                          enabled: _busyId == null,
                          onAuthorQuestions: () => _openQuestions(rows[index]),
                          onGrade: () => _openGrading(rows[index]),
                          onTogglePublished: () =>
                              _togglePublished(rows[index]),
                          onDelete: () => _deleteExam(rows[index]),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the "new paper" dialog answers with. A record would do, but this is read
/// in two places and a name keeps the dialog's contract obvious.
///
/// [startsAt] / [endsAt] are local instants, or null for an unscheduled paper:
/// the dialog's pickers work in the author's own zone and the repository is what
/// converts to the UTC the column stores.
///
/// [faculty] / [department] / [level] are the paper's target cohort, or null for
/// "not narrowed": the labels the database policy compares against a student's
/// profile. They are sent as chosen — the repository omits unset ones rather than
/// sending blanks.
class _NewExamRequest {
  const _NewExamRequest({
    required this.title,
    required this.durationMinutes,
    required this.isPublished,
    this.startsAt,
    this.endsAt,
    this.faculty,
    this.department,
    this.level,
  });

  final String title;
  final int durationMinutes;
  final bool isPublished;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final String? faculty;
  final String? department;
  final String? level;
}

/// The "new paper" dialog: a title, how long it runs, an *optional* window, and
/// whether it is visible to students yet.
///
/// It opens on **draft** deliberately. A published paper appears in the student
/// portal immediately, and a paper with no questions yet is a session that
/// cannot be sat — so the default is the one that cannot go wrong, and the
/// console's own Publish control is one tap away once questions exist.
///
/// The window is optional in the same spirit: an author who wants an unscheduled
/// paper (the common case, and every paper the console could create before the
/// columns existed) simply never taps the two pickers, and nothing is sent.
/// Setting only one bound is allowed and meaningful — "opens Monday" with no
/// close, or a hard close with no opening time.
class _NewExamDialog extends StatefulWidget {
  const _NewExamDialog();

  @override
  State<_NewExamDialog> createState() => _NewExamDialogState();
}

class _NewExamDialogState extends State<_NewExamDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _durationController = TextEditingController(text: '60');
  bool _published = false;

  /// Local instants, or null for "no bound". Both are cleared by the same
  /// control that set them, so an accidental window is undone without leaving
  /// the dialog.
  DateTime? _startsAt;
  DateTime? _endsAt;

  /// Set when the two bounds disagree (or a clear leaves one behind in a way the
  /// pair cannot express). Shown inside the dialog rather than as a snack bar:
  /// the author is still editing the paper, so the fix belongs next to it.
  String? _windowError;

  /// The target cohort, or null for "not narrowed" — the state every paper the
  /// console could create before targeting existed is in, and the state that
  /// keeps a paper offered to every student the policy lets see it.
  String? _faculty;
  String? _department;
  String? _level;

  /// The department choices for the faculty currently chosen. With no faculty
  /// picked this is the whole catalogue, so a lecturer who only knows the
  /// department is not forced to answer a question they do not need to.
  List<String> get _departmentOptions =>
      AcademicCatalog.departmentsFor(_faculty);

  /// Picking a faculty narrows the department list, so a department left over
  /// from the previous faculty is dropped rather than silently re-submitted: the
  /// pair would then describe no cohort in the institution.
  void _selectFaculty(String? faculty) {
    setState(() {
      _faculty = faculty;
      if (_department != null &&
          !_departmentOptions.contains(_department)) {
        _department = null;
      }
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _durationController.dispose();
    super.dispose();
  }

  String? _validateTitle(String? value) =>
      (value ?? '').trim().isEmpty ? 'Give the paper a title' : null;

  /// The schema floors this at 1 minute (`duration_minutes > 0`); the ceiling is
  /// this screen's own, because an eight-hour paper is a typo rather than a
  /// duration. Both are checked before the server sees the row.
  String? _validateDuration(String? value) {
    final minutes = int.tryParse((value ?? '').trim());
    if (minutes == null) return 'Enter the duration in minutes';
    if (minutes < 1) return 'At least 1 minute';
    if (minutes > 480) return 'At most 480 minutes (8 hours)';
    return null;
  }

  /// A date and a time in one tap-through, because a window is a date *and* an
  /// instant: two controls per bound would be four interactions for one idea.
  ///
  /// `showDatePicker`/`showTimePicker` are inside `if (!mounted) return` guards:
  /// the author may have closed the dialog while one was open, and the awaited
  /// setState would then land on a disposed State.
  Future<void> _pickBound({required bool isStart}) async {
    final current = isStart ? _startsAt : _endsAt;
    final fallback = isStart
        ? (_endsAt ?? DateTime.now())
        : (_startsAt?.add(const Duration(hours: 2)) ?? DateTime.now());

    final date = await showDatePicker(
      context: context,
      initialDate: current ?? fallback,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      helpText: isStart ? 'When the paper opens' : 'When the paper closes',
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current ?? fallback),
      helpText: isStart ? 'What time it opens' : 'What time it closes',
    );
    if (time == null || !mounted) return;

    setState(() {
      final picked =
          DateTime(date.year, date.month, date.day, time.hour, time.minute);
      if (isStart) {
        _startsAt = picked;
      } else {
        _endsAt = picked;
      }
      _windowError = null;
    });
  }

  void _clearBound({required bool isStart}) {
    setState(() {
      if (isStart) {
        _startsAt = null;
      } else {
        _endsAt = null;
      }
      _windowError = null;
    });
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final start = _startsAt;
    final end = _endsAt;
    // The database's `exams_window_ordered` check is the backstop, but a 23514
    // from the server would arrive as "the server refused that paper" with the
    // dialog already gone — and a window that closes before it opens is a
    // mistake the author can see and fix here.
    if (start != null && end != null && !end.isAfter(start)) {
      setState(() {
        _windowError = 'The closing time must be after the opening time.';
      });
      return;
    }

    Navigator.pop(
      context,
      _NewExamRequest(
        title: _titleController.text.trim(),
        durationMinutes: int.parse(_durationController.text.trim()),
        isPublished: _published,
        startsAt: start,
        endsAt: end,
        faculty: _faculty,
        department: _department,
        level: _level,
      ),
    );
  }

  /// One optional academic label, as a dropdown whose first entry is "not
  /// narrowed".
  ///
  /// `initialValue`, not the deprecated `value`: the field owns what the author
  /// tapped and is rebuilt from the state above whenever that changes (picking a
  /// different faculty, say).
  Widget _labelField({
    required Key fieldKey,
    required String label,
    required IconData icon,
    required String anyLabel,
    required List<String> options,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) =>
      DropdownButtonFormField<String?>(
        key: fieldKey,
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          border: const OutlineInputBorder(),
        ),
        items: <DropdownMenuItem<String?>>[
          DropdownMenuItem<String?>(value: null, child: Text(anyLabel)),
          for (final option in options)
            DropdownMenuItem<String?>(value: option, child: Text(option)),
        ],
        onChanged: onChanged,
      );

  /// One optional bound, as a tappable field: the label says what the bound
  /// means, the subtitle says either the instant or that this paper has none,
  /// and the clear control appears only once there is something to clear.
  ///
  /// Not a `TextFormField`: a date is not typed, and a free-text parser is one
  /// more way to get a wrong instant into `timestamptz`.
  Widget _windowField({
    required Key fieldKey,
    required Key clearKey,
    required IconData icon,
    required String label,
    required DateTime? value,
    required bool isStart,
  }) {
    final theme = Theme.of(context);

    return ListTile(
      key: fieldKey,
      onTap: () => _pickBound(isStart: isStart),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(
        value == null
            ? 'Not set — no bound on this paper'
            : Exam.formatStamp(value),
        style: theme.textTheme.bodySmall?.copyWith(
          color: value == null
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onSurface,
        ),
      ),
      trailing: value == null
          ? null
          : IconButton(
              key: clearKey,
              tooltip: 'Clear',
              onPressed: () => _clearBound(isStart: isStart),
              icon: const Icon(Icons.clear),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      key: const Key('new-exam-dialog'),
      title: const Text('New paper'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'A paper can be authored as a draft and published when its '
                'questions are ready.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('new-exam-title'),
                controller: _titleController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'GES301: Software Engineering Midterm',
                  prefixIcon: Icon(Icons.title),
                  border: OutlineInputBorder(),
                ),
                validator: _validateTitle,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('new-exam-duration'),
                controller: _durationController,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Duration (minutes)',
                  prefixIcon: Icon(Icons.timer_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: _validateDuration,
              ),
              const SizedBox(height: 16),
              Text(
                'Who sits it is optional too. Leave these blank and the paper '
                'is offered to every student it was offered to before; choose a '
                'cohort to aim it, and add any borrowed student to the paper '
                'itself.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              _labelField(
                fieldKey: const Key('new-exam-faculty'),
                label: 'Faculty',
                icon: Icons.account_balance_outlined,
                anyLabel: 'Any faculty',
                options: AcademicCatalog.facultyNames,
                value: _faculty,
                onChanged: _selectFaculty,
              ),
              const SizedBox(height: 8),
              _labelField(
                fieldKey: const Key('new-exam-department'),
                label: 'Department',
                icon: Icons.menu_book_outlined,
                anyLabel: 'Any department',
                options: _departmentOptions,
                value: _department,
                onChanged: (value) => setState(() => _department = value),
              ),
              const SizedBox(height: 8),
              _labelField(
                fieldKey: const Key('new-exam-level'),
                label: 'Level',
                icon: Icons.groups_outlined,
                anyLabel: 'Any level',
                options: AcademicCatalog.levels,
                value: _level,
                onChanged: (value) => setState(() => _level = value),
              ),
              const SizedBox(height: 16),
              Text(
                'Scheduling is optional. Leave both blank for a paper students '
                'can take any time; set a closing time to give the sitting a '
                'hard end.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              _windowField(
                fieldKey: const Key('new-exam-starts-at'),
                clearKey: const Key('new-exam-starts-clear'),
                icon: Icons.event_available_outlined,
                label: 'Opens',
                value: _startsAt,
                isStart: true,
              ),
              const SizedBox(height: 8),
              _windowField(
                fieldKey: const Key('new-exam-ends-at'),
                clearKey: const Key('new-exam-ends-clear'),
                icon: Icons.event_busy_outlined,
                label: 'Closes',
                value: _endsAt,
                isStart: false,
              ),
              if (_windowError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _windowError!,
                  key: const Key('new-exam-window-error'),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('new-exam-publish'),
                contentPadding: EdgeInsets.zero,
                value: _published,
                onChanged: (value) => setState(() => _published = value),
                title: const Text('Publish now'),
                subtitle: const Text(
                  'Off keeps it a draft: students cannot see or start it.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('new-exam-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('new-exam-create'),
          onPressed: _submit,
          child: const Text('Create paper'),
        ),
      ],
    );
  }
}

/// One paper in the console's list: what it is, how it stands, and the four
/// things a lecturer does with it — author its questions, mark what came back,
/// publish or withdraw it, delete it.
class _ExamCard extends StatelessWidget {
  const _ExamCard({
    required this.exam,
    required this.busy,
    required this.enabled,
    required this.onAuthorQuestions,
    required this.onGrade,
    required this.onTogglePublished,
    required this.onDelete,
  });

  final AuthoredExam exam;
  final bool busy;

  /// False while another row's action is in flight: a second write must not be
  /// able to start from a list whose counts are about to change under it.
  final bool enabled;

  final VoidCallback onAuthorQuestions;
  final VoidCallback onGrade;
  final VoidCallback onTogglePublished;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = exam.exam.id;
    final published = exam.exam.isPublished;

    return Card(
      key: Key('exam-$id'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    exam.exam.title,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(left: 8, top: 2),
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Chip(
                    key: Key('exam-status-$id'),
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(
                      published ? Icons.public : Icons.edit_note,
                      size: 16,
                    ),
                    label: Text(exam.statusLabel),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              exam.countsLabel,
              key: Key('exam-counts-$id'),
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              '${exam.exam.durationMinutes} minutes',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // Only when the paper is actually scheduled: "Anytime" on every
            // unscheduled paper would be noise on a list where that is the norm.
            if (exam.exam.isScheduled)
              Text(
                exam.exam.scheduleLabel,
                key: Key('exam-window-$id'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            // The same rule for the cohort: only a targeted paper names one,
            // because naming "everybody" on a list where that is the norm would
            // read as a restriction that is not there.
            if (exam.exam.targetLabel != null)
              Text(
                exam.exam.targetLabel!,
                key: Key('exam-target-$id'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  key: Key('exam-questions-$id'),
                  onPressed: enabled ? onAuthorQuestions : null,
                  icon: const Icon(Icons.list_alt_outlined, size: 18),
                  label: const Text('Questions'),
                ),
                FilledButton.tonalIcon(
                  key: Key('exam-grading-$id'),
                  onPressed: enabled ? onGrade : null,
                  icon: const Icon(Icons.grading_outlined, size: 18),
                  label: Text('Marks (${exam.attemptCount})'),
                ),
                TextButton.icon(
                  key: Key('exam-publish-$id'),
                  onPressed: enabled ? onTogglePublished : null,
                  icon: Icon(
                    published ? Icons.unpublished_outlined : Icons.publish,
                    size: 18,
                  ),
                  label: Text(published ? 'Unpublish' : 'Publish'),
                ),
                IconButton(
                  key: Key('exam-delete-$id'),
                  tooltip: 'Delete paper',
                  onPressed: enabled ? onDelete : null,
                  color: theme.colorScheme.error,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The list could not be read: the repository's own sentence, with a retry.
class _ConsoleError extends StatelessWidget {
  const _ConsoleError({required this.message, required this.onRetry});

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
              key: const Key('lecturer-console-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('lecturer-console-retry'),
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

/// No papers yet — the normal first state of this console, so it reads as an
/// invitation rather than as an error.
class _NoPapers extends StatelessWidget {
  const _NoPapers();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        Icon(
          Icons.drive_file_rename_outline,
          size: 40,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text(
          'You have not created a paper yet.',
          key: const Key('lecturer-no-papers'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Tap “New paper” to start one, then add its questions.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
