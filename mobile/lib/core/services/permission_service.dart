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

  Future<bool> allCriticalGranted() async {
    final camera = await _isGranted(StartupPermission.camera);
    final microphone = await _isGranted(StartupPermission.microphone);
    return camera && microphone; // overlay is best-effort, not exam-blocking
  }

  /// Call right before starting an exam; returns missing permissions so the
  /// UI can block entry with a clear message instead of silently degrading
  /// proctoring quality.
  Future<List<StartupPermission>> missingCriticalPermissions() async {
    final missing = <StartupPermission>[];
    if (!await _isGranted(StartupPermission.camera)) {
      missing.add(StartupPermission.camera);
    }
    if (!await _isGranted(StartupPermission.microphone)) {
      missing.add(StartupPermission.microphone);
    }
    return missing;
  }

  /// Upper bound on a *status* query.
  ///
  /// A plugin that never answers must not be able to block the exam bootstrap —
  /// the exam screen has no back button, so a silent plugin would strand the
  /// student on a spinner. A timed-out query is reported as "not granted", which
  /// the UI can explain and offer a retry for.
  ///
  /// Permission *requests* are deliberately not time-boxed: the OS dialog
  /// legitimately stays on screen until the student answers it.
  static const Duration statusTimeout = Duration(seconds: 2);

  /// Status query with the same "never throw" guarantee as [_request] —
  /// `isGranted` has no web implementation for the mobile-only permissions
  /// either, so a query can fail exactly like a request.
  Future<bool> _isGranted(StartupPermission permission) async {
    if (!isSupported(permission)) return false;

    try {
      return await _platform(permission).isGranted.timeout(statusTimeout);
    } on TimeoutException {
      debugPrint(
        'PermissionService: ${permission.name} status did not answer within '
        '$statusTimeout',
      );
      return false;
    } catch (error) {
      debugPrint('PermissionService: ${permission.name} status failed: $error');
      return false;
    }
  }

  Permission _platform(StartupPermission permission) => switch (permission) {
        StartupPermission.camera => Permission.camera,
        StartupPermission.microphone => Permission.microphone,
        StartupPermission.systemAlertWindow => Permission.systemAlertWindow,
      };
}

