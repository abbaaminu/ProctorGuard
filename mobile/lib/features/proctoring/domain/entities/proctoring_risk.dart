import 'violation.dart';

/// How seriously one attempt's evidence reads, as a band rather than a number.
///
/// Four bands and not a bare score, because the number is only useful to the
/// person who computed it: a supervisor scanning a live grid needs to answer
/// "who needs me first", and `61` does not answer that.
enum RiskBand {
  low('Low'),
  moderate('Moderate'),
  high('High'),
  critical('Critical');

  const RiskBand(this.label);

  /// Word shown in the grid ("Low", "Critical", …).
  final String label;
}

/// The proctoring risk index for one attempt: a 0-100 score recomputed from
/// every violation logged so far in that session.
///
/// "Adaptive" here is a statement about what the score is a function of, not
/// about a fitted model: it is derived from the running list of signals for
/// *this* attempt ([ProctoringRisk.fromViolations]), so it moves as evidence
/// accumulates and - the part that matters - it moves differently as the *kinds*
/// of evidence change. Three glances off screen do not score like three
/// different integrity failures, and one second face in frame outranks a long
/// string of the same camera complaint. Nothing is baselined across students, and
/// there is deliberately no time decay: every signal in the list already had to
/// clear its own detector threshold and its per-type cooldown to be logged at all
/// (`register_violation` server-side, the debounce window in `ProctoringNotifier`
/// client-side), so decaying the score with time would only hide evidence the
/// detector was already conservative about.
///
/// The formula, documented rather than tuned in place:
///
///     score = min(100, 20 * strikes + 10 * extraSignals + 15 * severeCount)
///
/// where `extraSignals` is `max(0, distinctTypes - 1)`.
///
///  * [strikes] - one per logged violation: persistence matters, so repeating a
///    signal still moves the score.
///  * [distinctTypes] - how many *different* signals fired, and the term is
///    `10 * (distinctTypes - 1)` so that one signal is the baseline rather than a
///    discount. A session where the camera, the microphone and the lifecycle
///    observer all disagree is worse than one repeating the same complaint, which
///    is what the `+10` per extra type prices in.
///  * [severeCount] - how many of [severeSignals] fired: the ones that by
///    themselves mean "somebody else is in this exam".
///
/// Bands: 0-19 [RiskBand.low], 20-44 [RiskBand.moderate], 45-69 [RiskBand.high],
/// 70+ [RiskBand.critical]. So one logged violation reads as "Moderate", and the
/// third strike - the server's auto-disqualification threshold - always reads at
/// least "High", whatever the mix of signals that produced it.
class ProctoringRisk {
  const ProctoringRisk({
    required this.score,
    required this.strikes,
    required this.distinctTypes,
    required this.severeCount,
  });

  /// Nothing logged: the one state that is not evidence of anything.
  static const ProctoringRisk none = ProctoringRisk(
    score: 0,
    strikes: 0,
    distinctTypes: 0,
    severeCount: 0,
  );

  /// The signals that on their own mean the student is not alone at the
  /// keyboard: a second face in frame, a camera that is not the device's own lens,
  /// a second display the answers could be read from, or developer tools open
  /// over the exam.
  static const Set<ViolationType> severeSignals = <ViolationType>{
    ViolationType.multipleFaces,
    ViolationType.virtualCameraDetected,
    ViolationType.secondaryDisplayDetected,
    ViolationType.devtoolsDetected,
  };

  /// 0-100, higher is worse. See the class docs for the formula.
  final int score;

  /// How many violations were logged in this session - the client's evidence
  /// list, or the server's strike count when that is higher (see
  /// [ProctoringRisk.fromViolations]).
  final int strikes;

  /// How many *different* violation types were logged.
  final int distinctTypes;

  /// How many of the logged types are in [severeSignals].
  final int severeCount;

  /// The score for the whole session, recomputed from its full violation list.
  ///
  /// Takes the whole list on purpose (rather than an increment): the index is a
  /// function of the session, so it has to be derivable from the session's own
  /// evidence and not from a number that some earlier caller remembered to bump.
  ///
  /// [serverStrikes] is `register_violation`'s authoritative count. It only ever
  /// *raises* the strike term, because the evidence list can legitimately be
  /// shorter than the count: a resumed attempt (or a violation logged from
  /// another device) starts with an empty local list and a non-zero server count,
  /// and an index that read 0 there would be describing a different session.
  factory ProctoringRisk.fromViolations(
    Iterable<ViolationType> violations, {
    int serverStrikes = 0,
  }) {
    final logged = violations.toList(growable: false);
    final strikes = serverStrikes > logged.length ? serverStrikes : logged.length;
    if (strikes == 0) return none;

    final types = logged.toSet();
    final severe = types.where(severeSignals.contains).length;
    // `types.length - 1` counts *extra* signals beyond the first, but it must not
    // go negative: when the count comes from the server alone (a resumed attempt
    // whose local evidence list is gone) there is no local mix to discount, and a
    // negative term would make more evidence score lower than less.
    final extraSignals = types.isEmpty ? 0 : types.length - 1;
    final score = (20 * strikes + 10 * extraSignals + 15 * severe).clamp(0, 100);

    return ProctoringRisk(
      score: score,
      strikes: strikes,
      distinctTypes: types.length,
      severeCount: severe,
    );
  }

  RiskBand get band => switch (score) {
        < 20 => RiskBand.low,
        < 45 => RiskBand.moderate,
        < 70 => RiskBand.high,
        _ => RiskBand.critical,
      };

  /// The band's word - "Moderate", "Critical".
  String get label => band.label;

  /// What the score was made of, for a tooltip: the supervisor can see *why* a
  /// row is high without opening the incident feed.
  String get explanation {
    final violationWord = strikes == 1 ? 'violation' : 'violations';
    final signalWord = distinctTypes == 1 ? 'signal' : 'signals';
    return '$strikes $violationWord across $distinctTypes $signalWord'
        '${severeCount > 0 ? ', $severeCount of them serious' : ''}';
  }
}
