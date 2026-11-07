import '../entities/proctor_consent.dart';

/// The proctoring consent notice, as the database sees it.
///
/// Two questions and one write, kept behind an interface for the same reason
/// every other repository here is: the consent screen has to be testable without
/// a backend, and it is the one screen a student cannot get past.
abstract class ConsentRepository {
  /// True when a consent row already satisfies
  /// `public.student_has_consent()` for [examId] *as far as the client can
  /// tell* - the current wording, for this paper or generally.
  ///
  /// Used to skip the screen on a resume: an attempt that already exists can only
  /// have been created after a consent was recorded (`submissions_insert_own_
  /// ongoing` refuses otherwise), so asking again would be asking a student to
  /// re-accept something they cannot change. A false answer pulls the screen up,
  /// which is always safe - `record_consent()` is idempotent.
  Future<bool> hasCurrentConsent(String examId);

  /// `public.proctoring_consent_config.current_version`, or null when the
  /// project has no config row / cannot be read.
  ///
  /// The consent screen compares this against [ProctorConsentConfig.version] so a
  /// build that shipped older wording says "update the app" *before* the student
  /// ticks the box, rather than letting them accept text the server will not
  /// count.
  Future<String?> currentServerVersion();

  /// Records the acceptance and returns what the server stored.
  ///
  /// [version] is the wording this build displayed - always
  /// [ProctorConsentConfig.version]. [examId] null means a general acceptance
  /// covering every paper, which the policy accepts just as well.
  Future<ConsentRecord> recordConsent({
    String? examId,
    required String version,
  });
}
