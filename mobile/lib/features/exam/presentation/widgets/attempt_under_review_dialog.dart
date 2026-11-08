import 'package:flutter/material.dart';

/// What the student is told when the attempt they tried to open is closed and
/// waiting on a person: `exam_submissions.status = 'flagged_for_review'`.
///
/// The wording is deliberately about **being locked out of this one exam**, not
/// about being punished: nothing has been decided, the answers are saved, and the
/// only thing that changes the state is a member of staff unlocking it. It names
/// all three tiers the server accepts (`is_exam_supervisor()` = admin or
/// supervisor, and `owns_exam()` = the lecturer who wrote the paper), because a
/// student who is told "ask your supervisor" in a department with no supervisor on
/// duty has been told nothing actionable.
const String attemptUnderReviewTitle = 'Attempt under review';

const String attemptUnderReviewBody =
    'This exam attempt is closed while a member of staff reviews it. Your answers '
    'are saved, and nothing has been decided.';

/// Who can unlock it - the same three the server accepts.
const String attemptUnderReviewWhoCanUnlock =
    'A supervisor, the lecturer who set this exam, or an administrator has to '
    'unlock it before you can sit this exam again.';

/// What the lock does *not* cover. Worth saying: the lock is per attempt, so the
/// account stays signed in and the student's other papers are unaffected.
const String attemptUnderReviewOtherExams =
    'Your other exams are not affected, and you do not need to sign out.';

const String attemptUnderReviewAction = 'Back to my exams';

/// The screen a student gets instead of a paper when the attempt they tried to
/// open is under review.
///
/// A dialog rather than a route, because the caller is the exam list and the only
/// thing to do is go back to it: [showAttemptUnderReviewDialog] leaves the student
/// exactly where they were, signed in, with the rest of their exams still tappable.
/// The *other* place this state is met is the exam screen itself, when the third
/// counted strike lands mid-attempt - that is `ViolationOverlay` with
/// `underReview: true`, whose Exit button pops back to the same list.
///
/// Deliberately **not** a sign-out. The lock is per exam attempt
/// (`exam_submissions.status` on one row), so signing the account out of the whole
/// app would take away exams the student is still entitled to sit - and it would
/// look like a punishment, which this state is not.
Future<void> showAttemptUnderReviewDialog(
  BuildContext context, {
  required String examTitle,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('attempt-under-review-dialog'),
      icon: const Icon(Icons.lock_clock_outlined),
      title: const Text(attemptUnderReviewTitle),
      content: Text(
        '“$examTitle” cannot be opened.\n\n'
        '$attemptUnderReviewBody\n\n'
        '$attemptUnderReviewWhoCanUnlock\n\n'
        '$attemptUnderReviewOtherExams',
      ),
      actions: [
        TextButton(
          key: const Key('attempt-under-review-exit'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(attemptUnderReviewAction),
        ),
      ],
    ),
  );
}
