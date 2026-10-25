import 'package:flutter/material.dart';

import '../../../../core/services/kiosk_service.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../domain/entities/question.dart';

/// Bars and tiles that make up the exam-session chrome.
///
/// These used to be private classes at the bottom of `exam_taking_page.dart`;
/// they are extracted here so the page file is about *orchestration* (the
/// camera, the kiosk, the guards and the controller) rather than about layout.
/// Every widget is self-contained and takes only the values it renders.

/// Countdown chip in the exam app bar: neutral, amber inside the last five
/// minutes and red in the last one, so the clock is visible without stealing
/// attention from the question.
class ExamRemainingChip extends StatelessWidget {
  const ExamRemainingChip({super.key, required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final seconds = remaining.inSeconds;
    final scheme = Theme.of(context).colorScheme;
    final color = seconds <= 60
        ? Colors.redAccent
        : seconds <= 300
            ? Colors.amber
            : scheme.onSurface;

    return Tooltip(
      message: 'Time remaining',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              _format(seconds),
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  /// `m:ss` with the negative case clamped to zero (the auto-submit that
  /// follows the zero tick is asynchronous, so a tick can render at -1s).
  static String _format(int seconds) {
    final clamped = seconds < 0 ? 0 : seconds;
    return '${clamped ~/ 60}:${(clamped % 60).toString().padLeft(2, '0')}';
  }
}

/// "3 of 5 answered" chip in the exam chrome.
class ExamAnsweredChip extends StatelessWidget {
  const ExamAnsweredChip({
    super.key,
    required this.count,
    required this.total,
  });

  final int count;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Answers stored for this attempt',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '$count of $total answered',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
    );
  }
}

/// Lock state of the exam surface, so a student and a roaming supervisor can
/// both see whether pinning is enforced (device owner) or best-effort (screen
/// pinning, which can still be escaped).
class ExamKioskBadge extends StatelessWidget {
  const ExamKioskBadge({super.key, required this.status});

  final KioskResult status;

  @override
  Widget build(BuildContext context) {
    final locked = status.granted;
    final strict = status.strict;
    final (IconData icon, Color color, String label) = switch ((
      locked,
      strict,
    )) {
      (true, true) => (Icons.lock, Colors.green, 'Kiosk'),
      (true, false) => (Icons.lock_outline, Colors.amber, 'Pinned'),
      _ => (Icons.lock_open_outlined, Colors.redAccent, 'Unpinned'),
    };

    return Tooltip(
      message: status.message ?? 'Kiosk mode unavailable',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

/// "1 of 3 warnings" chip in the exam chrome.
///
/// The full-screen warning is dismissible by design — the student has to get back
/// to the paper — so without this chip a logged strike left no trace on the screen
/// they were looking at. On a phone that meant a candidate could be one warning
/// away from disqualification with nothing on screen saying so, and a roaming
/// supervisor looking over a shoulder saw a paper that looked untouched.
///
/// Rendered only once the server has confirmed a warning (`count > 0`), so an
/// untouched attempt's header is unchanged.
class ExamWarningChip extends StatelessWidget {
  const ExamWarningChip({super.key, required this.count, this.total = 3});

  /// Confirmed warnings on this attempt, counted the way the overlay and the
  /// supervisor's grid count them (1-based: the first strike is "1 of 3").
  final int count;

  /// The count that closes the attempt — `register_violation` in `schema.sql`
  /// disqualifies on the third.
  final int total;

  @override
  Widget build(BuildContext context) {
    // The last warning before disqualification is the one that has to look
    // different: it is the only one a student can still act on.
    final lastOne = count >= total - 1;
    final color = lastOne ? Colors.redAccent : Colors.amber.shade800;

    return Tooltip(
      message: 'Every failed proctoring check is a warning. '
          'The attempt closes at $total.',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: color),
            const SizedBox(width: 4),
            Text(
              '$count of $total warnings',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: lastOne ? FontWeight.w700 : null,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown in place of the self-view when a **real** session has no live camera.
///
/// Deliberately *not* a neutral camera placeholder: the blocking error above
/// already explains what went wrong, and this tile says plainly that the feed is
/// gone — an unproctored exam must never look like a normal one.
class ExamCameraOfflineNotice extends StatelessWidget {
  const ExamCameraOfflineNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.videocam_off, color: Colors.redAccent, size: 26),
        const SizedBox(height: 6),
        Text(
          'CAMERA\nOFFLINE',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.redAccent,
                height: 1.2,
              ),
        ),
      ],
    );
  }
}

/// Sits where the camera self-view would be on the only path with no real
/// hardware: `flutter run --dart-define=MOCK_CAMERA=true`. It is unreachable
/// without that compile-time flag (a failed real camera blocks the session
/// instead, see [ExamCameraOfflineNotice]), and loud on purpose — a tester
/// should never mistake simulated violations for real detection.
class ExamMockCameraTile extends StatelessWidget {
  const ExamMockCameraTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black87,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.videocam_off_outlined,
            color: Colors.amber,
            size: 26,
          ),
          const SizedBox(height: 6),
          Text(
            'MOCK\nCAMERA',
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: Colors.amber, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// Full-screen blocking state for the exam session (permission refused, no
/// camera, questions unreachable, clock expired). It always offers a way out:
/// the exam chrome deliberately has no back button, so without one of these a
/// failure would strand the student with no escape.
class ExamBlockingState extends StatelessWidget {
  const ExamBlockingState({
    super.key,
    required this.message,
    this.title = 'Cannot start this exam',
    this.icon = Icons.error_outline,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.onOpenSettings,
    this.allowExit = false,
  });

  final String title;
  final String message;
  final IconData icon;

  /// Retry action, or null when retrying cannot help (e.g. an exam with no
  /// questions — only a supervisor can fix that).
  final VoidCallback? onRetry;
  final String retryLabel;

  /// Opens the OS app-settings page, for a permission the student has to change
  /// there (Android/iOS stop prompting after a permanent denial).
  final VoidCallback? onOpenSettings;

  /// Shows the "Leave" button.
  final bool allowExit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retry = onRetry;
    final openSettings = onOpenSettings;

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false, title: Text(title)),
      // Scrollable and width-capped: a phone in landscape, a resized desktop
      // window or a large accessibility text scale can still reach every button.
      // This screen is the only way out of a blocked session, so it must never
      // clip its own actions.
      body: SafeArea(
        child: ResponsiveScrollView(
          maxWidth: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (retry != null)
                FilledButton.icon(
                  key: const Key('exam-retry'),
                  onPressed: retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(retryLabel),
                ),
              if (openSettings != null) ...[
                if (retry != null) const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('exam-open-settings'),
                  onPressed: openSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open settings'),
                ),
              ],
              if (allowExit) ...[
                if (retry != null || openSettings != null)
                  const SizedBox(height: 8),
                TextButton(
                  key: const Key('exam-leave'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Leave'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The question review grid: one tile per question, tappable to jump to it.
///
/// The two states a student checks before submitting have to be readable at a
/// glance:
///
///  * **answered** - this question has an answer that will be graded (a filled,
///    check-marked tile);
///  * **not answered** - nothing has been stored for it yet (a neutral outlined
///    tile).
///
/// A third state rides on top of both: **marked for review** ([markedIds]) tints
/// the tile with the tertiary pair and pins a small flag in its corner, so "I
/// have to come back to this one" is visible in the same scan while the check
/// still means answered.
///
/// The question currently on screen is ringed, so the same grid doubles as a
/// "where am I in this paper" indicator, and the counts above it are the summary
/// the student is really looking for: how much is left.
///
/// Deliberately a `Wrap` and not a `GridView`: the pane it lives in is already
/// scrollable, and a fixed-height scroller inside a scroller is a class of bug
/// this screen does not need.
class ExamQuestionPalette extends StatelessWidget {
  const ExamQuestionPalette({
    super.key,
    required this.questions,
    required this.currentIndex,
    required this.answeredIds,
    this.markedIds = const <String>{},
    this.onSelect,
  });

  /// The paper, in order: the tile numbers are the question numbers.
  final List<Question> questions;

  /// The question being shown, ringed in the grid.
  final int currentIndex;

  /// Question ids whose answer is stored - the same set the counted chip and the
  /// submit summary read.
  final Set<String> answeredIds;

  /// Question ids the student flagged for another look.
  ///
  /// A third state next to answered/not answered: an empty set renders exactly
  /// the two-state grid this widget had before "Mark for review" existed, so a
  /// caller that does not track marks (or an attempt that has none) is unchanged.
  final Set<String> markedIds;

  /// Called with the index of the tapped question. Null disables the grid: a
  /// submit in flight must not let the paper change under it.
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final answeredCount =
        questions.where((question) => answeredIds.contains(question.id)).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Questions', style: theme.textTheme.labelLarge),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$answeredCount answered • '
                '${questions.length - answeredCount} not answered',
                key: const Key('exam-palette-summary'),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var index = 0; index < questions.length; index++)
              _PaletteTile(
                index: index,
                answered: answeredIds.contains(questions[index].id),
                marked: markedIds.contains(questions[index].id),
                current: index == currentIndex,
                onTap: onSelect == null ? null : () => onSelect!(index),
              ),
          ],
        ),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _PaletteLegend(answered: true),
            _PaletteLegend(answered: false),
            _PaletteLegend(marked: true),
          ],
        ),
      ],
    );
  }
}

/// Text input for a fill-in-the-blank question.
///
/// Stateful and keyed by question id (the parent passes `ValueKey(question.id)`),
/// so moving between questions creates a fresh controller holding *that*
/// question's saved text instead of leaking the previous answer into the next
/// field. Both typed answers share one implementation — see [_AnswerBox].
class ExamFillInTheBlankField extends StatelessWidget {
  const ExamFillInTheBlankField({
    super.key,
    required this.initialValue,
    required this.saved,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String initialValue;
  final bool saved;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => _AnswerBox(
        fieldKey: const Key('exam-text-answer'),
        label: 'Type your answer',
        hintText: 'Your answer',
        initialValue: initialValue,
        saved: saved,
        enabled: enabled,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      );
}

/// Text input for an essay.
///
/// The same durable path as [ExamFillInTheBlankField] — keystrokes go to the
/// local cache, "Save & next" writes through `merge_submission_text_answer`, and
/// the same 2000-character cap applies — with a taller box and a label that makes
/// no claim about one accepted wording: this answer is marked by a person after
/// the attempt is handed in.
class ExamEssayField extends StatelessWidget {
  const ExamEssayField({
    super.key,
    required this.initialValue,
    required this.saved,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String initialValue;
  final bool saved;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) => _AnswerBox(
        fieldKey: const Key('exam-essay-answer'),
        label: 'Write your answer',
        hintText: 'Write as much as the question needs.',
        helperText: 'Marked after you hand in — nothing is scored as you type.',
        minLines: 5,
        maxLines: 12,
        initialValue: initialValue,
        saved: saved,
        enabled: enabled,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
      );
}

/// The shared body of the two typed answers: a text box, the character cap that
/// matches `merge_submission_text_answer()`, and the line that tells a student
/// whether what they typed is stored yet.
class _AnswerBox extends StatefulWidget {
  const _AnswerBox({
    required this.fieldKey,
    required this.label,
    required this.hintText,
    required this.initialValue,
    required this.saved,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
    this.minLines = 1,
    this.maxLines = 4,
    this.helperText,
  });

  final Key fieldKey;
  final String label;
  final String hintText;
  final String? helperText;
  final int minLines;
  final int maxLines;
  final String initialValue;
  final bool saved;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_AnswerBox> createState() => _AnswerBoxState();
}

class _AnswerBoxState extends State<_AnswerBox> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(
          key: widget.fieldKey,
          controller: _controller,
          enabled: widget.enabled,
          textInputAction: TextInputAction.done,
          minLines: widget.minLines,
          maxLines: widget.maxLines,
          // Matches the server-side cap in merge_submission_text_answer().
          maxLength: 2000,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: widget.hintText,
            helperText: widget.helperText,
            helperMaxLines: 2,
          ),
        ),
        _AnswerSaveStatus(
          saved: widget.saved,
          message: widget.saved
              ? 'Answer saved'
              : 'Not saved yet — tap "Save & next", or Submit on the last '
                  'question, to send it.',
        ),
      ],
    );
  }
}

/// True/false input: two tap targets, and the word the student chose.
///
/// The tap is written through the *text* answer path
/// (`merge_submission_text_answer`), because that is what the row's key is
/// compared against — the word 'true' or 'false', not an option index. The
/// student never types it, though, so this is a pair of cards rather than a field
/// with two valid spellings.
class ExamTrueFalseField extends StatelessWidget {
  const ExamTrueFalseField({
    super.key,
    required this.selectedValue,
    required this.saved,
    required this.enabled,
    required this.onSelected,
  });

  /// 'true' or 'false' once the student has answered, and null while nothing is
  /// stored under the question.
  final String? selectedValue;

  final bool saved;
  final bool enabled;
  final ValueChanged<bool> onSelected;

  bool? get _selected => switch (selectedValue?.trim().toLowerCase()) {
        'true' => true,
        'false' => false,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Choose one', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        for (final value in const <bool>[true, false])
          Card(
            color:
                selected == value ? theme.colorScheme.secondaryContainer : null,
            child: ListTile(
              key: Key('exam-answer-${value ? 'true' : 'false'}'),
              title: Text(value ? 'True' : 'False'),
              selected: selected == value,
              trailing: selected == value
                  ? const Icon(Icons.radio_button_checked)
                  : null,
              onTap: enabled ? () => onSelected(value) : null,
            ),
          ),
        const SizedBox(height: 4),
        _AnswerSaveStatus(
          saved: saved,
          message: saved
              ? 'Answer saved'
              : 'Not saved yet — tap an answer to send it.',
        ),
      ],
    );
  }
}

/// The "is what I chose stored yet?" line, shared by the two typed answers and
/// the true/false pair so the three cannot word it differently.
class _AnswerSaveStatus extends StatelessWidget {
  const _AnswerSaveStatus({required this.saved, required this.message});

  final bool saved;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(
          saved ? Icons.check_circle_outline : Icons.cloud_off_outlined,
          size: 14,
          color: saved ? Colors.green : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: saved ? Colors.green : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// One numbered tile: filled with a check when answered, corner-flagged when the
/// student marked it for review, neutral when it is neither.
class _PaletteTile extends StatelessWidget {
  const _PaletteTile({
    required this.index,
    required this.answered,
    required this.marked,
    required this.current,
    required this.onTap,
  });

  final int index;
  final bool answered;
  final bool marked;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final number = '${index + 1}';

    // The unanswered state is deliberately the quieter of the two: "done" is what
    // should read first when a student scans the grid for what is left. A marked
    // tile takes the tertiary pair instead, so "flagged by me" can never read as
    // "answered" - the flag is the reminder, the check stays the answer marker,
    // and a tile can carry both.
    final Color background;
    final Color foreground;
    if (marked) {
      background = scheme.tertiaryContainer;
      foreground = scheme.onTertiaryContainer;
    } else if (answered) {
      background = scheme.primaryContainer;
      foreground = scheme.onPrimaryContainer;
    } else {
      background = scheme.surfaceContainerHighest;
      foreground = scheme.onSurfaceVariant;
    }
    final border = current
        ? scheme.primary
        : (marked
            ? scheme.tertiary
            : (answered ? scheme.primary : scheme.outlineVariant));

    final states = <String>[
      if (answered) 'answered',
      if (marked) 'marked for review',
    ];

    return Tooltip(
      message: states.isEmpty
          ? 'Question $number — not answered yet'
          : 'Question $number — ${states.join(', ')}',
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border, width: current ? 2 : 1),
        ),
        child: InkWell(
          key: Key('exam-palette-$index'),
          onTap: onTap,
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          child: SizedBox(
            width: 46,
            height: 40,
            child: Stack(
              children: [
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (answered) ...[
                        Icon(Icons.check, size: 12, color: foreground),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        number,
                        style: TextStyle(
                          color: foreground,
                          fontWeight:
                              current ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                // Pinned to the corner rather than put in the row with the
                // number: two glyphs plus a two-digit number do not fit a 46 dp
                // tile, and an overflowing tile is a red screen.
                if (marked)
                  Positioned(
                    top: 1,
                    right: 2,
                    child: Icon(Icons.flag, size: 10, color: foreground),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The key to [_PaletteTile]'s states, spelled out rather than assumed.
class _PaletteLegend extends StatelessWidget {
  const _PaletteLegend({this.answered = false, this.marked = false})
      : assert(
          !(answered && marked),
          'the marked key is its own state, not the answered one',
        );

  final bool answered;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final IconData icon;
    final String label;
    final Color color;
    if (marked) {
      icon = Icons.flag;
      label = 'Marked for review';
      color = scheme.tertiary;
    } else if (answered) {
      icon = Icons.check_circle;
      label = 'Answered';
      color = scheme.primary;
    } else {
      icon = Icons.radio_button_unchecked;
      label = 'Not answered';
      color = scheme.onSurfaceVariant;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color)),
      ],
    );
  }
}

/// Who is sitting this exam, and which exam it is, printed on the exam surface.
///
/// The app bar and the palette both belong to the *question* — "4 of 20", the
/// clock, what is answered — and neither has room left on a 360 dp phone for the
/// candidate's own identity. This strip carries it instead, above the question.
///
/// Only [candidateName] is required. [examTitle] and [candidateEmail] are rendered
/// only when supplied, so a caller without them gets a one-line strip rather than
/// a row of blanks. There is deliberately no avatar upload here: `profiles` has
/// no photo column, so the initials tile is the whole of what the data supports.
class ExamCandidateHeader extends StatelessWidget {
  const ExamCandidateHeader({
    super.key,
    required this.candidateName,
    this.examTitle,
    this.candidateEmail,
  });

  final String candidateName;
  final String? examTitle;

  /// Shown under the name because it *is* the identifier this deployment has -
  /// `profiles` carries no matric/registration number.
  final String? candidateEmail;

  /// Up to two initials for the tile: "Aisha Bello" -> "AB", a single name or an
  /// email local part -> its first letter.
  static String initialsOf(String name) {
    final words = name
        .split(RegExp(r'[\s@._-]+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first.characters.first.toUpperCase();
    return (words.first.characters.first + words.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      key: const Key('exam-candidate-header'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: scheme.primaryContainer,
            child: Text(
              initialsOf(candidateName),
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidateName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (examTitle != null && examTitle!.isNotEmpty)
                  Text(
                    examTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (candidateEmail != null && candidateEmail!.isNotEmpty)
                  Text(
                    candidateEmail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
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
