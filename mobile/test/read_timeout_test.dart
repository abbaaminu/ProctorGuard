import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:proctorguard/features/admin/data/repositories/admin_user_repository_impl.dart';
import 'package:proctorguard/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:proctorguard/features/authoring/data/repositories/question_authoring_repository_impl.dart';
import 'package:proctorguard/core/utils/read_timeout.dart';
import 'package:proctorguard/features/authoring/domain/repositories/question_authoring_repository.dart';
import 'package:proctorguard/features/dashboard/data/repositories/dashboard_repository_impl.dart';
import 'package:proctorguard/features/dashboard/domain/repositories/dashboard_repository.dart';
import 'package:proctorguard/features/exam/data/repositories/consent_repository_impl.dart';
import 'package:proctorguard/features/exam/data/repositories/exam_repository_impl.dart';
import 'package:proctorguard/features/supervision/data/repositories/supervision_repository_impl.dart';
import 'package:proctorguard/features/supervision/domain/repositories/supervision_repository.dart';
import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A transport whose every request is accepted and never answered - the shape a
/// connection takes when a socket goes quiet without closing. Recorded, so a
/// test can also see that the read was actually sent (and sent once).
class _HungTransport extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return Completer<http.StreamedResponse>().future;
  }
}

/// The same client construction `schema_contract_test.dart` uses, with a
/// transport that will not answer it.
SupabaseClient _clientOver(http.BaseClient transport) => SupabaseClient(
      'https://mock.supabase.co',
      'sb_publishable_mock',
      httpClient: transport,
    );

/// The deadline each repository test asks for: long enough not to race a slow
/// machine, short enough that the run does not notice it.
const Duration _testTimeout = Duration(milliseconds: 20);

Matcher get _throwsTheSentence => throwsA(
      isA<ReadTimeoutException>().having(
        (error) => error.toString(),
        'toString',
        readTimeoutMessage,
      ),
    );

/// The read deadline, and the repositories that apply it.
///
/// Every group below asserts the same two things about a read that never
/// answers: it stops, and what it reports is the sentence the rest of the
/// repository layer uses for an unreachable backend. `_HungTransport` is how a
/// dead connection is reproduced - a `send` that is never going to complete,
/// which is exactly what the transport does when a socket goes quiet.
void main() {
  group('the read deadline', () {
    test('returns the read when it answers in time', () async {
      const answer = 'rows';

      final result = await withReadTimeout(
        () async => answer,
        timeout: const Duration(seconds: 1),
      );

      expect(result, answer);
    });

    test('abandons a hung read and reports the connection sentence', () async {
      final hung = Completer<String>();

      await expectLater(
        withReadTimeout(
          () => hung.future,
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<ReadTimeoutException>().having(
            (error) => error.toString(),
            'toString',
            readTimeoutMessage,
          ),
        ),
      );

      // Nothing else finishes that future: `Completer` is never completed on
      // purpose. A late answer would have been discarded anyway - what a page
      // must not do is keep waiting for it.
      expect(hung.isCompleted, isFalse);
    });

    test('a hung read stops at the deadline, not later', () async {
      final hung = Completer<String>();
      final started = DateTime.now();

      await expectLater(
        withReadTimeout(
          () => hung.future,
          timeout: const Duration(milliseconds: 30),
        ),
        throwsA(isA<ReadTimeoutException>()),
      );

      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 2)),
        reason: 'the deadline is what ends the wait, not the caller',
      );
    });

    test('the default deadline is twelve seconds', () {
      // Pinned so the documented figure and the applied one cannot drift; the
      // repositories pass it through unless a test asks for less.
      expect(defaultReadTimeout, const Duration(seconds: 12));
    });
  });

  group('the exam reads', () {
    test('the exam list gives up and says the server did not answer', () async {
      final transport = _HungTransport();
      final repository = ExamRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      await expectLater(repository.getPublishedExams(), _throwsTheSentence);

      // Sent once. A read that timed out does not re-enter the transport on its
      // own: it fails to the page, and the page owns the retry.
      expect(transport.requests, hasLength(1));
      expect(transport.requests.single.url.path, '/rest/v1/exams');
    });

    test('the question feed does, through the safe view', () async {
      final transport = _HungTransport();
      final repository = ExamRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      await expectLater(repository.getQuestions('exam-1'), _throwsTheSentence);

      expect(transport.requests.single.url.path, '/rest/v1/questions_public');
      expect(transport.requests.single.url.query, contains('exam_id=eq.exam-1'));
    });
  });

  group('the consent reads', () {
    test('the gating version gives up and says the server did not answer',
        () async {
      final transport = _HungTransport();
      final repository = ConsentRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      await expectLater(repository.currentServerVersion(), _throwsTheSentence);

      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.url.path,
        '/rest/v1/proctoring_consent_config',
      );
    });

    test('no session is answered without a request, so no deadline applies',
        () async {
      // `hasCurrentConsent` returns before it reads when there is no user - the
      // one branch where a hung transport cannot strand the consent gate.
      final transport = _HungTransport();
      final repository = ConsentRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      expect(await repository.hasCurrentConsent('exam-1'), isFalse);
      expect(transport.requests, isEmpty);
    });
  });

  group('the console reads', () {
    test('a hung analytics page reports through the dashboard error', () async {
      final transport = _HungTransport();
      final repository = DashboardRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      await expectLater(
        repository.getAnalytics(),
        throwsA(
          isA<DashboardException>().having(
            (error) => error.message,
            'message',
            contains(readTimeoutMessage),
          ),
        ),
      );

      // All three rollup reads were sent and each gave up; `Future.wait` keeps
      // the first failure and does not leave the other two unhandled.
      expect(
        transport.requests.map((request) => request.url.path),
        containsAll(<String>[
          '/rest/v1/exams',
          '/rest/v1/exam_submissions',
          '/rest/v1/proctoring_logs',
        ]),
      );
    });
  });

  group('the assignment console reads', () {
    test('the assignment list gives up as an unreachable server', () async {
      final transport = _HungTransport();
      final repository = SupervisionRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      // The deadline lands in the `catch (_)` the method already has, so an
      // administrator sees exactly what a refused connection shows them.
      await expectLater(
        repository.listAssignments(),
        throwsA(
          isA<SupervisionException>()
              .having((error) => error.message, 'message', readTimeoutMessage),
        ),
      );

      expect(
        transport.requests.single.url.path,
        '/rest/v1/supervisor_exam_assignments',
      );
    });

    test('the paper list does, on the same sentence', () async {
      final transport = _HungTransport();
      final repository = SupervisionRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      await expectLater(
        repository.listExams(),
        throwsA(
          isA<SupervisionException>()
              .having((error) => error.message, 'message', readTimeoutMessage),
        ),
      );

      expect(transport.requests.single.url.path, '/rest/v1/exams');
    });
  });

  group('the account roster read', () {
    test('an unanswered roster read reports an unreachable server', () async {
      final transport = _HungTransport();
      final repository = AdminUserRepositoryImpl(
        _clientOver(transport),
        readTimeout: _testTimeout,
      );

      // `_guard` already converts everything except an `AdminAccountException`
      // into this sentence, so the deadline needed no new branch.
      await expectLater(
        repository.listAccounts(),
        throwsA(
          isA<AdminAccountException>()
              .having((error) => error.message, 'message', readTimeoutMessage),
        ),
      );

      expect(transport.requests.single.url.path, '/rest/v1/profiles');
    });
  });

  group('the authoring console reads', () {
    QuestionAuthoringRepositoryImpl repositoryOver(
      http.BaseClient transport,
    ) =>
        QuestionAuthoringRepositoryImpl(
          _clientOver(transport),
          // The seam `RoleGate.currentUserId` uses: the console's reads are
          // filtered by owner, and this is the owner.
          currentUserId: () => 'user-1',
          readTimeout: _testTimeout,
        );

    test('the paper list gives up as an unreachable server', () async {
      final transport = _HungTransport();

      await expectLater(
        repositoryOver(transport).listMyExams(),
        throwsA(
          isA<AuthoringException>()
              .having((error) => error.message, 'message', readTimeoutMessage),
        ),
      );

      expect(transport.requests.single.url.path, '/rest/v1/exams');
      expect(
        transport.requests.single.url.query,
        contains('created_by=eq.user-1'),
      );
    });

    test('the paper\'s questions do, on the same sentence', () async {
      final transport = _HungTransport();

      await expectLater(
        repositoryOver(transport).listQuestions('exam-1'),
        throwsA(
          isA<AuthoringException>()
              .having((error) => error.message, 'message', readTimeoutMessage),
        ),
      );

      expect(transport.requests.single.url.path, '/rest/v1/questions');
    });
  });

  group('the session reads', () {
    // The singleton, because these two RPCs are what `SessionLiveness` asks and
    // there is no repository between it and `SupabaseService`.
    final service = SupabaseService.instance;

    setUp(() {
      service.debugSessionReadTimeout = _testTimeout;
      service.debugSetClient(_clientOver(_HungTransport()));
    });

    tearDown(() {
      service.debugSessionReadTimeout = null;
      service.debugSetClient(null);
    });

    test('a claim nobody answers is "could not ask", not a lost account',
        () async {
      // The sign-in that hangs on a quiet socket: without the deadline this
      // future never completes, so the 30-second watch that starts after it never
      // starts at all.
      final claim = await service.claimSession(deviceLabel: 'android');

      expect(claim.measured, isFalse);
      expect(
        claim.accepted,
        isTrue,
        reason: 'only a measured false may sign a device out',
      );
    });

    test('a liveness check nobody answers is null, so nobody is signed out',
        () async {
      expect(await service.isCurrentSession(), isNull);
    });
  });
}
