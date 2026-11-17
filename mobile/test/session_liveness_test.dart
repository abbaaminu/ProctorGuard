import 'dart:async';

import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:proctorguard/features/auth/presentation/widgets/session_liveness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widget that carries the one-login rule into the UI (schema.sql §1b).
///
/// Everything the server does is asserted in `single_session_check.sql`; what is
/// asserted here is the part only the client can get wrong — asking at the right
/// moments (once per sign-in, never per token refresh), and signing out *only*
/// when the server explicitly says another session holds the account.
void main() {
  /// What `claim_session()` answers for a device that now holds the account.
  SessionClaim accepted() => SessionClaim.fromRpc(<dynamic>[
        <String, dynamic>{
          'accepted': true,
          'active_session_id': 'session-1',
          'claimed_at': '2026-11-11T09:00:00+00:00',
          'replaced_session_id': null,
        },
      ]);

  /// What it answers for a device that lost it to a newer sign-in.
  SessionClaim refused() => SessionClaim.fromRpc(<dynamic>[
        <String, dynamic>{
          'accepted': false,
          'active_session_id': 'session-2',
          'claimed_at': '2026-11-11T09:05:00+00:00',
          'replaced_session_id': null,
        },
      ]);

  const reason = 'You signed in on another device, so this one is signed out.';

  Widget harness({
    required Stream<bool> signedIn,
    Future<AuthOutcome> Function()? signOutOtherDevices,
    Future<SessionClaim> Function({String? deviceLabel})? claimSession,
    Future<bool?> Function()? isCurrentSession,
    Future<AuthOutcome> Function()? signOut,
    List<Duration> claimRetryDelays = defaultClaimRetryDelays,
  }) =>
      MaterialApp(
        home: SessionLiveness(
          signedInChanges: signedIn,
          signOutOtherDevices: signOutOtherDevices ??
              () async => const AuthOutcome.success(),
          claimSession:
              claimSession ?? ({String? deviceLabel}) async => accepted(),
          isCurrentSession: isCurrentSession ?? () async => true,
          signOut: signOut ?? () async => const AuthOutcome.success(),
          message: reason,
          claimRetryDelays: claimRetryDelays,
          // A Scaffold, because the message has to be *shown*: the SnackBar is
          // posted to the root messenger and rendered by whichever Scaffold is
          // registered with it.
          child: const Scaffold(body: Text('signed in')),
        ),
      );

  /// Lets every awaited fake above resolve.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a sign-in claims the session, then watches it on a timer',
      (tester) async {
    var otherSignOuts = 0;
    var claims = 0;
    String? label;
    var checks = 0;

    await tester.pumpWidget(
      harness(
        signedIn: Stream<bool>.value(true),
        signOutOtherDevices: () async {
          otherSignOuts++;
          return const AuthOutcome.success();
        },
        claimSession: ({String? deviceLabel}) async {
          claims++;
          label = deviceLabel;
          return accepted();
        },
        isCurrentSession: () async {
          checks++;
          return true;
        },
      ),
    );
    await settle(tester);

    expect(otherSignOuts, 1, reason: 'older devices lose their refresh token');
    expect(claims, 1);
    // The column staff read next to a supersession: a coarse platform name,
    // never a device model.
    expect(label, isNotNull);
    expect(label, isNotEmpty);
    expect(checks, 0, reason: 'the first poll is a whole interval away');

    await tester.pump(const Duration(seconds: 31));
    expect(checks, 1, reason: 'the 30s poll is what notices a supersession');

    // Unmounts the gate: a live periodic timer would outlive the test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a refused claim signs out at once and says why', (tester) async {
    var signOuts = 0;
    var checks = 0;

    await tester.pumpWidget(
      harness(
        signedIn: Stream<bool>.value(true),
        claimSession: ({String? deviceLabel}) async => refused(),
        isCurrentSession: () async {
          checks++;
          return false;
        },
        signOut: () async {
          signOuts++;
          return const AuthOutcome.success();
        },
      ),
    );
    await settle(tester);

    expect(signOuts, 1, reason: 'the first answer is enough to sign out');
    expect(find.byKey(sessionSupersededMessageKey), findsOneWidget);
    expect(find.text(reason), findsOneWidget);
    expect(
      checks,
      0,
      reason: 'a lost account is not polled: the sign-out already happened',
    );

    // The SnackBar's own timer, so the test ends with nothing pending.
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('the poll signs the device out when the account moves on',
      (tester) async {
    var checks = 0;
    var signOuts = 0;

    await tester.pumpWidget(
      harness(
        signedIn: Stream<bool>.value(true),
        isCurrentSession: () async {
          checks++;
          return checks < 2; // mine, then somebody else's
        },
        signOut: () async {
          signOuts++;
          return const AuthOutcome.success();
        },
      ),
    );
    await settle(tester);

    await tester.pump(const Duration(seconds: 31));
    expect(checks, 1);
    expect(signOuts, 0, reason: 'still this device\'s session');

    await tester.pump(const Duration(seconds: 31));
    await settle(tester);
    expect(checks, 2);
    expect(signOuts, 1);
    expect(find.text(reason), findsOneWidget);

    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a claim the server could not answer is asked again',
      (tester) async {
    // The failure this covers: `claim_session` on a flaky link, or on a project
    // the single-session migration has not reached yet, answers "unmeasured".
    // Asking once per sign-in meant that device never claimed the account, so
    // nothing superseded anything for the rest of the sitting - the exact shape
    // of "one login works for the admin but not for this class".
    var claims = 0;

    await tester.pumpWidget(
      harness(
        signedIn: Stream<bool>.value(true),
        claimRetryDelays: const <Duration>[Duration(seconds: 1)],
        claimSession: ({String? deviceLabel}) async {
          claims++;
          return claims == 1 ? const SessionClaim.unmeasured() : accepted();
        },
      ),
    );
    await settle(tester);

    expect(claims, 1, reason: 'the first ask is at the sign-in');
    expect(
      find.text(reason),
      findsNothing,
      reason: 'an unmeasured claim is not a supersession: carry on',
    );

    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    expect(claims, 2, reason: 'the unanswered claim is re-asked on the schedule');
    expect(find.text(reason), findsNothing);

    // The schedule is finite: a device that stays offline is not asked for ever.
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(claims, 2);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a token refresh is not a new sign-in, so it claims nothing',
      (tester) async {
    final events = StreamController<bool>.broadcast();
    addTearDown(events.close);
    var claims = 0;

    await tester.pumpWidget(
      harness(
        signedIn: events.stream,
        claimSession: ({String? deviceLabel}) async {
          claims++;
          return accepted();
        },
      ),
    );

    events.add(true);
    await settle(tester);
    expect(claims, 1);

    // Same session, new token: the stream says "signed in" again, and the
    // account's session id is unchanged. Asking again would be harmless on the
    // server and noisy on the wire, so it does not happen.
    events.add(true);
    events.add(true);
    await settle(tester);
    expect(claims, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('signing out stops the watch', (tester) async {
    final events = StreamController<bool>.broadcast();
    addTearDown(events.close);
    var checks = 0;
    var signOuts = 0;

    await tester.pumpWidget(
      harness(
        signedIn: events.stream,
        isCurrentSession: () async {
          checks++;
          return false;
        },
        signOut: () async {
          signOuts++;
          return const AuthOutcome.success();
        },
      ),
    );

    events.add(true);
    await settle(tester);

    events.add(false);
    await settle(tester);

    await tester.pump(const Duration(seconds: 31));
    await settle(tester);
    expect(checks, 0, reason: 'nobody is signed in, so nothing is watched');
    expect(signOuts, 0, reason: 'a plain sign-out is not a supersession');
  });
}

