import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:proctorguard/features/auth/data/repositories/profile_repository_impl.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/auth/domain/repositories/profile_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The sign-in race, from the repository's side.
///
/// Signing in emits the session a moment before the `handle_new_user` trigger's
/// `public.profiles` row is visible to a `select`, so the first answer the role
/// gate gets can legitimately be "no row" for an account that is perfectly fine.
/// `ProfileRepositoryImpl.getProfile` rides that out **silently**: the future
/// stays pending while it looks again on an increasing delay, which is what keeps
/// the gate on "Loading your profile…" instead of "We could not load your
/// profile".
///
/// Nothing else is retried — a refused read, a row with an unknown role, and a row
/// that is still absent after the whole window are all reported at once. Both
/// halves of that sentence are pinned here.
///
/// Two things make it testable without a backend and without sleeping: the
/// transport answers each request in turn ("no row yet", then a row), and the
/// repository's wait is injected (`wait:`), so a test can hold the window open and
/// assert the schedule rather than race it.
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

  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final index = requests.length;
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(
          _replies[index < _replies.length ? index : _replies.length - 1],
        ),
      ),
      refusedMethods.contains(request.method) ? refusalStatus : statusCode,
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
  /// `Future.delayed` through would spend the whole 2.45 second window in the
  /// suite. The default here resolves immediately, so the schedule is still the
  /// real one and only the waiting is skipped.
  ProfileRepositoryImpl repository({
    List<Duration>? retryDelays,
    Future<void> Function(Duration)? wait,
    ProfileIdentityReader? currentIdentity,
  }) =>
      ProfileRepositoryImpl(
        SupabaseClient(
          'https://mock.supabase.co',
          'sb_publishable_mock',
          httpClient: transport,
        ),
        retryDelays: retryDelays ?? ProfileRepositoryImpl.defaultRetryDelays,
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
      expect(waits.last, const Duration(milliseconds: 700));
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
          const Duration(milliseconds: 700),
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
      expect(total, lessThan(const Duration(seconds: 5)));
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
          '[]', '[]', '[]', '[]', // the look-window
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

      // Four looks, one insert, one read-back — in that order.
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
      // is exactly what must not be written. Four looks and the honest sentence,
      // unchanged from before this behaviour existed.
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
