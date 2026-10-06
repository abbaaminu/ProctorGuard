import 'package:equatable/equatable.dart';

import 'submission.dart';

/// What the student is shown the moment an attempt closes.
///
/// Two halves, deliberately:
///
///  * what the **server** answered. `submit_exam()` returns
///    `(result_status, final_score)`, and `final_score` is the sum of
///    `questions.points` over the answers it could grade — so the client never
///    computes a mark of its own (a patched client cannot grade itself) and the
///    number shown here is the same one the roster and the analytics read.
///  * what only the **session screen** knows: the paper's own totals, filled in
///    by [withPaper]. An attempt containing an essay is only ever *partly*
///    graded when it is handed in — the written answers are marked afterwards by
///    the paper's owner, through `grade_submission()` — and that is exactly what
///    [awaitingMarking] exists to say instead of showing a score that is still
///    going to move.
///
/// The defaults are the cautious ones: a result nobody has told about the paper
/// claims nothing final, so "is there a mark to show?" is answered *no* until
/// [withPaper] says otherwise.
class ExamSubmitResult extends Equatable {
  const ExamSubmitResult({
    required this.status,
    this.score,
    this.maxScore = 0,
    this.awaitingMarking = true,
  });

  /// Reads the single row `submit_exam()` answers with
  /// (`result_status`, `final_score`).
  ///
  /// A missing or unrecognised answer is read as "submitted, unmarked" rather
  /// than thrown: the attempt is *already closed* by the time the client sees
  /// it, so an exception here would turn a finished exam into an error screen.
  factory ExamSubmitResult.fromRpc(Object? response) {
    final row = switch (response) {
      final List list when list.isNotEmpty => list.first,
      final Map map => map,
      _ => null,
    };
    if (row is! Map) {
      return const ExamSubmitResult(status: SubmissionStatus.submitted);
    }

    return ExamSubmitResult(
      status: _statusFrom(row['result_status']),
      score: row['final_score'] is num ? row['final_score'] as num : null,
    );
  }

  /// `exam_submissions.status` after the attempt closed.
  final SubmissionStatus status;

  /// `final_score` as the server computed it — null for an attempt that was
  /// never graded (a disqualification).
  final num? score;

  /// Every point on the paper, for "You scored 7 of 10".
  final num maxScore;

  /// True while a written (essay) answer is still waiting for its lecturer.
  final bool awaitingMarking;

  /// The two facts about the paper only the session screen holds — the questions
  /// it was showing, and therefore whether one of them was an essay.
  ExamSubmitResult withPaper({
    required bool awaitingMarking,
    required num maxScore,
  }) =>
      ExamSubmitResult(
        status: status,
        score: score,
        maxScore: maxScore,
        awaitingMarking: awaitingMarking,
      );

  bool get isDisqualified => status == SubmissionStatus.disqualified;

  /// True when the mark on screen is the final one: the attempt is submitted and
  /// nothing on it is still to be marked by hand. This is the whole point of the
  /// instant result — an objective paper is finished the moment the server
  /// answers, and a paper with an essay on it is not.
  bool get hasFinalScore => status == SubmissionStatus.submitted && !awaitingMarking;

  /// "7 of 10" — [score] rendered without a trailing `.0`, since a whole-number
  /// mark is the common case and "7.0 of 10" reads like a bug.
  String get scoreLabel {
    final earned = _formatNumber(score ?? 0);
    return '$earned of ${_formatNumber(maxScore)}';
  }

  static String _formatNumber(num value) =>
      value == value.roundToDouble() ? value.round().toString() : '$value';

  /// `submit_exam()` writes exactly `ongoing` / `submitted` / `disqualified`;
  /// anything else (a column added later, a truncated body) must not take the
  /// screen down, and "submitted" is the reading that claims the least.
  static SubmissionStatus _statusFrom(Object? value) => switch (value) {
        'submitted' => SubmissionStatus.submitted,
        'disqualified' => SubmissionStatus.disqualified,
        'ongoing' => SubmissionStatus.ongoing,
        _ => SubmissionStatus.submitted,
      };

  /// Value equality: two results with the same four facts are the same result,
  /// which is what lets a test assert one against a literal.
  @override
  List<Object?> get props => [status, score, maxScore, awaitingMarking];

  @override
  String toString() =>
      'ExamSubmitResult(${status.dbValue}, score: $score, '
      'maxScore: $maxScore, awaitingMarking: $awaitingMarking)';
}
