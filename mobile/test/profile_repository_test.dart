import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:proctorguard/features/auth/data/repositories/profile_repository_impl.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/auth/domain/repositories/profile_repository.dart';
import 'package:proctorguard/features/auth/presentation/providers/profile_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The sign-in race, from the repository's side - and the connection that is
/// still coming back.
///
/// Signing in emits the session a moment before the `handle_new_user` trigger's
/// `public.profiles` row is visible to a `select`, so the first answer the role
/// gate gets can legitimately be "no row" for an account that is perfectly fine.
/// `ProfileRepositoryImpl.getProfile` rides that out **silently**: the future
/// stays pending while it looks again on an increasing delay, which is what keeps
/// the gate on "Loading your profile…" instead of "We could not load your
/// profile".
///
/// A read that *fails* for a reason that may not be true a moment later - a socket
/// that never answers, a dropped connection, a gateway that could not reach the
/// database - is retried on the same schedule, because a cold start and a paused
/// project look exactly like that from here (and reporting them at once is what
/// showed "Loading your profile took too long" to students whose connection was
/// still resolving). A refused read, a row with an unknown role, and a row that is
/// still absent after the whole window are still reported at once. Every one of
/// those sentences is pinned here.
///
/// Three things make it testable without a backend and without sleeping: the
/// transport answers each request in turn ("no row yet", then a row), it can leave
/// a request hanging, and the repository's wait is injected (`wait:`), so a test
/// can hold the window open and assert the schedule rather than race it.
class _ScriptedTransport extends http.BaseClient {
  _ScriptedTransport(this._replies);

  /// One answer per request, consumed in order; the last entry is reused once the
  /// list runs out, so "the row is never there" needs a single `'[]'`.
  final List<String> _replies;

  /// Status every answer carries — 200 unless a test needs the client to see a
  /// refusal.
  int statusCode = 200;

  /// Methods to answer with [refusalStatus] instead of [statusCode]: lets a test
  /// refuse the `POST` an insert makes while leaving the reads alone, which is
  /// how "the repair was refused but the reads still worked" is expressed
  /// without a second transport.
  final Set<String> refusedMethods = <String>{};

  /// Status a [refusedMethods] request carries.
  int refusalStatus = 403;

  /// Status for one request index, when an answer's status matters as well as its
  /// body: a `PGRST003` pool timeout is a 504, a healthy read is a 200.
  final Map<int, int> statuses = <int, int>{};

  /// Request indices that never answer until [release]: the shape of a socket a
  /// cold start, a sleeping laptop or a paused project left open.
  final Set<int> hanging = <int>{};

  /// Every request the repository made, in order.
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  final List<Completer<void>> _gates = <Completer<void>>[];

  /// Lets every [hanging] request answer.
  void release() {
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final index = requests.length;
    requests.add(request);

    if (hanging.contains(index)) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }

    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          _replies[index < _replies.length ? index : _replies.length - 1],
        ),
      ),
      statuses[index] ??
          (refusedMethods.contains(request.method) ? refusalStatus : statusCode),
      headers: const <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}

/// The auth user id every row below is keyed by — `supabase/seed.sql`'s student.
const _userId = '22222222-2222-4222-8222-222222222222';

/// A PostgREST refusal, the shape the client turns into a `PostgrestException`.
const _refusal = '{"code":"42501","message":"permission denied for table '
    'profiles","details":null,"hint":null}';

/// PostgREST's "the pool had no connection to give" answer: `PGRST003` with a
/// 504. It says nothing about the account, which is why it is retried.
const _poolTimeout = '{"code":"PGRST003","message":"Timed out acquiring '
    'connection from connection pool.","details":null,"hint":null}';

/// One `public.profiles` row as PostgREST returns it, or `'[]'` for "no row
/// (yet)".
String profileRow({
  String id = _userId,
  String role = 'student',
  String fullName = 'Aisha Bello',
  String email = 'aisha.bello@proctor.test',
}) =>
    jsonEncode(<Map<String, dynamic>>[
      <String, dynamic>{
        'id': id,
        'role': role,
        'full_name': fullName,
        'email': email,
      },
    ]);

void main() {
  late _ScriptedTransport transport;

  setUp(() => transport = _ScriptedTransport(<String>['[]']));

  /// The repository under test, wired to the current [transport].
  ///
  /// `wait:` is injected by every test that reaches a retry: letting the real
  /// `Future.delayed` through would spend the whole 5.5 second window in the
  /// suite. The default here resolves immediately, so the schedule is still the
  /// real one and only the waiting is skipped. `attemptTimeout` is left at the
  /// shipped value except by the tests that need a request to hang, where a few
  /// milliseconds stand in for four seconds.
  ProfileRepositoryImpl repository({
    List<Duration>? retryDelays,
    Duration attemptTimeout = ProfileRepositoryImpl.defaultAttemptTimeout,
    Future<void> Function(Duration)? wait,
    ProfileIdentityReader? currentIdentity,
  }) =>
      ProfileRepositoryImpl(
        SupabaseClient(
          'https://mock.supabase.co',
          'sb_publishable_mock',
          httpClient: transport,
          // `supabase` retries a GET three times on its own (`PostgrestClientOptions`,
          // network errors and 503/520 included). These tests are about the
          // repository's own window, so that layer is switched off here: otherwise
          // a single failure would be absorbed by it and neither the schedule nor
          // the sentence could be asserted.
          postgrestOptions: const PostgrestClientOptions(retryEnabled: false),
        ),
        retryDelays: retryDelays ?? ProfileRepositoryImpl.defaultRetryDelays,
        attemptTimeout: attemptTimeout,
        wait: wait ?? (duration) async {},
        currentIdentity: currentIdentity,
      );

  group('a row that is there', () {
    test('is read by the auth user id and mapped onto a role', () async {
      transport = _ScriptedTransport(<String>[profileRow()]);

      final UserProfile profile = await repository().getProfile(_userId);

      expect(profile.id, _userId);
      expect(profile.role, UserRole.student);
      expect(profile.displayName, 'Aisha Bello');
      expect(profile.isStaff, isFalse);

      // One request, and the right one: `public.profiles`, filtered by the auth
      // uid — the `id = auth.uid()` half of `profiles_select_own_or_staff` that
      // covers an account reading its own row.
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/rest/v1/profiles');
      expect(request.url.queryParameters['select'], '*');
      expect(request.url.queryParameters['id'], 'eq.$_userId');
      // `maybeSingle()` keeps `Accept: application/json` on a GET (the documented
      // workaround for supabase-flutter#560), which is why a table with no
      // matching row answers `null` instead of a 406 — the behaviour the retry
      // below is built on.
      expect(request.headers['accept'], 'application/json');
    });
  });

  group('the row is late (the sign-in race)', () {
    test('looks again, silently, until the trigger\'s row appears', () async {
      transport = _ScriptedTransport(<String>['[]', '[]', profileRow()]);

      // Each wait is held open by the test, so "still pending" is assertable
      // rather than a race against the transport.
      final waits = <Duration>[];
      final gates = <Completer<void>>[];
      final profile = repository(
        wait: (duration) {
          waits.add(duration);
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      ).getProfile(_userId);

      String? outcome;
      unawaited(
        profile.then(
          (_) => outcome = 'value',
          onError: (_) => outcome = 'error',
        ),
      );

      // First look: no row yet, so the repository is inside its window.
      await pumpEventQueue();
      expect(transport.requests.length, 1);
      expect(waits, <Duration>[const Duration(milliseconds: 250)]);
      expect(
        outcome,
        isNull,
        reason: 'nothing is reported while it is still looking — no error screen '
            'may flash for a row that is about to arrive',
      );

      gates.first.complete();
      await pumpEventQueue();
      expect(transport.requests.length, 2);
      expect(waits.last, const Duration(milliseconds: 750));
      expect(outcome, isNull);

      gates.last.complete();
      await pumpEventQueue();

      expect(outcome, 'value');
      expect((await profile).role, UserRole.student);
      expect(transport.requests.length, 3);
      expect(
        waits,
        <Duration>[
          const Duration(milliseconds: 250),
          const Duration(milliseconds: 750),
        ],
        reason: 'the window the gate\'s loading screen covers',
      );
    });

    test('gives up after the whole window and explains the absence', () async {
      transport = _ScriptedTransport(<String>['[]']); // never there
      final waits = <Duration>[];

      await expectLater(
        repository(wait: (duration) async => waits.add(duration))
            .getProfile(_userId),
        throwsA(
          isA<ProfileLookupException>().having(
            (error) => error.message,
            'message',
            contains('no profile row yet'),
          ),
        ),
      );

      // One immediate look plus one per delay, and no more: after that the gate
      // shows the sentence above with its retry and its sign-out, so an account
      // the trigger never created is never left on a spinner.
      expect(
        transport.requests.length,
        ProfileRepositoryImpl.defaultRetryDelays.length + 1,
      );
      expect(waits, ProfileRepositoryImpl.defaultRetryDelays);
    });
  });

  group('what is not retried', () {
    test('an unknown role is reported at once, naming the value', () async {
      transport = _ScriptedTransport(<String>[profileRow(role: 'principal')]);
      final waits = <Duration>[];

      await expectLater(
        repository(wait: (duration) async => waits.add(duration))
            .getProfile(_userId),
        throwsA(
          isA<ProfileLookupException>().having(
            (error) => error.message,
            'message',
            allOf(contains('unrecognised role'), contains('principal')),
          ),
        ),
      );

      // The row arrived; it is the *value* that is wrong, and looking again would
      // only read the same wrong value. The gate offers its retry and its sign-out
      // instead of guessing a role.
      expect(transport.requests.length, 1);
      expect(waits, isEmpty);
    });

    test('a refused read is reported at once', () async {
      transport = _ScriptedTransport(<String>[_refusal])..statusCode = 403;
      final waits = <Duration>[];

      await expectLater(
        repository(wait: (duration) async => waits.add(duration))
            .getProfile(_userId),
        throwsA(
          isA<ProfileLookupException>().having(
            (error) => error.message,
            'message',
            contains('Check your connection'),
          ),
        ),
      );

      expect(transport.requests.length, 1);
      expect(
        waits,
        isEmpty,
        reason: 'there is nothing to wait for when the read itself was refused',
      );
    });
  });

  group('a connection that is still coming back', () {
    // The live failure behind these tests: a cold start, a laptop back from sleep
    // or a Supabase project coming out of pause leaves the first read unanswered or
    // dropped, and the gate used to be shown "We could not load your profile.
    // Loading your profile took too long..." for a connection that only needed a
    // moment. A read that fails that way is now retried on the same schedule as a
    // row that has not arrived yet - and a read that *keeps* failing still ends,
    // with the sentence about the connection rather than a guess about the row.

    test('a read that never answers is retried, and the row behind it wins',
        () async {
      transport = _ScriptedTransport(<String>[profileRow()])..hanging.add(0);
      final waits = <Duration>[];

      final profile = await repository(
        attemptTimeout: const Duration(milliseconds: 20),
        wait: (duration) async => waits.add(duration),
      ).getProfile(_userId);

      expect(profile.role, UserRole.student);
      expect(transport.requests.length, 2);
      expect(waits, <Duration>[const Duration(milliseconds: 250)]);

      // The abandoned request may still land. It must not be able to change
      // anything, and it must not keep the suite open.
      transport.release();
    });

    test('a connection that drops twice still gets a third chance', () async {
      // A read that fails is not a verdict: two unanswered attempts in a row are
      // exactly what a cold start looks like, and the third one is the read that
      // signs the student in.
      transport = _ScriptedTransport(<String>[profileRow()])
        ..hanging.addAll(<int>[0, 1]);
      final waits = <Duration>[];

      final profile = await repository(
        attemptTimeout: const Duration(milliseconds: 20),
        wait: (duration) async => waits.add(duration),
      ).getProfile(_userId);

      expect(profile.role, UserRole.student);
      expect(transport.requests.length, 3);
      expect(
        waits,
        <Duration>[
          const Duration(milliseconds: 250),
          const Duration(milliseconds: 750),
        ],
        reason: 'the delays grow, but the whole window is on the student\'s side',
      );
      transport.release();
    });

    test('a gateway that never reached the database is retried', () async {
      // `PGRST003` / 504 is PostgREST saying its pool had no connection to give,
      // and a proxy in front of a paused project answers a 5xx with no PostgREST
      // body at all. Neither is an answer about this account.
      transport = _ScriptedTransport(<String>[_poolTimeout, profileRow()])
        ..statuses[0] = 504;

      final profile = await repository(wait: (duration) async {})
          .getProfile(_userId);

      expect(profile.role, UserRole.student);
      expect(transport.requests.length, 2);
    });

    test('a connection that keeps failing ends on the connection sentence',
        () async {
      // Every read in the window goes unanswered: the shape of a socket that is
      // gone rather than slow.
      transport = _ScriptedTransport(<String>['[]'])
        ..hanging.addAll(<int>[0, 1, 2, 3, 4]);
      final waits = <Duration>[];

      await expectLater(
        repository(
          attemptTimeout: const Duration(milliseconds: 20),
          wait: (duration) async => waits.add(duration),
        ).getProfile(_userId),
        throwsA(
          isA<ProfileLookupException>().having(
            (error) => error.message,
            'message',
            contains('Check your connection'),
          ),
        ),
      );

      // Every attempt in the window was used, every one of them a read...
      expect(
        transport.requests.length,
        ProfileRepositoryImpl.defaultRetryDelays.length + 1,
      );
      expect(waits, ProfileRepositoryImpl.defaultRetryDelays);
      // ...and none of them a write: a failed read says nothing about whether the
      // row exists, so self-provisioning on that guess would be worse than the
      // message.
      expect(
        transport.requests.every((request) => request.method == 'GET'),
        isTrue,
      );
      transport.release();
    });
  });

  group('the default window', () {
    test('is finite, increasing, and outlasts the gate\'s hint', () {
      final delays = ProfileRepositoryImpl.defaultRetryDelays;
      expect(delays, isNotEmpty);

      for (var i = 1; i < delays.length; i++) {
        expect(
          delays[i],
          greaterThan(delays[i - 1]),
          reason: 'the delay has to grow: a fixed one either hammers a database '
              'that is still committing or stalls a row that will never come',
        );
      }

      final total = delays.fold(Duration.zero, (sum, delay) => sum + delay);
      // Short enough that a genuinely absent row still reaches the error screen
      // (with its retry) rather than looking like a hang...
      expect(total, lessThan(const Duration(seconds: 8)));
      // ...and long enough to cover the loading screen's "Still trying" hint,
      // which appears at 1500ms (`_ProfileLoading.hintDelay` in role_gate.dart):
      // a window shorter than that could never be *seen* to be retrying.
      expect(total, greaterThan(const Duration(milliseconds: 1500)));

      // A caller on the real schedule is on the same list, so nothing has to copy
      // the numbers to talk about the window.
      expect(
        repository().retryDelays,
        same(ProfileRepositoryImpl.defaultRetryDelays),
      );

      // The gate's own bound has to outlast the repository's worst case, or a
      // connection that is merely slow is reported as a failure while it is still
      // resolving - which is the false "Loading your profile took too long" that
      // live testing hit. Five attempts, each free to take `attemptTimeout`, plus
      // the waits in between.
      final worstCase = ProfileRepositoryImpl.defaultAttemptTimeout *
              (delays.length + 1) +
          total;
      expect(
        worstCase,
        lessThan(profileLoadTimeout),
        reason: 'the repository must be allowed to finish before the gate gives up',
      );
    });
  });

  group('giving a missing row back (self-provisioning)', () {
    // An account the app's own provisioning never wrote a row for — created by
    // hand in the Supabase dashboard, or a seed whose `profiles` rows carry
    // different ids — signs in perfectly well and then has nothing for the read
    // to find. Reporting that absence on every sign-in is what students were
    // stuck on, so the repository now performs the one insert
    // `profiles_insert_self_student` authorises (its own id, `role = 'student'`)
    // and reads the row back.
    //
    // The identity a real reader gets from `auth.currentUser` is injected here,
    // because a unit test cannot mint a GoTrue session.

    const identity = ProfileIdentity(
      id: _userId,
      email: 'aisha.bello@proctor.test',
      fullName: 'Aisha Bello',
    );

    /// How many looks the look-window makes: one immediate, then one per delay.
    /// Read back from the schedule rather than copied, so the request indices
    /// below cannot drift from it.
    final looks = ProfileRepositoryImpl.defaultRetryDelays.length + 1;

    /// Every look answers "no row"; the insert's own response carries no body
    /// (PostgREST returns none without `.select()`); the read-back finds the row
    /// the insert created. That is the whole shape of the repair.
    List<String> missingThenCreated() => <String>[
          for (var i = 0; i < looks; i++) '[]', // the look-window
          '[]', // the insert
          profileRow(),
        ];

    test('creates the account its own student row, then signs it in', () async {
      transport = _ScriptedTransport(missingThenCreated());

      final profile = await repository(
        currentIdentity: () => identity,
      ).getProfile(_userId);

      expect(profile.id, _userId);
      expect(profile.role, UserRole.student);
      expect(profile.displayName, 'Aisha Bello');
      expect(profile.isStaff, isFalse);

      // One look per delay, plus the first: then one insert and one read-back -
      // in that order.
      expect(transport.requests.length, looks + 2);

      final insert = transport.requests[looks] as http.Request;
      expect(insert.method, 'POST');
      expect(insert.url.path, '/rest/v1/profiles');
      // The row is *the caller's own*, and only ever a student row: the policy's
      // `with check (id = auth.uid() and role = 'student')` is the reason this
      // cannot become a way to mint a staff login.
      expect(insert.body, contains('"id":"$_userId"'));
      expect(insert.body, contains('"role":"student"'));
      expect(insert.body, contains('aisha.bello@proctor.test'));
      expect(insert.body, contains('Aisha Bello'));

      // The read that follows is the same one the gate always made, so the role
      // that routes the account is read from the database rather than assumed.
      final reread = transport.requests.last;
      expect(reread.method, 'GET');
      expect(reread.url.queryParameters['id'], 'eq.$_userId');
    });

    test('falls back to the address when the session has no name', () async {
      transport = _ScriptedTransport(missingThenCreated());

      await repository(
        currentIdentity: () =>
            const ProfileIdentity(id: _userId, email: 'aisha@proctor.test'),
      ).getProfile(_userId);

      final insert = transport.requests[looks] as http.Request;
      // `profiles.full_name` is NOT NULL, so the address is the honest stand-in
      // for a name the session never carried.
      expect(insert.body, contains('"full_name":"aisha@proctor.test"'));
    });

    test('a refused insert is logged, and the sentence is unchanged', () async {
      // The reads work (200, no row); the write is refused — RLS, a duplicate
      // email, or a dropped connection. None of that may turn a repair that
      // could not happen into a second, worse failure.
      transport = _ScriptedTransport(<String>['[]'])
        ..refusedMethods.add('POST');

      await expectLater(
        repository(currentIdentity: () => identity).getProfile(_userId),
        throwsA(
          isA<ProfileLookupException>().having(
            (error) => error.message,
            'message',
            contains('no profile row yet'),
          ),
        ),
      );

      expect(transport.requests.length, looks + 2);
      expect(transport.requests[looks].method, 'POST');
    });

    test('a repair with no session behind it is never attempted', () async {
      // No identity: nothing to build a row from, and a row about somebody else
      // is exactly what must not be written. A look per delay and the honest
      // sentence, unchanged from before this behaviour existed.
      transport = _ScriptedTransport(<String>['[]']);

      await expectLater(
        repository().getProfile(_userId),
        throwsA(isA<ProfileLookupException>()),
      );

      expect(transport.requests.length, looks);
      expect(
        transport.requests.every((request) => request.method == 'GET'),
        isTrue,
      );
    });

    test('an identity that is not the caller is never written', () async {
      transport = _ScriptedTransport(<String>['[]']);

      await expectLater(
        repository(
          currentIdentity: () => const ProfileIdentity(
            id: '99999999-9999-4999-8999-999999999999',
            email: 'somebody.else@proctor.test',
          ),
        ).getProfile(_userId),
        throwsA(isA<ProfileLookupException>()),
      );

      expect(transport.requests.length, looks);
      expect(
        transport.requests.every((request) => request.method == 'GET'),
        isTrue,
        reason: 'a row keyed by another account is not this caller to create',
      );
    });

    test('an identity with no address is not enough to build a row', () async {
      transport = _ScriptedTransport(<String>['[]']);

      await expectLater(
        repository(
          currentIdentity: () =>
              const ProfileIdentity(id: _userId, email: '   '),
        ).getProfile(_userId),
        throwsA(isA<ProfileLookupException>()),
      );

      expect(transport.requests.length, looks);
    });

    test('a row that arrives during the window is still just a read', () async {
      // The trigger landing late: the third look finds the row, so the repair
      // never runs at all. This is the "nothing changed for a normal account"
      // half of the contract.
      transport = _ScriptedTransport(<String>['[]', '[]', profileRow()]);

      final profile = await repository(
        currentIdentity: () => identity,
      ).getProfile(_userId);

      expect(profile.role, UserRole.student);
      expect(transport.requests.length, 3);
      expect(
        transport.requests.every((request) => request.method == 'GET'),
        isTrue,
      );
    });
  });
}
