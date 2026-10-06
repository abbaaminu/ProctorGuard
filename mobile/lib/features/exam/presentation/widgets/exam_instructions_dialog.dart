import 'package:flutter/material.dart';

import '../../domain/entities/exam.dart';

/// Opens the pre-exam instructions: how the proctor behaves, and what the paper
/// itself asks for.
///
/// Reachable from the two places a student stands *before* a session — the
/// portal's app bar (before choosing a paper) and the device-check gate (after
/// choosing one, before "Start Exam") — because the rules it explains become live
/// the moment the attempt row exists, and a rule a student first meets as a
/// strike is a rule they were never told.
///
/// A dialog rather than a page on purpose: it dismisses without losing the gate's
/// checklist or the portal's list, and nothing in it is a decision to make.
Future<void> showExamInstructions(BuildContext context, {Exam? exam}) {
  return showDialog<void>(
    context: context,
    builder: (_) => ExamInstructionsDialog(exam: exam),
  );
}

/// The two things a student is entitled to know before an attempt starts, in one
/// dialog with two tabs:
///
///  * **How the proctor works** — the camera, the microphone and its noise
///    floor, and the browser/kiosk rules that decide when a session counts as
///    interrupted;
///  * **Exam rules** — the clock, the deadline a scheduled paper adds, when a
///    mark appears (immediately for a paper with no written answers, after
///    marking for one with them), and what happens to a closed attempt.
///
/// The wording is deliberately the wording the live screens use — the audio
/// indicator's "Mic unavailable", the kiosk badge, the result dialog's "marked by
/// your lecturer" — so a student who read this recognises the state when it
/// appears.
class ExamInstructionsDialog extends StatelessWidget {
  const ExamInstructionsDialog({super.key, this.exam});

  /// The paper being started, when there is one — its title heads the dialog so
  /// the instructions are never ambiguous about which sitting they describe.
  final Exam? exam;

  @override
  Widget build(BuildContext context) {
    final title = exam?.title;

    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        key: const Key('exam-instructions-dialog'),
        title: Text(
          title == null ? 'Before you start' : 'Before you start: $title',
        ),
        content: SizedBox(
          width: 460,
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TabBar(
                tabs: [
                  Tab(
                    key: Key('instructions-tab-proctor'),
                    text: 'How the proctor works',
                  ),
                  Tab(
                    key: Key('instructions-tab-exam'),
                    text: 'Exam rules',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TabBarView(
                  children: [
                    _RuleList(
                      key: const Key('instructions-proctor'),
                      rules: _proctorRules,
                    ),
                    _RuleList(
                      key: const Key('instructions-exam'),
                      rules: _examRules,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const Key('exam-instructions-done'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

/// One tab's worth of rules, as icon + heading + sentence.
class _RuleList extends StatelessWidget {
  const _RuleList({super.key, required this.rules});

  final List<_Rule> rules;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: rules.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (context, index) => rules[index],
    );
  }
}

/// A single rule. A widget rather than a string list so the icon's tint follows
/// the theme, the same way the gate's checklist does.
class _Rule extends StatelessWidget {
  const _Rule({
    required this.icon,
    required this.heading,
    required this.body,
  });

  final IconData icon;
  final String heading;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(heading, style: theme.textTheme.labelLarge),
              const SizedBox(height: 2),
              Text(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The proctor tab. Every sentence describes something the session screen
/// actually does — camera frames and snapshots, the audio noise floor, the kiosk
/// pin, the browser guards — so nothing here is a threat the app cannot back up.
const List<_Rule> _proctorRules = <_Rule>[
  _Rule(
    icon: Icons.videocam_outlined,
    heading: 'Your camera stays on',
    body: 'It runs for the whole sitting and your face has to be visible. Frames '
        'are checked on your own device for a missing or second face, and a '
        'snapshot is kept with any incident. Everything recorded is reviewed by a '
        'person, not judged by the app alone.',
  ),
  _Rule(
    icon: Icons.mic_none_outlined,
    heading: 'Your microphone stays on',
    body: 'The session listens for noise above the room\'s own level, so a cough, '
        'a chair or a single word does not count against you — but sustained '
        'talking, a second voice or steady background sound does, even a quiet '
        'one at normal volume. Sustained noise is recorded as "Background noise", '
        'and the '
        'indicator on the exam screen shows the level as it moves. If the '
        'microphone is refused or unplugged the screen says so — it is never '
        'quietly treated as fine.',
  ),
  _Rule(
    icon: Icons.phonelink_lock_outlined,
    heading: 'Stay in the exam',
    body: 'On a phone the screen is pinned, so leaving the app — a call, another '
        'app, the home button — is recorded as leaving the exam. In a browser the '
        'tab must stay focused and full screen: switching tabs or windows, '
        'right-click, copy/paste and back/reload are blocked, and switching away '
        'is recorded the same way.',
  ),
  _Rule(
    icon: Icons.report_gmailerrorred_outlined,
    heading: 'Three confirmed strikes close the attempt',
    body: 'Incidents are counted as they happen and your supervisor sees them '
        'live. Three confirmed strikes close the attempt as disqualified, and a '
        'disqualified attempt is not marked. A disqualification aimed at the '
        'wrong candidate can be undone — the paper\'s author or a supervisor can '
        'reset the attempt, which clears it and its recording so it can be sat '
        'again.',
  ),
];

/// The exam-rules tab.
const List<_Rule> _examRules = <_Rule>[
  _Rule(
    icon: Icons.timer_outlined,
    heading: 'The clock starts when you do',
    body: 'Your attempt runs for the paper\'s own duration from the moment it '
        'starts. A paper with a scheduled window also closes at its end time — '
        'whichever comes first — so starting late does not extend the sitting. '
        'Answers are saved as you go, including offline, which replays when the '
        'connection returns; an unanswered question simply scores nothing.',
  ),
  _Rule(
    icon: Icons.emoji_events_outlined,
    heading: 'When you see your mark',
    body: 'A paper with no written answers is marked the instant you submit, and '
        'the score is shown to you there and then. A paper with written (essay) '
        'questions is only partly marked at that point: your lecturer reads and '
        'marks those answers afterwards, and the final score appears in this '
        'portal once they are done.',
  ),
  _Rule(
    icon: Icons.lock_outline,
    heading: 'One attempt per paper',
    body: 'A submitted or disqualified attempt is closed for good and cannot be '
        'reopened. If it has to be retaken — a wrong answer key, a '
        'disqualification that was a mistake, a power cut — your supervisor or '
        'the paper\'s author resets it, which clears the old attempt so you can '
        'start fresh.',
  ),
  _Rule(
    icon: Icons.settings_applications_outlined,
    heading: 'Before you start',
    body: 'The device check has to pass: a working camera and a working '
        'microphone. In a browser, on-device face detection is not available, so '
        'the camera still records and your attempt is still reviewed — faces are '
        'flagged by a person afterwards rather than as they happen.',
  ),
  _Rule(
    icon: Icons.support_agent_outlined,
    heading: 'If something goes wrong',
    body: 'Do not leave the screen: a dropped connection keeps your answers and '
        'sends them when it returns. Say something to the invigilator rather than '
        'fixing it yourself — an interruption your supervisor knows about is '
        'explained, and one they do not is an incident.',
  ),
];

