import 'dart:async';

import 'package:proctorguard/core/services/session_gate.dart';
import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// One login per account, client half (schema.sql §1b).
///
/// Two things are pinned here, both of them about the *direction* of the
/// forgiveness:
///  * only an explicit "another session holds the account" signs a device out —
///    an offline device, a timeout and an unreadable answer must all keep the
///    student where they are (a dropped connection cannot end an exam);
///  * the sign-out happens once, from whichever check saw it first (the timer,
///    a resume, or the claim right after sign-in), and the gate never revives
///    afterwards.
void main() {
  group('sessionDeviceLabel', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('names the platform coarsely and never the device', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(sessionDeviceLabel(), 'android');

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(sessionDeviceLabel(), 'ios');

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(sessionDeviceLabel(), 'windows');

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(sessionDeviceLabel(), 'linux');
    });
  });

  group('SessionClaim.fromRpc', () {
    test('reads the winning answer', () {
      final claim = SessionClaim.fromRpc(<dynamic>[
        <String, dynamic>{
          'accepted': true,
          'active_session_id': 'session-2',
          'claimed_at': '2026-11-11T09:00:00+00:00',
          'replaced_session_id': 'session-1',
        },
      ]);

      expect(claim.accepted, isTrue);
      expect(claim.measured, isTrue);
      expect(claim.activeSessionId, 'session-2');
      expect(claim.claimedAt, DateTime.utc(2026, 11, 11, 9));
      expect(claim.replacedSessionId, 'session-1');
    });

    test('reads a refusal, which names the session that won', () {
      final claim = SessionClaim.fromRpc(<dynamic>[
        <String, dynamic>{
          'accepted': false,
          'active_session_id': 'session-2',
          'claimed_at': '2026-11-11T09:00:00+00:00',
          'replaced_session_id': null,
        },
      ]);

      expect(claim.accepted, isFalse);
      expect(claim.measured, isTrue);
      // Null on the losing answer: the session that was replaced is the
      // caller's own, so there is nothing for the client to learn from it.
      expect(claim.replacedSessionId, isNull);
    });

    test('anything unreadable means nobody was asked, so nobody is signed out',
        () {
      final unreadable = <dynamic>[
        null,
        <dynamic>[],
        <String, dynamic>{'active_session_id': 'session-2'},
        <String, dynamic>{'accepted': 'yes'},
        'nope',
      ];

      for (final response in unreadable) {
        final claim = SessionClaim.fromRpc(response);
        expect(claim.measured, isFalse, reason: '$response is not an answer');
        expect(claim.accepted, isTrue, reason: '$response must not sign out');
      }
    });
  });

  group('SessionGate', () {
    test('a superseded device signs out once and never polls again', () async {
      var checks = 0;
      var signOuts = 0;

      final gate = SessionGate(
        isCurrent: () async {
          checks++;
          return false;
        },
        onSuperseded: () async => signOuts++,
        interval: const Duration(milliseconds: 10),
      );
      addTearDown(gate.dispose);

      expect(await gate.check(), isFalse);
      expect(signOuts, 1);
      expect(gate.superseded, isTrue);

      gate.start();
      expect(gate.isRunning, isFalse, reason: 'a lost account is not re-watched');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(checks, 1, reason: 'nothing asks the server again');
      expect(signOuts, 1, reason: 'one sign-out, however many checks race it');
    });

    test('an offline device is not signed out', () async {
      var signOuts = 0;
      final gate = SessionGate(
        isCurrent: () async => throw StateError('connection refused'),
        onSuperseded: () async => signOuts++,
      );
      addTearDown(gate.dispose);

      expect(await gate.check(), isTrue);
      expect(gate.superseded, isFalse);
      expect(signOuts, 0);
    });

    test('"could not ask" is not a supersession either', () async {
      var signOuts = 0;
      final gate = SessionGate(
        isCurrent: () async => null,
        onSuperseded: () async => signOuts++,
      );
      addTearDown(gate.dispose);

      expect(await gate.check(), isTrue);
      expect(gate.superseded, isFalse);
      expect(signOuts, 0);
    });

    test('a question that never comes back does not wedge the gate', () async {
      final hang = Completer<bool?>();
      var checks = 0;
      var signOuts = 0;

      final gate = SessionGate(
        // The first ask is a socket that never answers; the second is another
        // device taking the account.
        isCurrent: () {
          checks++;
          return checks == 1 ? hang.future : Future<bool?>.value(false);
        },
        onSuperseded: () async => signOuts++,
        interval: const Duration(milliseconds: 20),
      );
      addTearDown(gate.dispose);

      expect(
        await gate.check(),
        isTrue,
        reason: 'an unanswered question is "could not ask", not a supersession',
      );
      expect(gate.superseded, isFalse);

      // The hung ask was abandoned at the interval, so this one is really asked.
      // Without the deadline `_checking` would still be `true` and every later
      // check would answer `true` without asking anything at all - a device that
      // stops policing its own session after one bad packet.
      expect(await gate.check(), isFalse);
      expect(checks, 2, reason: 'the gate kept asking after the hang');
      expect(gate.superseded, isTrue);
      expect(signOuts, 1);

      // The abandoned answer arriving late changes nothing.
      hang.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(signOuts, 1);
    });

    test('the poll itself signs the device out when the answer turns false',
        () async {
      var checks = 0;
      var signOuts = 0;

      final gate = SessionGate(
        // Mine, then somebody else's: the answer changes while the poll runs.
        isCurrent: () async {
          checks++;
          return checks < 2;
        },
        onSuperseded: () async => signOuts++,
        interval: const Duration(milliseconds: 10),
      );
      addTearDown(gate.dispose);

      gate.start();
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(checks, greaterThanOrEqualTo(2));
      expect(signOuts, 1);
      expect(gate.superseded, isTrue);
      expect(gate.isRunning, isFalse);
    });

    test('stop() suspends the poll, and a later start() resumes it', () async {
      var checks = 0;
      final gate = SessionGate(
        isCurrent: () async {
          checks++;
          return true;
        },
        onSuperseded: () async {},
        interval: const Duration(milliseconds: 10),
      );
      addTearDown(gate.dispose);

      gate.start();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      gate.stop();
      final seen = checks;
      expect(seen, greaterThanOrEqualTo(2), reason: 'the timer was polling');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(checks, seen, reason: 'a stopped gate asks nothing');

      gate.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(checks, greaterThan(seen), reason: 'a fresh sign-in resumes it');
    });

    test('checks never overlap, however many callers arrive at once', () async {
      final answer = Completer<bool>();
      var checks = 0;

      final gate = SessionGate(
        isCurrent: () {
          checks++;
          return answer.future;
        },
        onSuperseded: () async {},
      );
      addTearDown(gate.dispose);

      // A resume and a timer tick landing in the same second is the normal
      // case, not the exceptional one.
      final first = gate.check();
      final second = gate.check();
      expect(checks, 1, reason: 'one question in flight at a time');

      answer.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
    });
  });

  group('SessionSupersededException', () {
    test('explains itself in the words the student is shown', () {
      expect(
        const SessionSupersededException().toString(),
        sessionSupersededMessage,
      );
      expect(sessionSupersededMessage, contains('another device'));
    });
  });

}
