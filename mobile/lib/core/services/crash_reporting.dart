import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../utils/proctor_log.dart';

/// Where a crash report would go, resolved before anything is initialised.
///
/// The app is configured entirely through `--dart-define` values (see
/// `SupabaseConfig`), because that is the only mechanism that also works on
/// Flutter Web. Crash reporting follows the same rule:
///
///   * `--dart-define=SENTRY_DSN=https://<key>@<host>/<project-id>` turns it on.
///   * Unset means **off**, which is what a local `flutter run`, a `flutter test`
///     run and every build that has not been given the define get: no SDK
///     initialisation, no zone, no network traffic, no change in behaviour.
///   * `--dart-define=SENTRY_ENVIRONMENT=staging` labels the reports;
///     `--dart-define=SENTRY_RELEASE=<git sha>` pins them to a build.
///
/// A DSN is validated rather than trusted. It arrives as a compile-time
/// constant, so a typo is a string no SDK can parse - and `SentryFlutter.init`
/// answers a bad DSN with an exception thrown *before* `runApp`, which is the
/// blank-screen startup failure the boot order in `main.dart` exists to avoid.
/// Anything that is not a real Sentry DSN is treated as "not configured".
class CrashReportingConfig {
  const CrashReportingConfig({
    required this.dsn,
    required this.environment,
    this.release,
  });

  /// The DSN to report to, or the empty string when crash reporting is off.
  final String dsn;

  /// `production`, `debug`, or whatever `SENTRY_ENVIRONMENT` says.
  final String environment;

  /// Usually the git SHA CI passed in `SENTRY_RELEASE`; null lets the SDK
  /// decide.
  final String? release;

  /// Whether there is a usable DSN. Never true for a placeholder or a typo.
  bool get enabled => dsn.isNotEmpty;

  /// The `--dart-define` names this file reads, named once so the workflows and
  /// `mobile/README.md` cannot drift from the code.
  static const String dsnDefine = 'SENTRY_DSN';
  static const String environmentDefine = 'SENTRY_ENVIRONMENT';
  static const String releaseDefine = 'SENTRY_RELEASE';

  /// [fromValues] with the compile-time constants already read.
  static CrashReportingConfig fromEnvironment() => fromValues(
        dsn: const String.fromEnvironment(dsnDefine),
        environment: const String.fromEnvironment(environmentDefine),
        release: const String.fromEnvironment(releaseDefine),
      );

  /// The same resolution with the values injected, so the rules below are
  /// testable — a compile-time define cannot be faked at runtime.
  ///
  /// [isRelease] and [isDebug] exist for the same reason: the test host is
  /// always debug, and the fallback environment name differs by build mode.
  static CrashReportingConfig fromValues({
    required String dsn,
    String environment = '',
    String release = '',
    bool? isRelease,
    bool? isDebug,
  }) {
    final trimmedDsn = dsn.trim();
    final trimmedEnvironment = environment.trim();
    final trimmedRelease = release.trim();

    return CrashReportingConfig(
      dsn: isSentryDsn(trimmedDsn) ? trimmedDsn : '',
      environment: trimmedEnvironment.isNotEmpty
          ? trimmedEnvironment
          : (isRelease ?? kReleaseMode)
              ? 'production'
              : (isDebug ?? kDebugMode)
                  ? 'debug'
                  : 'profile',
      release: trimmedRelease.isEmpty ? null : trimmedRelease,
    );
  }

  /// Whether [candidate] is a DSN in the shape Sentry's own parser accepts:
  /// `<scheme>://<public key>@<host>[:port]/<numeric project id>`.
  ///
  /// Deliberately structural rather than a host allow-list: a self-hosted
  /// Sentry is a legitimate deployment, and what matters here is that the SDK
  /// will not throw on it.
  static bool isSentryDsn(String candidate) {
    if (candidate.isEmpty) return false;

    final uri = Uri.tryParse(candidate);
    if (uri == null) return false;
    if (uri.scheme != 'https' && uri.scheme != 'http') return false;
    if (uri.host.isEmpty) return false;
    if (uri.userInfo.isEmpty) return false; // the public key

    final path = uri.pathSegments.where((segment) => segment.isNotEmpty);
    if (path.isEmpty) return false;
    return int.tryParse(path.last) != null;
  }
}

/// Installs Sentry when a DSN was compiled in, and then runs the app.
///
/// The boot order is the point. `main.dart` hands this the whole startup - the
/// Supabase client, the first permission pass, `runApp` - so a crash *during*
/// boot is reported, which is exactly the class of failure that is otherwise
/// only visible as "it shows a white screen on that phone".
///
/// **Guarded zone.** `SentryFlutter.init` is the guarded-zone initialiser, and
/// this file deliberately does not install a second one:
///
///   * On the web the SDK runs `appRunner` inside its own `runZonedGuarded`
///     (`RunZonedGuardedIntegration`), which captures the asynchronous errors
///     `PlatformDispatcher.onError` cannot see there.
///   * On Android and iOS it installs `FlutterError.onError` and
///     `PlatformDispatcher.onError` before `appRunner` runs.
///
/// Nesting another `runZonedGuarded` inside `appRunner` would shadow those
/// handlers: an error would reach the inner zone only, so it would have to be
/// re-reported by hand, and a fatal startup error would surface twice.
class CrashReporting {
  const CrashReporting._();

  /// Initialises crash reporting (unless [config] is disabled) and calls
  /// [appRunner] once the SDK is ready.
  ///
  /// [appRunner] is called exactly once either way — including when
  /// initialisation throws, which is the one thing this must guarantee: an
  /// observability tool that can keep a student out of an exam is worse than no
  /// observability tool at all.
  static Future<void> install({
    required FutureOr<void> Function() appRunner,
    CrashReportingConfig? config,
  }) async {
    final resolved = config ?? CrashReportingConfig.fromEnvironment();

    if (!resolved.enabled) {
      // No DSN: the pre-Sentry code path, unchanged.
      await appRunner();
      return;
    }

    try {
      await SentryFlutter.init(
        (options) {
          options
            ..dsn = resolved.dsn
            ..environment = resolved.environment
            ..release = resolved.release
            // Crash reporting only: no performance transactions, and therefore
            // no extra request per navigation or camera tick.
            ..tracesSampleRate = 0.0
            ..attachStacktrace = true
            // A proctoring client holds a roster of names and e-mail addresses
            // and, during an attempt, the student's face. `sendDefaultPii`
            // would attach the device/user context, `attachScreenshot` the
            // screen. The view hierarchy is off by default in the Flutter SDK,
            // so it is left to that default rather than being set through an
            // option the SDK still marks experimental.
            ..sendDefaultPii = false
            ..attachScreenshot = false;
        },
        appRunner: appRunner,
      );
    } catch (error) {
      // A DSN the SDK rejects, a platform channel that is not there, a
      // transport that cannot start: all of them land here, and all of them
      // end in the app running anyway.
      proctorLog(
        'Crash reporting could not start, continuing without it: $error',
      );
      await appRunner();
    }
  }
}
