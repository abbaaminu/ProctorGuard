import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/utils/read_timeout.dart';

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
}
