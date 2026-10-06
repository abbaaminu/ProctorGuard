import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/utils/proctor_log.dart';
import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';

/// The signed-in account's own identity, as `auth` reports it.
///
/// Only ever used to build a `profiles` row that is *missing* — see
/// [ProfileRepositoryImpl.getProfile]. The **id** is the whole point: it is the
/// value `profiles.id` references and the value `auth.uid()` returns, which is
/// what makes a self-provisioned row the caller's own row rather than a row
/// about somebody else (and therefore what `profiles_insert_self_student`'s
/// `with check` accepts).
class ProfileIdentity {
  const ProfileIdentity({
    required this.id,
    required this.email,
    this.fullName,
  });

  final String id;
  final String email;
  final String? fullName;
}

/// Reads the signed-in identity, or null when there is no session to read it
/// from.
///
/// Injectable for the same reason the repository's wait is: a test can drive
/// self-provisioning without a GoTrue session, which a unit test cannot mint.
typedef ProfileIdentityReader = ProfileIdentity? Function();

class ProfileRepositoryImpl implements ProfileRepository {
  ProfileRepositoryImpl(
    this._client, {
    this.retryDelays = defaultRetryDelays,
    Future<void> Function(Duration)? wait,
    this.currentIdentity,
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

  /// Where a missing row's identity comes from — see [_ensureOwnRow]. Null means
  /// "read it from the session", which is [_sessionIdentity].
  ///
  /// A field rather than a private one so it can be an initialising formal, the
  /// same shape [retryDelays] has: both exist to be injected by a test.
  final ProfileIdentityReader? currentIdentity;

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
  /// A row that is *still* absent after the window is not simply reported: the
  /// account is first given its own row back, through the one insert
  /// `profiles_insert_self_student` authorises (its own id, `role = 'student'`),
  /// and the sentence below is only reached if even that fails. See
  /// [_ensureOwnRow] for why that is a repair the account may make for itself and
  /// not a privilege this class is inventing.
  ///
  /// Every failure is turned into a [ProfileLookupException] with a sentence the
  /// user can act on, so the gate never has to interpret a PostgREST error.
  @override
  Future<UserProfile> getProfile(String userId) async {
    for (var attempt = 0;; attempt++) {
      final row = await _readRow(userId);
      if (row != null) return _profileFrom(row);

      // Out of attempts: the row really is absent (an account created outside the
      // app's own provisioning, or one whose `profiles` row carries a different
      // id). Before that is reported, the account is given its own row back —
      // see [_ensureOwnRow]: signing in and being told "this account has no
      // profile row yet" on every single attempt was the one failure a student
      // could neither understand nor act on.
      if (attempt >= retryDelays.length) {
        final provisioned = await _ensureOwnRow(userId);
        if (provisioned != null) return _profileFrom(provisioned);

        // Still nothing: this is the sentence that reaches the gate only after
        // every look, and the repair, have failed.
        throw const ProfileLookupException(
          'This account has no profile row yet — ask your administrator to create one.',
        );
      }

      await _wait(retryDelays[attempt]);
    }
  }

  /// Creates the caller's own `profiles` row when there is none to read, and
  /// returns the row that then reads back — `null` when it could not be created.
  ///
  /// This is exactly the repair `profiles_insert_self_student` authorises: a
  /// signed-in account may insert **its own** row (`id = auth.uid()`) and only
  /// with `role = 'student'`. So it is a repair the account is allowed to make
  /// for itself, not a privilege the app is inventing — and it is deliberately
  /// the narrowest version of it:
  ///
  ///   * it only runs once every read has failed, never alongside one;
  ///   * it only runs when the session can name the account
  ///     ([ProfileIdentityReader]); with no session there is nothing to write
  ///     *about*, and the caller gets the same retryable message as before;
  ///   * it can never mint a staff login — the policy's
  ///     `with check (role = 'student')` refuses any other role;
  ///   * it is best-effort: a refusal, a duplicate key (a row another tab
  ///     created while this one was looking, or an email already in use) or a
  ///     dropped connection is logged and left to the re-read below. Nothing
  ///     here throws, because a *repair* failing must still end in the honest
  ///     "ask your administrator" screen rather than a new crash.
  ///
  /// Staff accounts are not affected: every supported way of creating one
  /// (`admin-create-user`, `seed.sql`, the SQL editor) writes the `profiles` row
  /// together with the account, so a staff login never reaches this method. An
  /// account hand-created in the Auth dashboard that *should* have been staff
  /// lands here as a student, which is the one case an administrator then fixes
  /// by setting the role (`profiles_admin_all` is the policy that allows it).
  Future<Map<String, dynamic>?> _ensureOwnRow(String userId) async {
    final identity = (currentIdentity ?? _sessionIdentity)();
    if (identity == null || identity.id != userId) return null;
    if (identity.email.trim().isEmpty) return null;

    final name = identity.fullName?.trim();
    try {
      await _client.from('profiles').insert(<String, dynamic>{
        'id': identity.id,
        'role': 'student',
        'full_name': (name == null || name.isEmpty) ? identity.email : name,
        'email': identity.email,
      });
      proctorLog(
        'ProctorGuard profile: created the missing student row for '
        '${identity.id} (${identity.email}).',
      );
    } catch (error) {
      // Not fatal — the re-read below is the decision, not this write. The most
      // common reason to land here is benign: the row exists already (a second
      // tab, or the trigger landing late) and the primary key refused the copy.
      proctorLog(
        'ProctorGuard profile: could not self-provision a row for '
        '${identity.id}: $error',
      );
    }

    try {
      return await _readRow(userId);
    } catch (error) {
      proctorLog('ProctorGuard profile: re-reading the new row failed: $error');
      return null;
    }
  }

  /// The session's own view of who is signed in: the default
  /// [ProfileIdentityReader].
  ProfileIdentity? _sessionIdentity() {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final name = user.userMetadata?['name'];
    return ProfileIdentity(
      id: user.id,
      email: user.email ?? '',
      fullName: name is String && name.trim().isNotEmpty ? name.trim() : null,
    );
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
