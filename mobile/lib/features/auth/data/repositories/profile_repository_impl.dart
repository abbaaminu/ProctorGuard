import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';

class ProfileRepositoryImpl implements ProfileRepository {
  ProfileRepositoryImpl(this._client);

  final SupabaseClient _client;

  /// `public.profiles` is 1:1 with `auth.users`, and the
  /// `profiles_select_own_or_staff` policy lets an account read its own row (and
  /// staff read every row) — so the role the app routes on is exactly the role
  /// the RLS policies use.
  ///
  /// Every failure is turned into a [ProfileLookupException] with a sentence the
  /// user can act on, so the gate never has to interpret a PostgREST error.
  @override
  Future<UserProfile> getProfile(String userId) async {
    final Map<String, dynamic>? row;
    try {
      row = await _client
          .from('profiles')
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
        'This account has no profile row yet — ask your administrator to create one.',
      );
    }

    try {
      return UserProfile.fromMap(row);
    } on ArgumentError {
      throw ProfileLookupException(
        'Your account has an unrecognised role ("${row['role']}"). '
        'Ask your administrator to fix it.',
      );
    } catch (_) {
      throw const ProfileLookupException(
        'Your profile row is incomplete — ask your administrator to fix it.',
      );
    }
  }
}
