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
  /// Throws [ProfileLookupException] when there is no row, the role is
  /// unrecognised, or the backend refuses — the gate renders that as a
  /// retryable error instead of guessing a role.
  Future<UserProfile> getProfile(String userId);
}
