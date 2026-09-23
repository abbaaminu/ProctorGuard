import 'dart:async';

import 'package:exam_proctor/core/services/supabase_service.dart';
import 'package:exam_proctor/features/auth/presentation/pages/login_page.dart';
import 'package:exam_proctor/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the sign-in form with an injected auth call: validation, the loading
/// state, and the SnackBar wording for a rejected sign-in. No Supabase project
/// is contacted, which is why `LoginPage` takes `signIn:`.
void main() {
  const emailKey = Key('login-email');
  const passwordKey = Key('login-password');
  const submitKey = Key('login-submit');

  Widget wrap(Widget child) => MaterialApp(home: child);

  Future<void> fillForm(
    WidgetTester tester, {
    String email = 'student@example.com',
    String password = 'secret123',
  }) async {
    await tester.enterText(find.byKey(emailKey), email);
    await tester.enterText(find.byKey(passwordKey), password);
  }

  Future<void> tapSignIn(WidgetTester tester) async {
    await tester.tap(find.byKey(submitKey));
    await tester.pump();
  }

  /// Lets the SnackBar's own timer expire so the test ends with no pending
  /// timer.
  Future<void> letSnackBarExpire(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(seconds: 7));

  group('validation', () {
    testWidgets('empty fields block the call and say what is missing',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        wrap(
          LoginPage(
            signIn: ({required email, required password}) async {
              calls++;
              return const AuthOutcome.success();
            },
          ),
        ),
      );

      await tapSignIn(tester);

      expect(find.text('Enter your email address'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
      expect(calls, 0, reason: 'nothing to send yet');
    });

    testWidgets('whitespace-only fields count as empty', (tester) async {
      await tester.pumpWidget(
        wrap(
          LoginPage(
            signIn: ({required email, required password}) async =>
                const AuthOutcome.success(),
          ),
        ),
      );

      await fillForm(tester, email: '   ', password: '  ');
      await tapSignIn(tester);

      expect(find.text('Enter your email address'), findsOneWidget);
      expect(find.text('Enter your password'), findsOneWidget);
    });
  });

  group('sign-in', () {
    testWidgets('trims the credentials and shows progress while waiting',
        (tester) async {
      final pending = Completer<AuthOutcome>();
      final sent = <({String email, String password})>[];
      await tester.pumpWidget(
        wrap(
          LoginPage(
            signIn: ({required email, required password}) {
              sent.add((email: email, password: password));
              return pending.future;
            },
          ),
        ),
      );

      await fillForm(
        tester,
        email: '  student@example.com  ',
        password: ' secret123 ',
      );
      await tapSignIn(tester);

      // In flight: the button is both the spinner and the thing that cannot be
      // tapped again.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(submitKey)).onPressed,
        isNull,
      );

      pending.complete(const AuthOutcome.success());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(sent.single, (email: 'student@example.com', password: 'secret123'));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.textContaining('Signed in as student@example.com'),
        findsOneWidget,
      );

      await letSnackBarExpire(tester);
    });
  });

  group('errors', () {
    testWidgets('a wrong password is reported in a SnackBar', (tester) async {
      await tester.pumpWidget(
        wrap(
          LoginPage(
            signIn: ({required email, required password}) async =>
                const AuthOutcome.failure('Invalid login credentials'),
          ),
        ),
      );

      await fillForm(tester, password: 'not-the-password');
      await tapSignIn(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.widgetWithText(SnackBar, 'Incorrect email or password.'),
        findsOneWidget,
      );
      // The form stays put, usable for another attempt.
      expect(
        tester.widget<FilledButton>(find.byKey(submitKey)).onPressed,
        isNotNull,
      );

      await letSnackBarExpire(tester);
    });

    testWidgets('an unconfirmed email gets its own message', (tester) async {
      await tester.pumpWidget(
        wrap(
          LoginPage(
            signIn: ({required email, required password}) async =>
                const AuthOutcome.failure('Email not confirmed'),
          ),
        ),
      );

      await fillForm(tester);
      await tapSignIn(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Confirm your email address'), findsOneWidget);

      await letSnackBarExpire(tester);
    });

    testWidgets('a failure with no message still explains itself',
        (tester) async {
      await tester.pumpWidget(
        wrap(
          LoginPage(
            signIn: ({required email, required password}) async =>
                const AuthOutcome.failure(null),
          ),
        ),
      );

      await fillForm(tester);
      await tapSignIn(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Sign-in failed'), findsOneWidget);

      await letSnackBarExpire(tester);
    });

    testWidgets('an unconfigured build reports the setup problem',
        (tester) async {
      // No injected call: this is the real path for a build that booted without
      // SUPABASE_URL/KEY, which must degrade instead of throwing.
      await tester.pumpWidget(wrap(const LoginPage()));

      await fillForm(tester);
      await tapSignIn(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        find.widgetWithText(
          SnackBar,
          'Backend not configured — see the setup screen.',
        ),
        findsOneWidget,
      );

      await letSnackBarExpire(tester);
    });
  });

  group('role gate', () {
    testWidgets('a ready build with no session shows the sign-in form',
        (tester) async {
      // Pins the main.dart wiring: the "Login page goes here" placeholder is
      // gone and this form is what a signed-out student sees.
      await tester.pumpWidget(
        const ExamProctorApp(supabaseStatus: SupabaseInitStatus.ready),
      );
      await tester.pump();

      expect(find.byKey(submitKey), findsOneWidget);
      expect(find.text('Exam Proctor'), findsOneWidget);
      expect(find.text('Login page goes here'), findsNothing);
    });
  });
}
