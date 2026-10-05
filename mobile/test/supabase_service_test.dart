import 'dart:async';
import 'dart:typed_data';

import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthState;

/// Covers the Flutter Web auth hardening: `--dart-define` fallbacks, the
/// never-throwing initialisation contract, null-safe accessors, the auth-call
/// safety net and the error-tolerant auth listener.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SupabaseConfig', () {
    test('resolves a valid build and trims whitespace + trailing slash', () {
      final config = SupabaseConfig.resolve(
        url: ' https://abcdefgh.supabase.co/ ',
        publishableKey: ' sb_publishable_abc123 ',
      );

      expect(config, isNotNull);
      expect(config!.url, 'https://abcdefgh.supabase.co');
      expect(config.publishableKey, 'sb_publishable_abc123');
    });

    test('prefers the publishable key and falls back to the legacy anon key',
        () {
      final preferred = SupabaseConfig.fromValues(
        url: 'https://abcdefgh.supabase.co',
        publishableKey: 'sb_publishable_new',
        anonKey: 'legacy.anon.key',
      );
      final fallback = SupabaseConfig.fromValues(
        url: 'https://abcdefgh.supabase.co',
        publishableKey: '   ',
        anonKey: 'legacy.anon.key',
      );

      expect(preferred!.publishableKey, 'sb_publishable_new');
      expect(fallback!.publishableKey, 'legacy.anon.key');
    });

    test('is null when the build has no defines (web-safe default)', () {
      expect(SupabaseConfig.fromEnvironment(), isNull);
    });

    test('rejects empty values, placeholders and scheme-less URLs', () {
      expect(SupabaseConfig.resolve(url: '', publishableKey: 'k' * 24), isNull);
      expect(
        SupabaseConfig.resolve(
          url: 'https://abcdefgh.supabase.co',
          publishableKey: '',
        ),
        isNull,
      );
      expect(
        SupabaseConfig.resolve(
          url: 'https://your-project.supabase.co',
          publishableKey: 'sb_publishable_abc',
        ),
        isNull,
      );
      expect(
        SupabaseConfig.resolve(
          url: 'https://abcdefgh.supabase.co',
          publishableKey: 'your-anon-key',
        ),
        isNull,
      );
      expect(
        SupabaseConfig.resolve(
          url: 'abcdefgh.supabase.co',
          publishableKey: 'sb_publishable_abc',
        ),
        isNull,
      );
    });

    test('derives the SDK session key from the project ref', () {
      const config = SupabaseConfig(
        url: 'https://abcdefgh.supabase.co',
        publishableKey: 'sb_publishable_abc',
      );

      expect(config.sessionKey, 'sb-abcdefgh-auth-token');
    });

    test('refuses a plain http origin that is not this machine', () {
      // The publishable key and the student's access token travel on every request,
      // so a remote http:// origin is a credential leak over a network the school
      // does not control.
      final resolution = SupabaseConfig.resolveWithReason(
        url: 'http://abcdefgh.supabase.co',
        publishableKey: 'sb_publishable_abc',
      );

      expect(resolution.isReady, isFalse);
      expect(resolution.config, isNull);
      expect(resolution.reason, contains('https://'));
      // The reason has to name what is wrong, not just refuse: "not configured"
      // used to be the answer for a build that *did* set both values.
      expect(resolution.reason, isNot(contains('empty')));
    });

    test('accepts http only on loopback, for a local supabase stack', () {
      // `supabase start` serves http on localhost, and the Android emulator reaches
      // the host through 10.0.2.2: both are this machine, so nothing leaves it.
      for (final url in <String>[
        'http://localhost:54321',
        'http://127.0.0.1:54321',
        'http://[::1]:54321',
        'http://10.0.2.2:54321',
      ]) {
        final resolution = SupabaseConfig.resolveWithReason(
          url: url,
          publishableKey: 'sb_publishable_abc',
        );
        expect(resolution.isReady, isTrue, reason: url);
      }

      // ...and a host that merely *looks* local (a DNS name, another device on the
      // LAN) is still refused.
      for (final url in <String>[
        'http://localhost.evil.test',
        'http://192.168.1.50:54321',
        'http://notlocalhost',
      ]) {
        expect(
          SupabaseConfig.resolveWithReason(
            url: url,
            publishableKey: 'sb_publishable_abc',
          ).isReady,
          isFalse,
          reason: url,
        );
      }
    });

    test('names the missing value when the URL or key is the problem', () {
      expect(
        SupabaseConfig.resolveWithReason(url: '', publishableKey: 'k' * 24)
            .reason,
        contains('SUPABASE_URL'),
      );
      expect(
        SupabaseConfig.resolveWithReason(
          url: 'https://abcdefgh.supabase.co',
          publishableKey: '',
        ).reason,
        contains('SUPABASE_PUBLISHABLE_KEY'),
      );
    });
  });

  group('unconfigured service', () {
    test('init reports notConfigured instead of throwing', () async {
      final service = SupabaseService.instance;

      expect(await service.init(), SupabaseInitStatus.notConfigured);
      expect(service.status, SupabaseInitStatus.notConfigured);
      expect(service.isReady, isFalse);
      expect(service.clientOrNull, isNull);
      expect(service.initError, isNotNull);
    });

    test('accessors stay null-safe (no LateInitializationError)', () {
      final service = SupabaseService.instance;

      expect(service.currentUser, isNull);
      expect(service.currentUserId, isNull);
      expect(service.currentSession, isNull);
      expect(service.isSignedIn, isFalse);
      expect(service.clientOrNull, isNull);
      expect(() => service.client, throwsA(isA<StateError>()));
    });

    test('auth calls return failure outcomes instead of throwing', () async {
      final service = SupabaseService.instance;

      expect(
        (await service.signInWithPassword(
          email: 'student@proctor.test',
          password: 'x',
        ))
            .ok,
        isFalse,
      );
      expect(
        (await service.sendMagicLink(email: 'student@proctor.test')).ok,
        isFalse,
      );
      expect((await service.refreshSession()).ok, isFalse);
      expect((await service.signOut()).ok, isFalse);
      expect(
        await service.uploadViolationSnapshot(
          submissionId: 'sub-1',
          actionType: 'no_face',
          bytes: Uint8List.fromList(<int>[1, 2, 3]),
        ),
        isNull,
      );
    });
  });

  group('auth state listener', () {
    test('routes stream errors to onError and keeps listening', () async {
      final controller = StreamController<AuthState>();
      final errors = <Object>[];

      final subscription = SupabaseService.listenToAuthState(
        controller.stream,
        onState: (_) {},
        onError: errors.add,
      );

      controller.addError(StateError('token refresh failed'));
      await pumpEventQueue();
      controller.addError(StateError('second failure'));
      await pumpEventQueue();

      // Both errors reached onError (neither surfaced as an unhandled stream
      // error) and the second proves the subscription survived the first, i.e.
      // `cancelOnError: false`.
      expect(errors.map((error) => error.toString()), <String>[
        'Bad state: token refresh failed',
        'Bad state: second failure',
      ]);

      await subscription.cancel();
      await controller.close();
    });
  });
}
