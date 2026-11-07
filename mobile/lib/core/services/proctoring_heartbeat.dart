import 'dart:async';

import '../../features/proctoring/domain/repositories/proctoring_repository.dart';
import '../utils/proctor_log.dart';
import '../utils/uuid.dart';

/// The positive signal that a sitting is being proctored at all.
///
/// Every other thing the client sends is a *negative*: a `proctoring_logs` row
/// says something went wrong, and the absence of rows says nothing at all - an
/// unproctored attempt (killed app, closed tab, blocked script, dead wifi, a JS
/// error before the first frame) and a clean one leave the same empty feed. This
/// class closes that hole from the client side: while an attempt is being sat it
/// tells the server "still here, camera state, monitor state" on a timer, and the
/// server's `record_heartbeat()` turns the series into something a supervisor can
/// audit (`proctoring_coverage()`).
///
/// **What it proves, and what it does not.** A beat proves an authenticated
/// client of this app was running and claimed to be watching. It does not prove
/// the client was doing its job: a patched or scripted client can send beats
/// while monitoring nothing, exactly as it can fabricate a violation photo. The
/// step that would change that is platform attestation (Play Integrity / App
/// Attest), which is future work - see the README. Until then a heartbeat raises
/// the cost of the cheapest cheat (make the proctor disappear and get an empty
/// record) and a gap is evidence for a human, never a verdict.
///
/// **Why nothing is queued for later.** The offline queue exists for violations
/// and answers because a *late* strike still counts and a late answer can still
/// be graded. A late beat cannot: coverage is measured on the server's
/// `received_at`, so a beat replayed after the network comes back fills the gap
/// it was supposed to expose, which is the one failure mode that would make the
/// report lie. A beat that cannot be delivered inside [sendTimeout] is therefore
/// dropped and the next tick tries again - a missing beat is honest, a replayed
/// one is not. Failures are counted and logged, and never thrown: a heartbeat is
/// the least important thing the client does, and it must never be able to
/// interrupt an exam.
class ProctoringHeartbeatService {
  ProctoringHeartbeatService(
    this._repository, {
    this.cadence = defaultCadence,
    this.sendTimeout = defaultSendTimeout,
    String? appVersion,
    DateTime Function()? clock,
    String Function()? newEventId,
  })  : appVersion = appVersion ?? configuredAppVersion,
        _now = clock ?? DateTime.now,
        _newEventId = newEventId ?? uuidV4;

  /// How often a beat goes out.
  ///
  /// 15 s: fine enough that a supervisor looking at a live grid sees a fresh
  /// timestamp on every row, coarse enough that an hour-long sitting costs ~240
  /// rows rather than ~3,600, and comfortably slower than the server's 8 s rate
  /// limit so an honest client is never throttled by jitter.
  static const Duration defaultCadence = Duration(seconds: 15);

  /// How long one beat may take before it is written off.
  ///
  /// Shorter than [cadence] on purpose: a request that hangs must not still be
  /// the in-flight one when the next tick arrives, or one bad socket turns the
  /// series into a single stuck call. Four seconds is a generous
  /// `record_heartbeat` round trip and leaves the rest of the cadence free.
  static const Duration defaultSendTimeout = Duration(seconds: 4);

  /// Where the build's version string comes from, if it was baked in.
  ///
  /// A plain `--dart-define=APP_VERSION=1.0.0(12)` rather than a dependency:
  /// `package_info_plus` is a plugin call on every platform for one nullable
  /// diagnostic column, and this app already treats `SENTRY_DSN` (see
  /// `crash_reporting.dart`) the same way. Unset means the column stays null,
  /// which is the truth: this build did not say what it is.
  static const String appVersionDefine = 'APP_VERSION';

  /// The define above, or null when a build did not set it.
  static String? get configuredAppVersion {
    const value = String.fromEnvironment(appVersionDefine);
    return value.isEmpty ? null : value;
  }

  /// What the exam page should tell a supervisor about this build.
  final String? appVersion;

  /// How often the timer beats. Exposed so a test can shorten it instead of
  /// sleeping through a real quarter of a minute.
  final Duration cadence;

  /// Per-beat delivery deadline; see [defaultSendTimeout].
  final Duration sendTimeout;

  final ProctoringRepository _repository;
  final DateTime Function() _now;
  final String Function() _newEventId;

  Timer? _timer;
  String? _submissionId;
  bool _cameraOk = true;
  bool _monitoringOk = true;
  bool _inFlight = false;
  bool _disposed = false;

  int _acks = 0;
  int _stored = 0;
  int _failures = 0;
  DateTime? _lastAckAt;
  String? _lastError;

  /// True between [start] and [stop].
  bool get isBeating => _timer != null;

  /// The attempt being reported for, or null when idle.
  String? get submissionId => _submissionId;

  /// Beats the server answered, whichever outcome it gave. This is what coverage
  /// is made of - not how many times the timer fired.
  int get beatsAcked => _acks;

  /// Beats that added a row. Lower than [beatsAcked] whenever the server
  /// throttled (two beats inside 8 s) or deduped a replay; both are normal.
  int get beatsStored => _stored;

  /// Beats that never reached the server (offline, timeout, refused).
  ///
  /// The number on its own is the honest answer to "did the client manage to
  /// report?": a long sitting with a large [failures] count and a small
  /// [beatsAcked] count is a client that was mostly unable to speak.
  int get failures => _failures;

  /// When the server last answered a beat, per this device's clock.
  DateTime? get lastAckAt => _lastAckAt;

  /// The last delivery error, or null after a beat the server accepted. For the
  /// exam page's debug log and for tests; nothing branches on it.
  String? get lastError => _lastError;

  /// [sendTimeout] phrased for the log line under it, which is only read by a
  /// developer and should not claim "0s" in a test that shortened the deadline.
  String get _deadline =>
      sendTimeout.inMilliseconds < 1000 ? '${sendTimeout.inMilliseconds}ms' : '${sendTimeout.inSeconds}s';

  /// Begins reporting for [submissionId].
  ///
  /// Sends one beat immediately - a supervisor opening the exam seconds after a
  /// student starts should not have to wait a whole cadence to see the client is
  /// there - and then one per [cadence]. Idempotent for the same attempt, so a
  /// retried bootstrap cannot stack a second timer; calling it with a different
  /// attempt restarts the series rather than reporting for two.
  void start(
    String submissionId, {
    bool cameraOk = true,
    bool monitoringOk = true,
  }) {
    if (_disposed) return;
    if (_timer != null && _submissionId == submissionId) {
      noteCamera(cameraOk);
      noteMonitoring(monitoringOk);
      return;
    }
    stop();
    _submissionId = submissionId;
    _cameraOk = cameraOk;
    _monitoringOk = monitoringOk;
    _timer = Timer.periodic(cadence, (_) => unawaited(beatNow()));
    unawaited(beatNow());
  }

  /// Stops reporting. Safe to call twice, and safe to follow with another
  /// [start] - a resumed attempt starts a new series in the same table, which is
  /// exactly what the gap between the two should look like.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _submissionId = null;
  }

  /// Releases the timer for good. Called by the notifier's teardown; a beat is
  /// worthless once the page is gone.
  void dispose() {
    _disposed = true;
    stop();
  }

  /// Records the current state of the camera track, so the next beat can say
  /// "the monitor is up but blind" instead of being indistinguishable from a
  /// healthy one. Cheap and synchronous: the exam page calls this from the same
  /// place it calls `ProctoringNotifier.setCameraActive`.
  void noteCamera(bool ok) => _cameraOk = ok;

  /// Records the state of the monitor as a whole (detector loop, foreground
  /// app). False is the "backgrounded / paused / lost the stream" case, which the
  /// server stores as a `monitoring_ok = false` beat.
  void noteMonitoring(bool ok) => _monitoringOk = ok;

  /// Sends one beat now and returns when it has been answered or written off.
  ///
  /// Public so a resume, a manual refresh or a test can beat out of band. Never
  /// throws: every failure is counted in [failures] and logged, because a
  /// heartbeat that can break an exam is worse than no heartbeat at all.
  /// Overlapping calls collapse into the in-flight one, so a slow socket cannot
  /// pile up requests behind a fast timer.
  Future<void> beatNow() async {
    final submissionId = _submissionId;
    if (_disposed || submissionId == null || _inFlight) return;
    _inFlight = true;
    try {
      final ack = await _repository
          .recordHeartbeat(
            submissionId: submissionId,
            cameraOk: _cameraOk,
            monitoringOk: _monitoringOk,
            appVersion: appVersion,
            // What the device thought the time was. Stored for diagnostics only:
            // coverage uses the server's `received_at`, which a wrong (or moved)
            // device clock cannot distort.
            clientTime: _now(),
            // Idempotency key: a beat is a fresh event every time, but if two
            // deliveries of the *same* call ever race, the server stores one row.
            clientEventId: _newEventId(),
          )
          .timeout(sendTimeout);

      _acks++;
      if (ack.outcome.stored) _stored++;
      _lastAckAt = _now();
      _lastError = null;
    } on TimeoutException {
      _failures++;
      _lastError = 'heartbeat timed out after $_deadline';
      // Deliberately not queued: see the class docs. The next tick is the retry.
      proctorLog(
        'ProctorGuard heartbeat: no answer for $submissionId within '
        '$_deadline - coverage will show this gap.',
      );
    } catch (error) {
      _failures++;
      _lastError = '$error';
      // Also deliberately not queued, and deliberately not surfaced: a lost beat
      // is the network's business, and a student must never be interrupted by the
      // proctor's own liveness check.
      proctorLog('ProctorGuard heartbeat: beat for $submissionId failed ($error)');
    } finally {
      _inFlight = false;
    }
  }

  /// One line for a debug log or a "proctoring signal" chip.
  @override
  String toString() => isBeating
      ? 'ProctoringHeartbeatService($_submissionId: $_acks acked, '
          '$_stored stored, $_failures failed)'
      : 'ProctoringHeartbeatService(idle)';
}

