import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/exam_lifecycle_observer.dart';
import '../../../../core/services/mediapipe_proctoring_service.dart';
import '../../../../core/services/supabase_service.dart';
import '../../domain/entities/violation.dart';
import '../../domain/repositories/proctoring_repository.dart';
import '../../../exam/domain/repositories/exam_repository.dart';

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

  const ProctoringState({
    this.warningCount = 0,
    this.showViolationOverlay = false,
    this.lastViolation,
    this.disqualified = false,
  });

  ProctoringState copyWith({
    int? warningCount,
    bool? showViolationOverlay,
    ViolationType? lastViolation,
    bool? disqualified,
  }) =>
      ProctoringState(
        warningCount: warningCount ?? this.warningCount,
        showViolationOverlay: showViolationOverlay ?? this.showViolationOverlay,
        lastViolation: lastViolation ?? this.lastViolation,
        disqualified: disqualified ?? this.disqualified,
      );
}

/// Owns the MediaPipe engine + lifecycle observer for one exam session and
/// implements the section-3 escalation contract:
///   - on violation: warningCount += 1, show full-screen overlay, log to DB
///   - at warningCount >= 3: auto-submit as 'disqualified' + forced exit
class ProctoringNotifier extends StateNotifier<ProctoringState> {
  ProctoringNotifier({
    required this.submissionId,
    required this._proctoringRepo,
    required this._examRepo,
    required this._engine,
    required this._onForceExit,
    required this._uploadSnapshot,
    this.snapshotTimeout = const Duration(seconds: 5),
    this.audioNoiseThresholdDb = -25.0,
    this.audioNoiseSustain = const Duration(seconds: 2),
  })  : super(const ProctoringState()) {
    _gazeSub = _engine.signals.listen(_handleGazeSignal);
    // Same entry point the browser guards and the kiosk escape use, so there is
    // exactly one place that decides what "left the exam" means.
    _lifecycleObserver = ExamLifecycleObserver(
      onMinimized: reportAppMinimized,
    )..attach();
  }

  final String submissionId;
  final ProctoringRepository _proctoringRepo;
  final ExamRepository _examRepo;
  final MediaPipeProctoringService _engine;
  final void Function() _onForceExit;
  final SnapshotUploader _uploadSnapshot;

  /// Upper bound on how long a violation waits for its evidence; past this the
  /// log goes out without a picture rather than delaying escalation.
  final Duration snapshotTimeout;

  /// Loudness (dBFS, as reported by plugins such as `noise_meter`) that counts
  /// as suspicious background noise: -25 dBFS is roughly loud speech/shouting.
  final double audioNoiseThresholdDb;

  /// How long the level must stay above [audioNoiseThresholdDb] before it is
  /// logged, so a single door slam does not become a strike.
  final Duration audioNoiseSustain;

  DateTime? _loudSince;

  /// Set by the exam page once the camera is running. Null in mock-camera
  /// sessions (nothing to photograph) and before the camera is ready.
  SnapshotSource? _snapshotSource;

  late final StreamSubscription<GazeSignal> _gazeSub;
  late final ExamLifecycleObserver _lifecycleObserver;

  DateTime? _lastLoggedAt;
  static const _dedupeWindow = Duration(seconds: 2);

  /// Hands over the page's still-frame grabber, so violations can attach
  /// evidence. Call once, right after `startImageStream`.
  void attachSnapshotSource(SnapshotSource capture) {
    _snapshotSource = capture;
  }

  void _handleGazeSignal(GazeSignal signal) {
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

  /// Feeds one amplitude sample from an audio monitor. A level above
  /// [audioNoiseThresholdDb] that is sustained for [audioNoiseSustain] is logged
  /// as `audio_noise`; anything quieter resets the window.
  ///
  /// The audio source is intentionally not bundled (no `noise_meter`
  /// dependency): capturing audio needs a microphone-permission-driven
  /// recording session, so the host app forwards samples here once that plugin
  /// is wired up. This method itself is just a comparison — safe to call per
  /// sample.
  void reportAudioLevel(double decibels) {
    if (decibels < audioNoiseThresholdDb) {
      _loudSince = null;
      return;
    }

    final now = DateTime.now();
    _loudSince ??= now;
    if (now.difference(_loudSince!) >= audioNoiseSustain) {
      // Reset the window so sustained noise re-logs at most once per
      // `audioNoiseSustain` (the 2s dedupe below still applies).
      _loudSince = now;
      reportAudioNoise();
    }
  }

  /// Direct hook for a source that already classifies noise (a plugin with its
  /// own threshold, or a server-side detector).
  void reportAudioNoise() => _registerViolation(ViolationType.audioNoise);

  /// The student left the exam surface: an Android kiosk escape, a browser tab
  /// switch, a window blur, or dropping out of HTML5 fullscreen. All of them are
  /// the same violation — `app_minimized` — so the strike counter, the overlay
  /// and the auto-disqualification rule stay in one place.
  void reportAppMinimized() => _registerViolation(ViolationType.appMinimized);

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
    if (state.disqualified) return; // already ended, ignore stray signals

    // Debounce so one sustained condition doesn't spam multiple identical
    // log rows within the same couple of seconds.
    final now = DateTime.now();
    if (_lastLoggedAt != null && now.difference(_lastLoggedAt!) < _dedupeWindow) {
      return;
    }
    _lastLoggedAt = now;

    // Show the full-screen alert immediately (optimistic UI) — the student
    // must see the warning before any camera/storage/network round-trip.
    state = state.copyWith(
      warningCount: state.warningCount + 1,
      showViolationOverlay: true,
      lastViolation: type,
    );

    // Then collect evidence, time-boxed: a camera that refuses to grab a still
    // (some Android devices do while streaming) or an offline upload must never
    // delay the escalation below.
    final snapshotUrl = await _captureAndUploadSnapshot(type);

    try {
      final result = await _proctoringRepo.logViolation(
        submissionId: submissionId,
        violation: Violation(
          type: type,
          timestamp: now,
          snapshotUrl: snapshotUrl,
        ),
      );

      // Reconcile with the server's authoritative count (source of truth —
      // protects against a client that raced ahead or fell behind).
      state = state.copyWith(warningCount: result.warningCount);

      if (result.disqualified) {
        await _forceDisqualify();
      }
    } catch (_) {
      // Network failure: local count still stands, and the RPC call is
      // idempotent-safe to retry — in production, queue for retry here.
    }
  }

  /// Captures a still frame and stores it in the public `proctor-snapshots`
  /// bucket, returning the URL to attach to the log row.
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

  Future<void> _forceDisqualify() async {
    state = state.copyWith(disqualified: true, showViolationOverlay: true);
    await _examRepo.markDisqualified(submissionId);
    _onForceExit();
  }

  void dismissOverlay() {
    if (state.disqualified) return; // can't dismiss the final lockout screen
    state = state.copyWith(showViolationOverlay: false);
  }

  @override
  void dispose() {
    _gazeSub.cancel();
    _lifecycleObserver.detach();
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

// --- Repository providers -------------------------------------------------
// These are declared here for wiring clarity; in the real project they'd
// live in core/di alongside SupabaseService.instance.client.
final proctoringRepositoryProvider = Provider<ProctoringRepository>((ref) {
  throw UnimplementedError('Override in ProviderScope with ProctoringRepositoryImpl(client)');
});

final examRepositoryProvider = Provider<ExamRepository>((ref) {
  throw UnimplementedError('Override in ProviderScope with ExamRepositoryImpl(client)');
});
