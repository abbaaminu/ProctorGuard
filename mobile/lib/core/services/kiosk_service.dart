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
///    `stopLockTask()`), hide the status + navigation bars, keep the screen
///    awake and (while [blockScreenshots] is set) block screenshots and screen
///    recording with `FLAG_SECURE` for the duration of the exam. The `secure`
///    argument is what asks for the last one.
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
  KioskService({
    this.escapePollInterval = const Duration(seconds: 1),
    this.blockScreenshots = true,
  });

  static const String channelName = 'lock_task_channel';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// Whether the native side is asked to set `FLAG_SECURE` while the exam is
  /// pinned, so screenshots, screen recording and the recents thumbnail of the
  /// exam screen are blocked for the duration of the attempt.
  ///
  /// Sent as the `secure` argument of `startLock` and cleared by `stopLock`. It
  /// is an explicit field rather than a hard-coded constant because it is the one
  /// kiosk guarantee a *student* notices (they can no longer screenshot a
  /// question), so turning it off has to be a deliberate product decision rather
  /// than a platform accident.
  final bool blockScreenshots;

  /// Upper bound on a *command* round-trip (`startLock` / `stopLock`).
  ///
  /// A platform channel that never answers — no handler registered, a wedged
  /// activity, a suspended engine — would otherwise block the exam bootstrap
  /// forever and leave the student on a loading spinner with no way out (the
  /// exam chrome has no back button). Timing out degrades to "not pinned",
  /// which the exam chrome already reports.
  static const Duration commandTimeout = Duration(seconds: 2);

  /// Upper bound on a lock-task *state query*. A timeout is reported as
  /// "unknown" — never as an escape — so a slow device cannot burn a strike.
  static const Duration stateQueryTimeout = Duration(seconds: 1);

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

  /// The lock-task state query currently on the wire, if any.
  ///
  /// [escapePollInterval] is a *tick*, not a deadline: a device whose platform
  /// takes longer than one interval to answer used to queue a second, third and
  /// fourth identical `isLockTaskActive` call behind the first, and Android
  /// answers those queued calls with the state *at the time it gets to them*. A
  /// queued answer is therefore both stale and, in the worst case, a false escape
  /// report. Joining the call already in flight makes one question one round-trip,
  /// which is also what keeps a pinned exam from adding platform traffic.
  Future<bool?>? _stateQuery;

  /// The [startLock] currently on the wire, if any.
  ///
  /// A pin is not as idempotent as it looks: two overlapping `startLock` calls
  /// used to send two `startLock` messages and arm two escape polls, and the
  /// second assignment to [_poll] dropped the first timer on the floor — a timer
  /// that kept asking the platform once per interval for the rest of the run with
  /// no handle left to cancel it. Joining the call in flight makes one exam
  /// bootstrap one pin and one poll, and both callers act on the same answer.
  Future<KioskResult>? _startInFlight;

  /// Emitted when lock task ends *without* [stopLock] having been called, i.e.
  /// the student left the exam instead of finishing it.
  Stream<KioskExitReason> get escapes => _exits.stream;

  Future<void> _checkStillPinned() async {
    // Shared with any other caller asking about the pin at this instant (see
    // [_lockTaskState]): one tick, one platform round-trip.
    final active = await _lockTaskState();
    if (_disposed || _stopping) return;

    // The platform did not answer in time: inconclusive, not "the student
    // escaped". The next tick asks again.
    if (active == null) return;

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

  /// Asks the platform whether lock task mode is active, joining the question
  /// already in flight instead of starting a second one (see [_stateQuery]).
  ///
  /// The answer is still time-boxed by [stateQueryTimeout] inside
  /// [_isLockTaskActiveOrNull]; a caller that arrives mid-flight simply waits for
  /// the same answer rather than for a fresh one, so `isLockTaskActive()` cannot
  /// be answered from a *different* moment than the poll is judging.
  Future<bool?> _lockTaskState() {
    final inFlight = _stateQuery;
    if (inFlight != null) return inFlight;

    final query = _isLockTaskActiveOrNull();
    _stateQuery = query;
    return query.whenComplete(() {
      // Only clear our own slot: a `startLock` that reset the field while this
      // query was on the wire must not have its newer query thrown away.
      if (identical(_stateQuery, query)) _stateQuery = null;
    });
  }

  /// Pins the app for an exam session. Never throws: unsupported platforms
  /// (iOS, desktop, web) and refused pinning both come back with
  /// `granted: false` so the session can continue with a warning.
  ///
  /// Overlapping calls share the one round-trip already on the wire (see
  /// [_startInFlight]). A call that arrives after [dispose] reports
  /// [KioskResult.unsupported] instead of pinning anything: the platform half it
  /// would talk to is gone, and a pin armed from here would outlive the session
  /// that asked for it.
  Future<KioskResult> startLock() {
    if (_disposed) return Future<KioskResult>.value(KioskResult.unsupported);

    final inFlight = _startInFlight;
    if (inFlight != null) return inFlight;

    final start = _startLock();
    _startInFlight = start;
    return start.whenComplete(() {
      // Only clear our own slot: a start that began *after* this one answered
      // must not have its in-flight call discarded here.
      if (identical(_startInFlight, start)) _startInFlight = null;
    });
  }

  Future<KioskResult> _startLock() async {
    _stopping = false;
    _pinningConfirmed = false;
    _consecutiveInactive = 0;
    // Any query left over from a previous session describes the *previous* pin.
    _stateQuery = null;
    _stopPolling();

    try {
      final reply = await _channel
          .invokeMapMethod<String, dynamic>(
            'startLock',
            // The pin itself is the platform's job; this is the one thing the
            // Dart side has to state explicitly, because blocking screenshots is
            // a policy decision rather than a consequence of pinning (PG-4).
            <String, Object?>{'secure': blockScreenshots},
          )
          .timeout(commandTimeout);
      if (reply == null || reply.isEmpty) return KioskResult.unsupported;
      final result = KioskResult(
        granted: reply['granted'] == true,
        strict: reply['strict'] == true,
        canDetectEscape: reply['canDetectEscape'] == true,
        message: reply['message'] as String?,
      );
      // A `dispose` that landed while the bridge was answering wins: the timer
      // armed just below has no handle left to cancel it, and it would keep
      // asking a torn-down engine about a session that already ended.
      if (_disposed) return result;

      // Only worth polling when pinning actually engaged and the platform can
      // report its lock task state.
      if (result.granted && result.canDetectEscape) {
        _poll = Timer.periodic(escapePollInterval, (_) => _checkStillPinned());
      }
      return result;
    } on TimeoutException {
      // See [commandTimeout]: the session continues unpinned rather than
      // hanging on a bridge that is not answering.
      return KioskResult(
        granted: false,
        message: 'The kiosk bridge did not answer within '
            '${commandTimeout.inSeconds}s.',
      );
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
      await _channel.invokeMethod<void>('stopLock').timeout(commandTimeout);
    } on MissingPluginException {
      // Not Android: nothing was ever pinned.
    } on TimeoutException {
      // The bridge stopped answering, and the activity is going away with the
      // exam page anyway: there is nothing left to wait for.
    } on PlatformException {
      // Already unpinned, or the activity is gone: nothing to restore.
    }
  }

  /// True while the platform reports lock task mode as active.
  ///
  /// Time-boxed ([stateQueryTimeout]); a bridge that does not answer is
  /// reported as `false`. Use [_lockTaskState] where "unknown" and
  /// "not pinned" must be told apart, and note that this shares the escape
  /// poll's in-flight query rather than starting one of its own.
  Future<bool> isLockTaskActive() async => (await _lockTaskState()) ?? false;

  /// The raw platform query, with `null` meaning "the platform did not answer".
  ///
  /// Private on purpose: [_lockTaskState] is the only caller, so a query is never
  /// started twice for the same moment (see [_stateQuery]).
  Future<bool?> _isLockTaskActiveOrNull() async {
    try {
      return await _channel
              .invokeMethod<bool>('isLockTaskActive')
              .timeout(stateQueryTimeout) ??
          false;
    } on TimeoutException {
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
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

