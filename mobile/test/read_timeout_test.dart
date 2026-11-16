import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:proctorguard/core/utils/read_timeout.dart';
import 'package:proctorguard/features/exam/data/repositories/exam_repository_impl.dart';
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
}
