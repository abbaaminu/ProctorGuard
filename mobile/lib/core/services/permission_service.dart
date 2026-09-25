import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:permission_handler/permission_handler.dart';

enum StartupPermission { camera, microphone, systemAlertWindow }

class PermissionResult {
  final StartupPermission permission;
  final PermissionStatus status;

  /// True when the permission simply doesn't exist on this platform, so
  /// nothing was requested. Callers should read it as "not required here"
  /// rather than "the student refused" — both leave [isGranted] false.
  final bool notApplicable;

  const PermissionResult(
    this.permission,
    this.status, {
    this.notApplicable = false,
  });

  bool get isGranted => status.isGranted;
}

/// What a permission *status* query told us.
///
/// [unknown] is a first-class outcome: a plugin that does not answer in time, a
/// platform without the permission, or a status value none of the known cases
/// cover. Callers must not read it as a refusal.
enum PermissionState { granted, denied, unknown }

/// Result of [PermissionService.checkCritical], split so the caller can act on
/// it: only [denied] may block an exam.
class CriticalPermissionReport {
  const CriticalPermissionReport({required this.denied, required this.unknown});

  /// Explicitly refused (or permanently denied): the student has to change it in
  /// settings, so this is worth blocking on.
  final List<StartupPermission> denied;

  /// Could not be determined — reported for logging/support, never blocking.
  final List<StartupPermission> unknown;

  bool get isClear => denied.isEmpty && unknown.isEmpty;

  /// "camera and microphone", for a message to the student.
  String get deniedLabel =>
      denied.map((permission) => permission.name).join(' and ');
}

/// Requests every permission the proctoring engine needs *before* an exam
/// can start. Called once on app boot and again, defensively, right before
/// entering exam-taking mode (users can revoke permissions mid-session on
/// Android).
///
/// Platform notes:
///  * The web has no equivalent of Android's `systemAlertWindow` ("draw over
///    other apps"), and asking for it throws
///    `Unsupported operation: The Permission.systemAlertWindow permission is
///    currently not supported on web`. Those requests are skipped up front and
///    reported as [PermissionResult.notApplicable] — that thrown error is what
///    used to white-screen the app during startup.
///  * Any other platform failure (missing plugin registration, native refusal)
///    is logged and downgraded to a status instead of propagating, so a
///    permission problem can never take the whole app down at boot.
///  * Face detection itself cannot run on the web — Google ML Kit has no web
///    implementation — so pair web/desktop runs with
///    `--dart-define=MOCK_CAMERA=true` (see the mobile README).
class PermissionService {
  static const _requestOrder = [
    StartupPermission.camera,
    StartupPermission.microphone,
    StartupPermission.systemAlertWindow,
  ];

  /// Permissions that only exist on mobile. There is no browser API behind
  /// them, so they are never requested when [kIsWeb] is true.
  static const _mobileOnly = <StartupPermission>{
    StartupPermission.systemAlertWindow,
  };

  /// Whether [permission] can be requested on the current platform.
  ///
  /// [isWeb] exists so tests (and callers that already know the target) can
  /// evaluate the rule without recompiling for web; it defaults to [kIsWeb].
  static bool isSupported(StartupPermission permission, {bool? isWeb}) {
    final onWeb = isWeb ?? kIsWeb;
    if (onWeb && _mobileOnly.contains(permission)) return false;
    return true;
  }

  Future<List<PermissionResult>> requestAll() async {
    final results = <PermissionResult>[];
    for (final permission in _requestOrder) {
      results.add(await _request(permission));
    }
    return results;
  }

  /// Asks for one permission, always resolving to a [PermissionResult].
  Future<PermissionResult> _request(StartupPermission permission) async {
    if (!isSupported(permission)) {
      // Nothing to ask for on this platform: report "not applicable" instead
      // of calling into a plugin that would throw UnsupportedError.
      return PermissionResult(
        permission,
        PermissionStatus.restricted,
        notApplicable: true,
      );
    }

    try {
      return PermissionResult(permission, await _platform(permission).request());
    } catch (error) {
      // UnsupportedError / UnimplementedError / MissingPluginException mean the
      // permission has no implementation here; anything else (PlatformException)
      // means the native side refused or failed the request. Both are safe to
      // downgrade — this runs during startup, where throwing means a blank
      // screen rather than a visible message.
      final unsupported = error is UnsupportedError ||
          error is UnimplementedError ||
          error is MissingPluginException;

      debugPrint(
        'PermissionService: ${permission.name} request failed'
        '${unsupported ? ' (not supported on this platform)' : ''}: $error',
      );

      return PermissionResult(
        permission,
        unsupported ? PermissionStatus.restricted : PermissionStatus.denied,
        notApplicable: unsupported,
      );
    }
  }

  /// The two permissions an exam cannot run without, in the order they are
  /// reported to the student.
  static const List<StartupPermission> critical = [
    StartupPermission.camera,
    StartupPermission.microphone,
  ];

  Future<bool> allCriticalGranted() async {
    for (final permission in critical) {
      if (await _stateOf(permission) != PermissionState.granted) return false;
    }
    return true; // the overlay permission is best-effort, not exam-blocking
  }

  /// Called right before entering exam-taking mode.
  ///
  /// The split matters: only [CriticalPermissionReport.denied] may stop an
  /// exam. An unreadable status is reported as unknown and the caller carries
  /// on — the camera plugin reports the real refusal itself, whereas treating a
  /// slow query as "no camera" would block a device that is perfectly fine.
  Future<CriticalPermissionReport> checkCritical() async {
    final denied = <StartupPermission>[];
    final unknown = <StartupPermission>[];

    for (final permission in critical) {
      switch (await _stateOf(permission)) {
        case PermissionState.granted:
          break;
        case PermissionState.denied:
          denied.add(permission);
        case PermissionState.unknown:
          unknown.add(permission);
      }
    }

    return CriticalPermissionReport(denied: denied, unknown: unknown);
  }

  /// Convenience wrapper for callers with only a yes/no question: everything
  /// that was not confirmed granted.
  Future<List<StartupPermission>> missingCriticalPermissions() async {
    final report = await checkCritical();
    return <StartupPermission>[...report.denied, ...report.unknown];
  }

  /// Opens the OS app-settings page for this app, so a *permanently* denied
  /// permission can still be granted (Android and iOS stop prompting after
  /// "don't allow" twice). No-op where the platform has no settings page; never
  /// throws.
  Future<void> openSettings() async {
    try {
      await openAppSettings();
    } catch (error) {
      debugPrint('PermissionService: could not open settings: $error');
    }
  }

  /// Upper bound on a *status* query.
  ///
  /// A plugin that never answers must not be able to block the exam bootstrap —
  /// the exam screen has no back button, so a silent plugin would strand the
  /// student on a spinner. A timed-out query comes back as
  /// [PermissionState.unknown], which the exam screen does not block on.
  ///
  /// Permission *requests* are deliberately not time-boxed: the OS dialog
  /// legitimately stays on screen until the student answers it.
  static const Duration statusTimeout = Duration(seconds: 2);

  /// Reads one permission's state, always resolving.
  Future<PermissionState> _stateOf(StartupPermission permission) async {
    if (!isSupported(permission)) return PermissionState.unknown;

    try {
      final status = await _platform(permission).status.timeout(statusTimeout);
      if (status.isGranted || status.isLimited) return PermissionState.granted;
      if (status.isDenied || status.isPermanentlyDenied || status.isRestricted) {
        return PermissionState.denied;
      }
      return PermissionState.unknown;
    } on TimeoutException {
      debugPrint(
        'PermissionService: ${permission.name} status did not answer within '
        '$statusTimeout',
      );
      return PermissionState.unknown;
    } catch (error) {
      // UnsupportedError / MissingPluginException / PlatformException: nothing
      // usable here. Never a refusal — see [PermissionState].
      debugPrint('PermissionService: ${permission.name} status failed: $error');
      return PermissionState.unknown;
    }
  }

  Permission _platform(StartupPermission permission) => switch (permission) {
        StartupPermission.camera => Permission.camera,
        StartupPermission.microphone => Permission.microphone,
        StartupPermission.systemAlertWindow => Permission.systemAlertWindow,
      };
}

