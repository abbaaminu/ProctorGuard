import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import '../../../../core/utils/proctor_log.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/services/exam_lifecycle_observer.dart';
import '../../../../core/services/mediapipe_proctoring_service.dart';
import '../../../../core/services/offline_sync_service.dart';
import '../../../../core/services/supabase_service.dart';
import '../../../../core/utils/uuid.dart';
import '../../domain/entities/proctoring_risk.dart';
import '../../domain/entities/violation.dart';
import '../../domain/repositories/proctoring_repository.dart';
import '../../../exam/domain/repositories/exam_repository.dart';

// The repository providers are declared in `core/di/providers.dart` (see the note
// there) and re-exported here, so `main.dart` and every existing import site keeps
// working without knowing about the move.
export '../../../../core/di/providers.dart'
    show examRepositoryProvider, proctoringRepositoryProvider;

/// How the notifier asks the exam page for a still frame when it needs
/// evidence: the page owns the camera, the notifier just knows when to ask.
typedef SnapshotSource = Future<Uint8List?> Function();

/// Everything the exam-taking UI needs to render (overlay, warning count,
/// whether the session has just been force-ended).
class ProctoringState {
  final int warningCount;
  final bool showViolationOverlay;
  final ViolationType? lastViolation;
  final bool disqualified;

  /// True while camera-derived tracking is paused because the feed is
  /// initialising, blocked or lost. The exam page watches this to prompt the
  /// student instead of letting an unproctored session look normal.
  final bool cameraPaused;

  /// Every violation logged in this session so far, in order.
  ///
  /// This is the attempt's own evidence list, and it is kept as a list rather
  /// than folded into a number because the risk index is a function of the whole
  /// session ([risk]): a score derived from the list cannot drift away from the
  /// evidence it is supposed to summarise.
  final List<ViolationType> violationTypes;

  const ProctoringState({
    this.warningCount = 0,
    this.showViolationOverlay = false,
    this.lastViolation,
    this.disqualified = false,
    this.cameraPaused = false,
    this.violationTypes = const <ViolationType>[],
  });

  /// The attempt's risk index, recomputed from [violationTypes].
  ///
  /// [ProctoringRisk.none] until something is actually logged, so a clean
  /// session reads "Low risk · 0" rather than "unknown".
  ProctoringRisk get risk => ProctoringRisk.fromViolations(
        violationTypes,
        serverStrikes: warningCount,
      );

  ProctoringState copyWith({
    int? warningCount,
    bool? showViolationOverlay,
    ViolationType? lastViolation,
    bool? disqualified,
    bool? cameraPaused,
    List<ViolationType>? violationTypes,
  }) =>
      ProctoringState(
        warningCount: warningCount ?? this.warningCount,
        showViolationOverlay: showViolationOverlay ?? this.showViolationOverlay,
        lastViolation: lastViolation ?? this.lastViolation,
        disqualified: disqualified ?? this.disqualified,
        cameraPaused: cameraPaused ?? this.cameraPaused,
        violationTypes: violationTypes ?? this.violationTypes,
      );
}

/// Owns the MediaPipe engine + lifecycle observer for one exam session and
/// implements the section-3 escalation contract:
///   - on violation: warningCount += 1, show full-screen overlay, log to DB
///   - at warningCount >= 3: auto-submit as 'disqualified' + forced exit
///
/// Every signal — camera, audio, lifecycle, the browser's exam lockdown, the
/// browser's face-detector bridge and the device-integrity probes — enters
/// through the `report*` methods below, so the strike counter, the evidence
/// upload and the disqualification rule live in exactly one place.
///
/// Violations are delivered through a [ViolationOutbox] rather than straight to
/// the repository, so "the network is gone" queues the row instead of losing it
/// (see [OfflineSyncService]). Without an injected outbox the notifier falls back
/// to [DirectViolationOutbox] over [proctoringRepo], which is the behaviour it had
/// before the offline layer - and what the unit tests exercise.
class ProctoringNotifier extends StateNotifier<ProctoringState> {
  ProctoringNotifier({
    required this.submissionId,
    required ProctoringRepository proctoringRepo,
    required this._examRepo,
    required this._engine,
    required this._onForceExit,
    required this._uploadSnapshot,
    ViolationOutbox? outbox,
    this.snapshotTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  })  : _outbox = outbox ?? DirectViolationOutbox(proctoringRepo),
        _now = clock ?? DateTime.now,
        super(const ProctoringState()) {
    _gazeSub = _engine.signals.listen(_handleGazeSignal);
    // A violation the queue delivered after the fact still carries the server's
    // ruling: that is how a third strike taken while the network was down ends
    // the attempt instead of being discovered only in the audit log.
    _rulingsSub = _outbox.deferredRulings.listen(_handleDeferredRuling);
    // Same entry point the browser guards and the kiosk escape use, so there is
    // exactly one place that decides what "left the exam" means.
    _lifecycleObserver = ExamLifecycleObserver(
      onMinimized: reportAppMinimized,
    )..attach();
  }

  final String submissionId;
  final ViolationOutbox _outbox;
  final ExamRepository _examRepo;
  final MediaPipeProctoringService _engine;
  final void Function() _onForceExit;
  final SnapshotUploader _uploadSnapshot;

  /// Upper bound on how long a violation waits for its evidence; past this the
  /// log goes out without a picture rather than delaying escalation.
  final Duration snapshotTimeout;

  /// The clock this session reasons about time with.
  ///
  /// Injected because the one place this class looks at a clock — the per-type
  /// debounce window below — is a contract a test has to be able to reach without
  /// sleeping in real time. `DateTime.now` stays the production default. (The
  /// other time-based rule, audio sustain, belongs to `AudioNoiseDetector`, which
  /// takes its own clock for the same reason.)
  final DateTime Function() _now;

  /// Set by the exam page once the camera is running. Null in mock-camera
  /// sessions (nothing to photograph) and before the camera is ready.
  SnapshotSource? _snapshotSource;

  /// Nullable rather than `late final`: [dispose] is the one method that has to
  /// work from *any* state, and a half-constructed notifier (a listener that
  /// could not be attached, an observer whose `attach()` threw) is exactly where
  /// a `late` field would turn a teardown into a `LateInitializationError`.
  StreamSubscription<GazeSignal>? _gazeSub;
  StreamSubscription<ViolationRuling>? _rulingsSub;
  ExamLifecycleObserver? _lifecycleObserver;

  /// When each violation type was last logged, so [_dedupeWindow] applies **per
  /// type**.
  ///
  /// One shared stamp (the first shape of this) swallowed distinct signals: a
  /// student who pastes while the camera reports looking away produces two
  /// different events, and whichever arrived second was dropped as if it were a
  /// repeat of the first.
  final Map<ViolationType, DateTime> _lastLoggedAt =
      <ViolationType, DateTime>{};
  static const _dedupeWindow = Duration(seconds: 2);

  /// Whether camera-derived signals are currently being evaluated. The exam
  /// page flips this off when the feed is initialising, blocked or lost so an
  /// offline camera cannot silently accumulate disqualification flags.
  bool _cameraActive = true;

  /// Hands over the page's still-frame grabber, so violations can attach
  /// evidence. Call once, right after `startImageStream`.
  void attachSnapshotSource(SnapshotSource capture) {
    _snapshotSource = capture;
  }

  /// Pauses or resumes camera-derived violation tracking.
  ///
  /// Called with `false` while the camera feed is offline/initialising and with
  /// `true` once frames are flowing again. While paused, [GazeSignal]s are
  /// dropped and the engine's frame counters are cleared, so a lost camera shows
  /// the student a prompt rather than quietly logging `no_face`/`looking_away`
  /// strikes for a stream that is not even running.
  void setCameraActive(bool active) {
    if (!mounted) return;
    if (_cameraActive == active) return;
    _cameraActive = active;
    // A resume must not inherit a stale dedupe stamp or a half-counted frame
    // episode from before the camera dropped out.
    _lastLoggedAt.clear();
    _engine.setStreamActive(active);
    state = state.copyWith(cameraPaused: !active);
  }

  /// Whether camera-derived signals are currently being evaluated.
  bool get cameraActive => _cameraActive;

  /// A face signal that was classified off the main isolate's camera pipeline:
  /// today, a browser page's own detector (see `WebFacePresenceMonitor`).
  ///
  /// This exists because the web build has no ML Kit and cannot hand frames to a
  /// model, so the panel on the web is a *host* detector reporting through a
  /// hook. It deliberately routes into the same handler the on-device engine
  /// feeds, so a browser look-away goes through the identical ladder: the
  /// camera-paused gate, the per-violation dedupe window, the snapshot, the
  /// offline queue and the three-strike disqualification.
  ///
  /// The signal is one of the four [GazeSignal] values on-device inference also
  /// emits - a page cannot name a violation, only what it saw - and the
  /// threshold, sustain and latch rules stay in `WebFacePresenceMonitor`, so
  /// "how long is a look away" is decided once per platform rather than once per
  /// host script.
  void reportGazeSignal(GazeSignal signal) => _handleGazeSignal(signal);

  void _handleGazeSignal(GazeSignal signal) {
    // A signal that arrived after the session was torn down must not touch the
    // state of a disposed notifier (see [_registerViolation]).
    if (!mounted) return;

    // Camera offline/initialising: ignore every face signal until the page
    // confirms the feed is live again.
    if (!_cameraActive) return;

    switch (signal) {
      case GazeSignal.centered:
        return; // no violation
      case GazeSignal.lookingAway:
        _registerViolation(ViolationType.lookingAway);
        break;
      case GazeSignal.noFace:
        _registerViolation(ViolationType.noFace);
        break;
      case GazeSignal.multipleFaces:
        _registerViolation(ViolationType.multipleFaces);
        break;
    }
  }

  /// The one audio entry point: the classifier has already decided.
  ///
  /// There is deliberately **no** `reportAudioLevel(double)` on this class any
  /// more. It was a second, independent implementation of "sustained loudness is a
  /// violation" — fixed -25 dBFS threshold, its own window, `DateTime.now` — while
  /// the audio path that actually ships classifies with `AudioNoiseDetector`
  /// (calibrated threshold + sustain + post-strike cooldown, injected clock) and
  /// then calls the method below. Two rules for one event, and the unused one was
  /// the one that looked authoritative. The rule now lives in exactly one place:
  /// the detector, owned by `AudioMonitoringNotifier`, whose strike lands here so
  /// that audio shares the ladder, the server-side count and the offline queue
  /// with every other violation.
  void reportAudioNoise() => _registerViolation(ViolationType.audioNoise);

  /// The student left the exam surface: an Android kiosk escape, a browser tab
  /// switch, a window blur, or dropping out of HTML5 fullscreen. All of them are
  /// the same violation — `app_minimized` — so the strike counter, the overlay
  /// and the auto-disqualification rule stay in one place.
  void reportAppMinimized() => _registerViolation(ViolationType.appMinimized);

  /// The student tried to move content through the clipboard while the exam
  /// lockdown was on: a copy, a cut or a paste (browser build).
  ///
  /// All three are the same violation — `copy_paste_attempt` — because they are
  /// the same attempt to get question text out of the exam, or an answer into it,
  /// and the browser reports them as three DOM events rather than three
  /// behaviours.
  void reportCopyPasteAttempt() =>
      _registerViolation(ViolationType.copyPasteAttempt);

  /// The browser's context menu was suppressed: `right_click_blocked`.
  ///
  /// Nothing was served, and that is the point — the menu is the route to "view
  /// source", "inspect" and the browser's own paste, so reaching for it is the
  /// evidence.
  void reportRightClickBlocked() =>
      _registerViolation(ViolationType.rightClickBlocked);

  /// A developer-tools panel is open over the exam: `devtools_detected`.
  ///
  /// The caller decides when the geometry is conclusive (see `WebGuards`); this
  /// only records it.
  void reportDevtoolsDetected() =>
      _registerViolation(ViolationType.devtoolsDetected);

  /// A second display is attached to this device (Android: HDMI/DP, casting,
  /// screen mirroring): `secondary_display_detected`.
  ///
  /// Reported when it appears, not while it stays attached (see
  /// `HardwareIntegrityService`), so one monitor left plugged in is one event.
  void reportSecondaryDisplayDetected() =>
      _registerViolation(ViolationType.secondaryDisplayDetected);

  /// The camera feeding this attempt is not the device's own lens — an external
  /// (USB) camera, or an emulator's virtual one: `virtual_camera_detected`.
  void reportVirtualCameraDetected() =>
      _registerViolation(ViolationType.virtualCameraDetected);

  /// No keyboard or pointer activity for the idle window: `idle_afk`.
  ///
  /// Somebody may still be in front of the screen (reading, or thinking), and
  /// that is why the window is minutes rather than seconds — but a device nobody
  /// is touching is also what a student handing their phone to someone else looks
  /// like from here, so it is logged rather than ignored.
  void reportIdleAfk() => _registerViolation(ViolationType.idleAfk);

  /// Hands the engine the camera metadata it needs to upright incoming frames
  /// before detection. Call once right after choosing the front camera.
  void engineAttachCamera(CameraDescription camera) =>
      _engine.attachCamera(camera);

  /// Called by the exam-taking page's `CameraController.startImageStream`
  /// callback for every frame; internal throttling in the engine decides
  /// whether it's actually processed (see MediaPipeProctoringService).
  void engineOnFrame(
    CameraImage cameraImage, {
    DeviceOrientation deviceOrientation = DeviceOrientation.portraitUp,
  }) =>
      _engine.onCameraFrame(
        cameraImage,
        deviceOrientation: deviceOrientation,
      );

  Future<void> _registerViolation(ViolationType type) async {
    // Every path into this method — a camera signal, a lifecycle callback, the
    // audio detector, a browser guard, the kiosk escape poll — can arrive after
    // the exam page was popped, and `proctoringProvider` is autoDispose, so the
    // notifier really is gone by then. `mounted` is the only safe gate: writing
    // `state` on a disposed `StateNotifier` asserts in debug and silently drops
    // the write in release.
    if (!mounted) return;
    if (state.disqualified) return; // already ended, ignore stray signals

    // Debounce so one sustained condition doesn't spam multiple identical
    // log rows within the same couple of seconds. Per type: see [_lastLoggedAt].
    final now = _now();
    final lastLogged = _lastLoggedAt[type];
    if (lastLogged != null && now.difference(lastLogged) < _dedupeWindow) {
      return;
    }
    _lastLoggedAt[type] = now;

    // Show the full-screen alert immediately (optimistic UI) — the student
    // must see the warning before any camera/storage/network round-trip. The
    // type is appended to the session's evidence list in the same write, so the
    // risk index (`state.risk`) moves with the count instead of lagging behind it.
    state = state.copyWith(
      warningCount: state.warningCount + 1,
      showViolationOverlay: true,
      lastViolation: type,
      violationTypes: <ViolationType>[...state.violationTypes, type],
    );

    // Then collect evidence, time-boxed: a camera that refuses to grab a still
    // (some Android devices do while streaming) or an offline upload must never
    // delay the escalation below.
    final snapshotUrl = await _captureAndUploadSnapshot(type);
    if (!mounted) return; // the page went away while the still was grabbed

    // Hand the row to the outbox: it either reaches the backend now (and returns
    // the authoritative ruling) or is queued with this event's id and replayed
    // later. One id per event is what keeps a retry from writing a second strike
    // for the same violation (`proctoring_logs.client_event_id` is unique).
    final ruling = await _outbox.log(
      submissionId: submissionId,
      violation: Violation(
        type: type,
        timestamp: now,
        snapshotUrl: snapshotUrl,
        clientEventId: uuidV4(),
      ),
    );

    // This await is the long one on a slow network: a violation whose RPC is
    // still in flight when the student's exam screen closes is exactly the race
    // that used to reconcile the server count *after* teardown (and, in release,
    // silently lose it).
    if (!mounted) return;

    if (ruling == null) {
      // Queued: the strike is durable on this device and will be delivered by the
      // retry loop, so the optimistic count above is left as it stands.
      return;
    }

    // Reconcile with the server's authoritative count (source of truth -
    // protects against a client that raced ahead or fell behind).
    state = state.copyWith(warningCount: ruling.warningCount);

    if (ruling.disqualified) {
      await _forceDisqualify();
    }
  }

  /// Reconciliation for a violation the queue delivered late (the student was
  /// offline when it happened).
  ///
  /// The strike was already counted optimistically, so this only ever *raises* the
  /// count - a deferred ruling can be older than a live one that arrived first -
  /// and ends the attempt when that late delivery is what crossed the threshold.
  void _handleDeferredRuling(ViolationRuling ruling) {
    if (!mounted) return; // the queue outlives the session it belongs to
    if (ruling.submissionId != submissionId) return; // another session's queue
    if (state.disqualified) return; // already ended, nothing left to escalate

    if (ruling.warningCount > state.warningCount) {
      state = state.copyWith(warningCount: ruling.warningCount);
    }
    if (ruling.disqualified) unawaited(_forceDisqualify());
  }

  /// Captures a still frame and stores it in the private `proctor-snapshots`
  /// bucket, returning the object path to attach to the log row.
  ///
  /// A path, not a URL: the bucket is private, so a URL would either be public
  /// (the audit's finding) or expired before the evidence is reviewed. Whoever
  /// reads the row signs the path on demand
  /// (`SupabaseService.signedSnapshotUrl`).
  ///
  /// Every step is optional: mock-camera sessions never attach a source, a
  /// capture can fail, an upload can be rejected — in all of those cases this
  /// returns null and the violation is still logged, just without a picture.
  Future<String?> _captureAndUploadSnapshot(ViolationType type) async {
    final capture = _snapshotSource;
    if (capture == null) return null;

    try {
      final bytes = await capture().timeout(snapshotTimeout);
      if (bytes == null || bytes.isEmpty) return null;

      return await _uploadSnapshot(
        submissionId: submissionId,
        actionType: type.dbValue,
        bytes: bytes,
      ).timeout(snapshotTimeout);
    } catch (_) {
      // Evidence is best-effort; proctoring must keep working without it.
      return null;
    }
  }

  /// Ends the attempt: lockout overlay, server-side status, forced exit.
  ///
  /// **Idempotent, and it always exits.** The disqualification is a local
  /// consequence of the third strike — the server has already recorded
  /// `status = 'disqualified'` inside `register_violation` — so the
  /// `mark_disqualified` round-trip here is bookkeeping, not the decision. A
  /// student whose confirmation cannot be persisted (offline, RLS, a token that
  /// expired mid-exam) used to be left sitting in an exam that had already ended,
  /// with the network as the only thing that could have told them: exactly
  /// backwards. The exit therefore runs whether or not the write succeeded, and a
  /// repeated call cannot fire a second exit.
  Future<void> _forceDisqualify() async {
    if (!mounted) return;
    if (state.disqualified) return; // already locked out: one strike, one exit

    state = state.copyWith(disqualified: true, showViolationOverlay: true);

    try {
      await _examRepo.markDisqualified(submissionId);
    } catch (error) {
      // Best effort, and never fatal: the authoritative status is set by the
      // violation RPC (see above), and the offline queue replays what it can.
      proctorLog(
        'ProctoringNotifier: could not persist the disqualification of '
        '$submissionId ($error) — exiting anyway.',
      );
    }

    if (!mounted) return; // the page went away during the write
    _onForceExit();
  }

  void dismissOverlay() {
    if (!mounted) return;
    if (state.disqualified) return; // can't dismiss the final lockout screen
    state = state.copyWith(showViolationOverlay: false);
  }

  @override
  void dispose() {
    // Cancel the listeners *before* the base teardown: both streams outlive this
    // notifier (the engine is per-session, but the outbox queue is shared and
    // replays later), so a signal arriving during teardown would otherwise reach
    // a disposed `StateNotifier`. The mounted guards above make that safe either
    // way; cancelling first makes it rare.
    //
    // Not awaited: `dispose` is synchronous, and a cancel is a cleanup signal that
    // must not be able to hold up the exam page leaving the screen.
    final gazeSub = _gazeSub;
    _gazeSub = null;
    if (gazeSub != null) unawaited(gazeSub.cancel());

    final rulingsSub = _rulingsSub;
    _rulingsSub = null;
    if (rulingsSub != null) unawaited(rulingsSub.cancel());

    final observer = _lifecycleObserver;
    _lifecycleObserver = null;
    observer?.detach();
    _engine.dispose();
    super.dispose();
  }
}

/// One notifier instance per exam session (keyed by submissionId), torn
/// down automatically when the exam-taking page is popped.
final proctoringProvider = StateNotifierProvider.autoDispose
    .family<ProctoringNotifier, ProctoringState, String>((ref, submissionId) {
  final notifier = ProctoringNotifier(
    submissionId: submissionId,
    proctoringRepo: ref.watch(proctoringRepositoryProvider),
    examRepo: ref.watch(examRepositoryProvider),
    engine: MediaPipeProctoringService(),
    // Durable delivery: a violation that cannot reach Supabase now is queued and
    // retried rather than dropped (see OfflineSyncService).
    outbox: ref.watch(violationOutboxProvider),
    onForceExit: () => ref.read(forceExitSignalProvider.notifier).state = submissionId,
    // The composition root is the right place to bind Storage; the notifier
    // itself stays free of the Supabase singleton, which keeps it unit-testable
    // with a fake uploader.
    uploadSnapshot: SupabaseService.instance.uploadViolationSnapshot,
  );
  // No `ref.onDispose(notifier.dispose)` here on purpose: Riverpod's
  // StateNotifierProvider already disposes the notifier it created
  // (StateNotifierProviderElement.runOnDispose), so registering it a second
  // time made every exam exit log "Tried to use ProctoringNotifier after
  // dispose was called" and skip the real teardown.
  return notifier;
});

/// Set by the notifier when a disqualification happens; the exam-taking
/// page listens to this and performs navigation + forced logout, keeping
/// Riverpod state changes and Navigator side effects cleanly separated.
final forceExitSignalProvider = StateProvider<String?>((ref) => null);
