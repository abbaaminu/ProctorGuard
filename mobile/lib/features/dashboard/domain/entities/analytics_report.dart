class ExamAnalytics {
  const ExamAnalytics({
    required this.examId,
    required this.title,
    required this.attempts,
    required this.ongoing,
    required this.completed,
    required this.disqualified,
    required this.incidents,
    required this.averageScore,
    required this.scoredAttempts,
  });

  final String examId;
  final String title;
  final int attempts;
  final int ongoing;
  final int completed;
  final int disqualified;
  final int incidents;
  final double? averageScore;
  final int scoredAttempts;

  int get closedAttempts => completed + disqualified;
  int get disqualificationRate =>
      closedAttempts == 0 ? 0 : (disqualified * 100 / closedAttempts).round();
}

class AnalyticsReport {
  const AnalyticsReport(this.exams);

  final List<ExamAnalytics> exams;

  int get attempts => exams.fold(0, (total, exam) => total + exam.attempts);
  int get completed => exams.fold(0, (total, exam) => total + exam.completed);
  int get disqualified =>
      exams.fold(0, (total, exam) => total + exam.disqualified);
  int get incidents => exams.fold(0, (total, exam) => total + exam.incidents);

  int get disqualificationRate {
    final closed = completed + disqualified;
    return closed == 0 ? 0 : (disqualified * 100 / closed).round();
  }

  double? get averageScore {
    final scored = exams.where((exam) => exam.averageScore != null).toList();
    final count = scored.fold(0, (total, exam) => total + exam.scoredAttempts);
    if (count == 0) return null;
    final total = scored.fold<double>(
      0,
      (sum, exam) => sum + exam.averageScore! * exam.scoredAttempts,
    );
    return total / count;
  }
}
