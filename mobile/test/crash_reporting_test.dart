import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/crash_reporting.dart';

/// Crash reporting is the one subsystem that must be **invisible** unless it was
/// deliberately configured: it sits in `main()` ahead of the Supabase client and
/// the first frame, so a configuration mistake here is a student who cannot
/// start an exam.
///
/// The rules these tests pin:
///
///  * No `--dart-define=SENTRY_DSN` means no SDK: `flutter run`, `flutter test`
///    and every unconfigured build keep the exact behaviour they had before
///    Sentry was a dependency. That is the state `install` short-circuits on.
///  * A DSN that is not a DSN is the same as no DSN. Compile-time constants are
///    not validated by the dart compiler, and `SentryFlutter.init` *throws* on a
///    DSN it cannot parse - before `runApp`.
///  * The app runner runs exactly once, whatever else happens.
void main() {
  // A shape Sentry accepts: scheme, public key, host, numeric project id.
  const valid = 'https://abc123def456@o42.ingest.sentry.io/1234567';

  group('a real DSN turns reporting on', () {
    test('in the hosted shape', () {
      final config = CrashReportingConfig.fromValues(dsn: valid);

      expect(config.enabled, isTrue);
      expect(config.dsn, valid);
    });

    test('for a self-hosted Sentry too', () {
      // The check is structural, not a host allow-list: `sentry.example.edu` is
      // as legitimate a deployment as sentry.io.
      final config = CrashReportingConfig.fromValues(
        dsn: 'https://key@sentry.example.edu/7',
      );

      expect(config.enabled, isTrue);
    });

    test('after the whitespace a pasted secret comes with', () {
      final config = CrashReportingConfig.fromValues(dsn: '  $valid\n');

      expect(config.dsn, valid);
    });
  });

  group('anything that is not a DSN is treated as "not configured"', () {
    // Each of these would otherwise reach `SentryFlutter.init`, which throws
    // `ArgumentError`/`FormatException` for it - before the first frame.
    const rejected = <String, String>{
      'empty': '',
      'whitespace': '   ',
      'a placeholder from a README': 'your-dsn-here',
      'a key with no host': 'https://abc123@/1234567',
      'a host with no public key': 'https://o42.ingest.sentry.io/1234567',
      'a non-numeric project id': 'https://abc123@o42.ingest.sentry.io/project',
      'no scheme': 'abc123@o42.ingest.sentry.io/1234567',
      'the wrong scheme': 'ftp://abc123@o42.ingest.sentry.io/1234567',
    };

    rejected.forEach((description, dsn) {
      test(description, () {
        final config = CrashReportingConfig.fromValues(dsn: dsn);

        expect(config.enabled, isFalse);
        expect(config.dsn, isEmpty);
      });
    });
  });

  group('the report is labelled with the build it came from', () {
    test('release builds are production by default', () {
      expect(
        CrashReportingConfig.fromValues(dsn: valid, isRelease: true).environment,
        'production',
      );
    });

    test('debug builds are debug by default', () {
      expect(
        CrashReportingConfig.fromValues(dsn: valid, isDebug: true).environment,
        'debug',
      );
    });

    test('an explicit environment wins over the default', () {
      expect(
        CrashReportingConfig.fromValues(
          dsn: valid,
          environment: ' staging ',
          isRelease: true,
        ).environment,
        'staging',
      );
    });

    test('the release is passed through, and absent when not given', () {
      expect(
        CrashReportingConfig.fromValues(dsn: valid, release: ' 9f2c1ab ').release,
        '9f2c1ab',
      );
      expect(CrashReportingConfig.fromValues(dsn: valid).release, isNull);
    });
  });

  group('install() runs the app exactly once', () {
    test('without touching Sentry when no DSN was compiled in', () async {
      var runs = 0;

      await CrashReporting.install(
        config: const CrashReportingConfig(dsn: '', environment: 'debug'),
        appRunner: () async => runs++,
      );

      expect(runs, 1);
    });

    test('and lets a boot error reach the caller rather than swallowing it',
        () async {
      // The disabled path is the pre-Sentry code path: an exception thrown
      // there must behave exactly as it did before, or a `flutter test` that
      // expects a startup failure would start passing for the wrong reason.
      await expectLater(
        CrashReporting.install(
          config: const CrashReportingConfig(dsn: '', environment: 'test'),
          appRunner: () => throw StateError('boot failed'),
        ),
        throwsStateError,
      );
    });
  });
}
