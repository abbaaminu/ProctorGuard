import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';

class ProfileRepositoryImpl implements ProfileRepository {
  ProfileRepositoryImpl(
    this._client, {
    this.retryDelays = defaultRetryDelays,
    Future<void> Function(Duration)? wait,
  }) : _wait = wait ?? Future<void>.delayed;

  /// The waits between attempts at `public.profiles` while the row is not there
  /// *yet* — the sign-in race described on [getProfile].
  ///
  /// Three waits, so four attempts in total (the first is immediate): 0.25s,
  /// 0.7s and 1.5s, about 2.5 seconds at the outside. Long enough to ride out a
  /// `handle_new_user` trigger that is still committing or a read that has not
  /// caught up, and short enough that a genuinely absent row still reaches the
  /// gate's retryable error screen rather than looking like a hang. Absolute
  /// durations rather than a multiplier, so the schedule is what it says it is
  /// however it is edited.
  static const List<Duration> defaultRetryDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 700),
    Duration(milliseconds: 1500),
  ];

  final SupabaseClient _client;

  /// How this class waits between attempts. Injected so a test can assert the
  /// schedule without sleeping through it.
  final Future<void> Function(Duration) _wait;

  /// The waiting schedule, exposed so a test (and the docs) can state the retry
  /// window instead of copying it.
  final List<Duration> retryDelays;

  /// `public.profiles` is 1:1 with `auth.users`, and the
  /// `profiles_select_own_or_staff` policy lets an account read its own row (and
  /// staff read every row) — so the role the app routes on is exactly the role
  /// the RLS policies use.
  ///
  /// A **missing** row is retried silently before it is reported: signing in can
  /// emit the session a moment before the `handle_new_user` trigger's row is
  /// visible to this query, and the first answer of "no row" used to send the
  /// account straight to "We could not load your profile" for a row that was
  /// about to appear. Every attempt is separated by [retryDelays] (increasing),
  /// and the future stays unresolved for the whole window — which is what keeps
  /// the role gate on its loading screen instead of its error screen.
  ///
  /// Nothing else is retried. A refused request (no connection, an expired
  /// session, RLS) has nothing to wait for and is reported at once, as is a row
  /// that arrived with a role the app does not recognise.
  ///
  /// Every failure is turned into a [ProfileLookupException] with a sentence the
  /// user can act on, so the gate never has to interpret a PostgREST error.
  @override
  Future<UserProfile> getProfile(String userId) async {
    for (var attempt = 0;; attempt++) {
      final row = await _readRow(userId);
      if (row != null) return _profileFrom(row);

      // Out of attempts: the row really is absent (an account created outside the
      // trigger, or one an administrator still has to add). This is the sentence
      // that reaches the gate only after every look has failed.
      if (attempt >= retryDelays.length) {
        throw const ProfileLookupException(
          'This account has no profile row yet — ask your administrator to create one.',
        );
      }

      await _wait(retryDelays[attempt]);
    }
  }

  /// One read of the caller's own `profiles` row. `null` means "no row (yet)";
  /// a backend that refused throws the sentence the gate shows.
  Future<Map<String, dynamic>?> _readRow(String userId) async {
    try {
      return await _client
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
  }

  /// Maps a row onto a role, naming the column when the value is wrong.
  UserProfile _profileFrom(Map<String, dynamic> row) {
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
