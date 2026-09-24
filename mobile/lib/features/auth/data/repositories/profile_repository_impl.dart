import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';

class ProfileRepositoryImpl implements ProfileRepository {
  ProfileRepositoryImpl(this._client);

  final SupabaseClient _client;

  /// `public.users` is 1:1 with `auth.users`, and the "Authenticated users can
  /// read profiles" policy lets any signed-in account read it — so the role the
  /// app routes on is exactly the role the RLS policies use.
  ///
  /// Every failure is turned into a [ProfileLookupException] with a sentence a
  /// student can act on, so the gate never has to interpret a PostgREST error.
  @override
  Future<UserProfile> getProfile(String userId) async {
    final Map<String, dynamic>? row;
    try {
      row = await _client
          .from('users')
          .select()
          .eq('id', userId)
          .maybeSingle();
    } on AuthException catch (error) {
      throw ProfileLookupException(
        'Could not verify your session: ${error.message}',
      );
    } catch (_) {
      throw const ProfileLookupException(
        'Could not load your profile. Check your connection and try again.',
      );
    }

    if (row == null) {
      throw const ProfileLookupException(
        'This account has no profile row yet — ask your supervisor to create one.',
      );
    }

    try {
      return UserProfile.fromMap(row);
    } on ArgumentError {
      throw ProfileLookupException(
        'Your account has an unrecognised role ("${row['role']}"). '
        'Ask your supervisor to fix it.',
      );
    } catch (_) {
      throw const ProfileLookupException(
        'Your profile row is incomplete — ask your supervisor to fix it.',
      );
    }
  }
}
