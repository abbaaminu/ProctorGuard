import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import '../utils/proctor_log.dart';

/// How often the shipped client asks the server whether it still holds the
/// account.
///
/// 30 seconds is the interval schema.sql §1b is written against: a superseded
/// device keeps a valid *access* token until `exp`, so this poll is what turns
/// "the other device signed in" into "this device is at the login screen" in
/// about half a minute instead of after an hour.
const Duration sessionCheckInterval = Duration(seconds: 30);

/// The coarse platform name sent to `claim_session(p_device_label)` — the label
/// staff see next to a supersession in `session_supersessions`.
///
/// Deliberately not the device model or the OS version: the column is evidence
/// for "which device took the account", and an app that reports more about a
/// student's hardware than that is collecting without a reason.
String sessionDeviceLabel() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}

/// Asks the server "does this token still hold the account?"; `null` means the
/// question could not be asked.
typedef SessionLivenessCheck = Future<bool?> Function();

/// Runs once when this device has been superseded: sign out locally, tell the
/// student why. The server side has already refused its writes.
typedef SessionSupersededAction = Future<void> Function();

/// Watches the account's single active session from the device's side
/// (schema.sql §1b).
///
/// The database is the authority — every write path refuses a superseded
/// session with `PT409` — but a student who was superseded mid-exam would
/// otherwise keep tapping answer buttons that quietly fail. This gate closes
/// that gap: it polls [SessionLivenessCheck] on a timer and on every app resume,
/// and hands the UI a single [superseded] event to sign out on.
///
/// It is deliberately forgiving. A failed check ([SessionLivenessCheck]
/// throwing, or answering `null`) is *not* supersession: offline students must
/// not be signed out of an exam by a dropped connection, and the SQL gate fails
/// open in exactly the same situations.
class SessionGate {
  SessionGate({
    required this.isCurrent,
    required this.onSuperseded,
    this.interval = sessionCheckInterval,
  });

  /// The question: does this token still hold the account? `null` means it could
  /// not be asked.
  final SessionLivenessCheck isCurrent;

  /// Run once, when [isCurrent] answers an explicit `false`.
  final SessionSupersededAction onSuperseded;

  /// How often [start] re-asks. Injectable so tests do not wait 30 seconds.
  final Duration interval;

  Timer? _timer;
  bool _checking = false;
  bool _superseded = false;

  /// Whether this device has been signed out for being superseded. Sticky: a
  /// superseded gate never goes back to watching.
  bool get superseded => _superseded;

  /// Whether [start] has a poll running.
  bool get isRunning => _timer != null;

  /// Begins polling. Idempotent, and a no-op once [superseded].
  void start() {
    if (_timer != null || _superseded) return;
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
  }

  /// Stops polling without forgetting a supersession — signing out, or leaving
  /// the signed-in part of the app, must not let a later [start] revive it.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  /// Asks once.
  ///
  /// Answers `false` only when the server said another session holds the
  /// account; by then [onSuperseded] has been awaited. `true` covers both "still
  /// mine" and "could not ask", because the caller cannot act on the difference
  /// and being wrong in that direction only means the next check decides.
  Future<bool> check() async {
    if (_superseded) return false;

    // One question in flight at a time: the timer, a resume and the sign-in
    // hook can all land in the same second, and three identical RPCs would be
    // three chances to answer in a different order.
    if (_checking) return true;
    _checking = true;
    try {
      final current = await isCurrent();
      if (current != false) return true;

      _superseded = true;
      stop();
      proctorLog('SessionGate: this device was superseded by a newer sign-in');
      await onSuperseded();
      return false;
    } catch (error) {
      // A check that throws is an offline device, not a lost account.
      proctorLog('SessionGate: liveness check failed: $error');
      return true;
    } finally {
      _checking = false;
    }
  }
}
