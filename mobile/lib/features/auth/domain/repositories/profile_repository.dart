import '../entities/user_profile.dart';

/// Raised when the profile lookup cannot produce a role.
///
/// [message] is written for the student, not for the log — the role gate shows
/// it verbatim in its error state.
class ProfileLookupException implements Exception {
  const ProfileLookupException(this.message);

  final String message;

  @override
  String toString() => 'ProfileLookupException: $message';
}

abstract class ProfileRepository {
  /// Reads `public.profiles` for [userId] (the **auth** user id).
  ///
  /// Throws [ProfileLookupException] when the role is unrecognised, or when there
  /// is still no row after the implementation's own short retry window — the gate
  /// renders that as a retryable error instead of guessing a role.
  ///
  /// A row that is merely *late* (the sign-in race: the session is emitted a
  /// moment before the database trigger's row becomes visible) is retried
  /// silently by the implementation, so the returned future simply stays pending
  /// — the caller's loading state covers the window. See
  /// `ProfileRepositoryImpl.getProfile` for the schedule.
  Future<UserProfile> getProfile(String userId);
}
