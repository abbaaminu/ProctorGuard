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
    this.attemptTimeout = defaultAttemptTimeout,
    Future<void> Function(Duration)? wait,
    this.currentIdentity,
  }) : _wait = wait ?? Future<void>.delayed;

  /// The waits between attempts at `public.profiles` — the sign-in race described
  /// on [getProfile], and a connection that is still coming back.
  ///
  /// Four waits, so five attempts in total (the first is immediate): 0.25s, 0.75s,
  /// 1.5s and 3s, about 5.5 seconds of waiting at the outside. Long enough to ride
  /// out a `handle_new_user` trigger that is still committing, a read that has not
  /// caught up, or the first seconds of a network that is still resolving, and
  /// short enough that a genuinely absent row still reaches the gate's retryable
  /// error screen rather than looking like a hang. Absolute durations rather than a
  /// multiplier, so the schedule is what it says it is however it is edited.
  static const List<Duration> defaultRetryDelays = <Duration>[
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 3000),
  ];

  /// Upper bound on any single attempt at the row.
  ///
  /// A cold start, a laptop that has just woken up or a project coming out of pause
  /// can leave one request on the wire for a long time. Without a bound here that
  /// request would consume the role gate's whole timeout, so the student saw
  /// "Loading your profile took too long" for a connection that only needed a
  /// second chance. Four seconds is well above a healthy read on a slow mobile
  /// connection, and it keeps the worst case of the whole window (five attempts
  /// plus [retryDelays]: about 25 seconds) inside the gate's own bound.
  static const Duration defaultAttemptTimeout = Duration(seconds: 4);

  final SupabaseClient _client;

  /// How this class waits between attempts. Injected so a test can assert the
  /// schedule without sleeping through it.
  final Future<void> Function(Duration) _wait;

  /// How long one read is given before it is abandoned and tried again. See
  /// [defaultAttemptTimeout].
  final Duration attemptTimeout;

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
  /// Nothing else is retried. A refused request (an expired session, RLS) has
  /// nothing to wait for and is reported at once, as is a row that arrived with a
  /// role the app does not recognise.
  ///
  /// A **failed** read *is* retried, as long as the failure is the kind that might
  /// not be true a second later: a request that never answered ([attemptTimeout]),
  /// a dropped connection, a browser's "Failed to fetch", or a gateway 5xx while a
  /// project wakes up. Those used to be reported at once, which is what put "We
  /// could not load your profile" in front of a student whose connection only
  /// needed a moment - a cold start, a laptop back from sleep, a Supabase project
  /// coming out of pause. A session that is refused (`AuthException`) and a
  /// PostgREST answer that will be the same every time (a policy refusal, a missing
  /// column, a bad filter - see [_isTransientPostgrestCode]) are still reported
  /// immediately.
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
      final lastAttempt = attempt >= retryDelays.length;
      Map<String, dynamic>? row;
      try {
        row = await _readRow(userId);
      } on _TransientLookupFailure catch (failure) {
        // The *connection* failed, not the account: the row may be there and be
        // readable a moment later. Retried on the same schedule as a late row,
        // because a cold start, a laptop waking up and a project coming out of
        // pause all look exactly like this from here.
        proctorLog(
          'ProctorGuard profile: read attempt ${attempt + 1} failed: '
          '${failure.message}',
        );
        if (lastAttempt) {
          throw const ProfileLookupException(
            'Could not load your profile. Check your connection and try again.',
          );
        }
        await _wait(retryDelays[attempt]);
        continue;
      }
      if (row != null) return _profileFrom(row);

      // Out of attempts: the row really is absent (an account created outside the
      // app's own provisioning, or one whose `profiles` row carries a different
      // id). Before that is reported, the account is given its own row back —
      // see [_ensureOwnRow]: signing in and being told "this account has no
      // profile row yet" on every single attempt was the one failure a student
      // could neither understand nor act on.
      if (lastAttempt) {
        Map<String, dynamic>? provisioned;
        try {
          provisioned = await _ensureOwnRow(userId);
        } on _TransientLookupFailure {
          // The insert may well have landed; what failed is the read-back. Saying
          // "this account has no profile row yet" here would be a guess, so the
          // student is told about the connection instead - and Try again re-reads.
          throw const ProfileLookupException(
            'Could not load your profile. Check your connection and try again.',
          );
        }
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
    } on _TransientLookupFailure {
      // Not a verdict about the account: the insert may have worked and the read
      // failed on the way back. `getProfile` turns this into the connection
      // sentence rather than "no profile row yet".
      rethrow;
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

  /// One read of the caller's own `profiles` row. `null` means "no row (yet)"; a
  /// backend that refused throws the sentence the gate shows, and a failure that
  /// may be temporary throws a [_TransientLookupFailure] so [getProfile] can wait
  /// it out instead of ending the student's sign-in on it.
  ///
  /// Bounded by [attemptTimeout] on purpose: the HTTP client underneath has no
  /// default timeout, so one socket that never answers would otherwise hold the
  /// whole lookup - and the student would be told the profile took too long for a
  /// connection that was about to come back.
  Future<Map<String, dynamic>?> _readRow(String userId) async {
    try {
      return await _client
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle()
          .timeout(attemptTimeout);
    } on TimeoutException {
      throw const _TransientLookupFailure('the read did not answer in time');
    } on AuthException catch (error) {
      throw ProfileLookupException(
        'Could not verify your session: ${error.message}',
      );
    } on PostgrestException catch (error) {
      // A PostgREST error is the database's answer; only the codes that mean "no
      // database answered" are worth asking again. See [_isTransientPostgrestCode].
      if (_isTransientPostgrestCode(error.code)) {
        throw _TransientLookupFailure(
          'PostgREST ${error.code ?? '(no code)'}: ${error.message}',
        );
      }
      throw const ProfileLookupException(
        'Could not load your profile. Check your connection and try again.',
      );
    } catch (error) {
      // A dropped socket, a browser's "Failed to fetch", a TLS hiccup, a DNS
      // answer that has not arrived: the client cannot say whether the same
      // request would fail a second later, and that is exactly what the retry
      // window exists for.
      throw _TransientLookupFailure('$error');
    }
  }

  /// Whether a PostgREST failure is worth waiting out.
  ///
  /// A PostgREST error is normally the database's *answer*: `42501` (permission
  /// denied), `PGRST116` (no rows / malformed response), a missing column. Asking
  /// again produces the same answer, so those end the lookup at once. The
  /// exceptions are the codes that mean "the request never reached a database that
  /// could answer" - see [_transientPostgrestCodes] and the status branch below.
  static bool _isTransientPostgrestCode(String? code) {
    final value = code?.trim() ?? '';
    // No code at all is what a gateway 502/503 usually produces: there was no
    // PostgREST answer to read.
    if (value.isEmpty) return true;

    // `postgrest` falls back to the HTTP status as the code when the body was not
    // a PostgREST error at all (a proxy's HTML page, an empty 503), so a numeric
    // code is a status: 5xx, 408 and 429 are the "ask again" answers, and anything
    // else is a decision about this request.
    final status = int.tryParse(value);
    if (status != null) {
      return status >= 500 || status == 408 || status == 429;
    }

    return _transientPostgrestCodes.contains(value) || value.startsWith('08');
  }

  /// The PostgREST and SQLSTATE codes that mean "no answer from the database",
  /// not "the answer is no".
  static const Set<String> _transientPostgrestCodes = <String>{
    'PGRST000', // could not connect to the database
    'PGRST001', // the database connection was lost
    'PGRST003', // the request timed out waiting for a connection
    '53300', // too many connections
    '57P01', // admin shutdown
    '57P02', // crash shutdown
    '57P03', // cannot connect now (a project that is starting up)
  };

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

/// A read that failed for a reason that may not be true in a moment.
///
/// Private on purpose: [ProfileRepositoryImpl.getProfile] is the only thing that
/// decides what the student is told, and it does that once, after the whole window
/// has been spent. The [message] is for the log.
class _TransientLookupFailure implements Exception {
  const _TransientLookupFailure(this.message);

  final String message;

  @override
  String toString() => 'TransientProfileLookupFailure: $message';
}
