import 'dart:async';

import 'package:flutter/services.dart';

/// Why lock task mode ended without the app asking for it.
enum KioskExitReason {
  /// The student escaped screen pinning (long-press back + recents, confirm).
  studentEscaped,
}

/// Outcome of a kiosk (Android lock task / screen pinning) request.
class KioskResult {
  const KioskResult({
    required this.granted,
    this.strict = false,
    this.canDetectEscape = false,
    this.message,
  });

  /// True when the platform pinned the app (`Activity.startLockTask()`).
  final bool granted;

  /// True when a device owner whitelisted the app, so the student cannot leave
  /// the exam at all — as opposed to best-effort screen pinning, which a
  /// long-press of back + recents can still escape.
  final bool strict;

  /// True when the platform exposes its lock task state (API 23+), which is
  /// what makes escape detection possible.
  final bool canDetectEscape;

  /// Platform explanation, surfaced in logs and the exam chrome.
  final String? message;

  /// Enforced, but escapable without Device Owner status.
  bool get isBestEffort => granted && !strict;

  /// Returned on iOS/desktop/web and when Android refuses to pin.
  static const KioskResult unsupported = KioskResult(
    granted: false,
    message: 'Kiosk mode is Android-only, or the activity could not be pinned.',
  );
}

/// Bridges to the native exam-kiosk handler in `MainActivity.kt`.
///
/// Channel `lock_task_channel`:
///  * `startLock` / `stopLock` — pin/unpin the app (`startLockTask()` /
///    `stopLockTask()`), hide the status + navigation bars and keep the screen
///    awake for the duration of the exam.
///  * `isLockTaskActive` / `isLockTaskPermitted` — capability queries, also used
///    to poll for escapes (see [escapes]).
///  * [escapes] — Android has no public "lock task ended" callback on `Activity`
///    (only `DeviceAdminReceiver`, which needs device-owner status), so while
///    the app is pinned this checks `isLockTaskActive` every
///    [escapePollInterval]. Two inactive reports in a row, after pinning was
///    confirmed at least once, mean the student escaped. Forward that to
///    `ProctoringNotifier.reportKioskEscape()`, which logs the same
///    `app_minimized` violation the lifecycle observer uses.
///
/// Create one instance per exam session (the exam page owns it) so the escape
/// poll only runs while the exam is on screen.
class KioskService {
  KioskService({this.escapePollInterval = const Duration(seconds: 1)});

  static const String channelName = 'lock_task_channel';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// How often the platform is asked whether lock task is still active. One
  /// method call per interval is negligible next to the camera pipeline.
  final Duration escapePollInterval;

  final StreamController<KioskExitReason> _exits =
      StreamController<KioskExitReason>.broadcast();

  Timer? _poll;
  bool _stopping = false;
  bool _disposed = false;
  bool _pinningConfirmed = false;
  int _consecutiveInactive = 0;

  /// Emitted when lock task ends *without* [stopLock] having been called, i.e.
  /// the student left the exam instead of finishing it.
  Stream<KioskExitReason> get escapes => _exits.stream;

  Future<void> _checkStillPinned() async {
    final active = await isLockTaskActive();
    if (_disposed || _stopping) return;

    if (active) {
      _pinningConfirmed = true;
      _consecutiveInactive = 0;
      return;
    }

    // Android takes a moment to engage lock task after `startLockTask()`, and
    // an OEM may refuse pinning outright — until the platform has reported lock
    // task active at least once there is nothing to escape from. Minimising the
    // app is still caught by the lifecycle observer.
    if (!_pinningConfirmed) return;

    // A single inactive poll can be a transient state (a resume animation, a
    // permission dialog); two in a row is the student actually being out.
    _consecutiveInactive++;
    if (_consecutiveInactive < 2) return;

    _stopPolling();
    _exits.add(KioskExitReason.studentEscaped);
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  /// Pins the app for an exam session. Never throws: unsupported platforms
  /// (iOS, desktop, web) and refused pinning both come back with
  /// `granted: false` so the session can continue with a warning.
  Future<KioskResult> startLock() async {
    _stopping = false;
    _pinningConfirmed = false;
    _consecutiveInactive = 0;
    _stopPolling();

    try {
      final reply = await _channel.invokeMapMethod<String, dynamic>('startLock');
      if (reply == null || reply.isEmpty) return KioskResult.unsupported;
      final result = KioskResult(
        granted: reply['granted'] == true,
        strict: reply['strict'] == true,
        canDetectEscape: reply['canDetectEscape'] == true,
        message: reply['message'] as String?,
      );
      // Only worth polling when pinning actually engaged and the platform can
      // report its lock task state.
      if (result.granted && result.canDetectEscape) {
        _poll = Timer.periodic(escapePollInterval, (_) => _checkStillPinned());
      }
      return result;
    } on MissingPluginException {
      return KioskResult.unsupported;
    } on PlatformException catch (error) {
      return KioskResult(granted: false, message: error.message);
    }
  }

  /// Unpins the app. Call this when the exam ends *before* [dispose], so the
  /// resulting state change is not mistaken for an escape.
  Future<void> stopLock() async {
    _stopping = true;
    _stopPolling();
    try {
      await _channel.invokeMethod<void>('stopLock');
    } on MissingPluginException {
      // Not Android: nothing was ever pinned.
    } on PlatformException {
      // Already unpinned, or the activity is gone: nothing to restore.
    }
  }

  /// True while the platform reports lock task mode as active.
  Future<bool> isLockTaskActive() async {
    try {
      return await _channel.invokeMethod<bool>('isLockTaskActive') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Releases the polling timer and the escape stream.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopPolling();
    _exits.close();
  }
}

