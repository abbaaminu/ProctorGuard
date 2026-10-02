import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
// Only the binding is taken from here: the pointer *events* this page forwards
// to the idle watcher already arrive through Material's re-export, and a bare
// `show` keeps the gesture arena's other names out of this file's scope.
import 'package:flutter/gestures.dart' show GestureBinding;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/di/providers.dart';
import '../../../../core/services/afk_watcher.dart';
import '../../../../core/services/audio_monitor.dart';
import '../../../../core/services/hardware_integrity_service.dart';
import '../../../../core/services/hardware_verification_service.dart';
import '../../../../core/services/kiosk_service.dart';
import '../../../../core/services/mediapipe_proctoring_service.dart';
import '../../../../core/services/offline_sync_service.dart';
import '../../../../core/services/permission_service.dart';
import '../../../../core/services/web_camera_permission.dart';
import '../../../../core/services/web_exam_guard.dart';
import '../../../../core/services/web_guards.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../../proctoring/presentation/providers/audio_monitoring_provider.dart';
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../../proctoring/presentation/widgets/audio_monitor_indicator.dart';
import '../../../proctoring/presentation/widgets/fullscreen_lock_overlay.dart';
import '../../../proctoring/presentation/widgets/violation_overlay.dart';
import '../../domain/entities/question.dart';
import '../widgets/exam_sync_banner.dart';

/// Route arguments: examId + submissionId (submission is created/resumed
/// by ExamRepository *before* navigating here — see exam list page) plus the
/// clock the attempt runs on: `durationMinutes` comes from `exams` and
/// `startedAt` from the submission row, so a resumed session keeps its
/// remaining time instead of restarting.
class ExamTakingPage extends ConsumerStatefulWidget {
  final String examId;
  final String submissionId;

  /// `exams.duration_minutes`. Null (older callers, tests) skips the countdown.
  final int? durationMinutes;

  /// `exam_submissions.started_at`; null counts from "now".
  final DateTime? startedAt;

  /// Browser guards for this session; injectable so tests can drive tab-switch
  /// and fullscreen behaviour on the VM, where the real implementation (and its
  /// DOM) does not exist.
  final WebGuards? webGuards;

  /// Clock the browser-guard timings read: the start-up grace and the fullscreen
  /// countdown. Null means the wall clock, which is what production uses.
  ///
  /// A widget test's fake time does not move `DateTime.now()`, so a test that wants
  /// to watch the countdown run out passes a clock it can move itself.
  final DateTime Function()? clock;

  /// Overrides `--dart-define=MOCK_CAMERA=true` for this session.
  ///
  /// The dart-define is a compile-time constant, so this is what lets a widget
  /// test — or a desktop/CI demo — exercise the *question* half of the screen
  /// without a camera. `null` falls back to the compile-time flag.
  final bool? mockCamera;

  const ExamTakingPage({
    super.key,
    required this.examId,
    required this.submissionId,
    this.durationMinutes,
    this.startedAt,
    this.webGuards,
    this.clock,
    this.mockCamera,
  });

  /// True when this session runs without a camera (simulated violations).
  bool get mockMode =>
      mockCamera ?? MediaPipeProctoringService.mockCameraFromEnvironment;

  @override
  ConsumerState<ExamTakingPage> createState() => _ExamTakingPageState();
}

class _ExamTakingPageState extends ConsumerState<ExamTakingPage> {
  CameraController? _cameraController;

  /// True while the camera is actually streaming frames to the proctoring
  /// engine. Flips to false when the controller reports an error (device
  /// revoked, driver crash) so tracking pauses and the student is prompted
  /// instead of silently accruing strikes against a dead feed.
  bool _cameraStreaming = false;

  List<Question> _questions = [];

  /// Selected option per question id, mirrored locally so a tap paints
  /// immediately — the RPC round-trip is not on the UI's critical path, and the
  /// server copy (what grading reads) is written by [ExamRepository.saveAnswer].
  final Map<String, int> _answers = <String, int>{};

  /// Free-text answers (fill-in-the-blank), keyed by question id. `_savedText`
  /// holds what the server confirmed, so the UI can tell "typed" from "stored"
  /// and only writes when they differ.
  final Map<String, String> _textAnswers = <String, String>{};
  final Map<String, String> _savedText = <String, String>{};

  /// Question ids whose answer the server has confirmed — either shape. Drives
  /// the "N answered" count and the submit dialog's summary.
  final Set<String> _savedQuestions = <String>{};

  /// In-flight guard for a text autosave (one at a time).
  bool _savingText = false;

  int _currentIndex = 0;
  bool _loading = true;

  /// In-flight guard for the bootstrap (see [_bootstrap]).
  ///
  /// A blocking screen's "Try again" button is only rebuilt on the next turn of
  /// the event loop, so a double tap used to start a second session setup on top
  /// of the first: two capture pipelines competing for one lens, and a first
  /// kiosk pin, watcher set and integrity probe that nothing released.
  bool _bootstrapping = false;

  /// Set when the session cannot be proctored at all (permission refused, no
  /// camera) or when the question feed fails to load. Both are blocking states
  /// with a retry, because silently running an unproctored exam is worse than
  /// not starting it.
  String? _blockingError;

  /// True when [_blockingError] is a permission problem the student can fix in
  /// the OS settings, so the blocking screen also offers "Open settings".
  bool _offerSettings = false;

  /// In-flight guard for the final submit (double taps, retry storms).
  bool _submitting = false;

  /// True when the clock ran out but the server has not acknowledged the
  /// submission yet; build() then shows a retry/exit screen instead of silently
  /// dropping the attempt.
  bool _timeUpPending = false;

  /// True when the student asked to submit but the queue still owes the server
  /// answers. Nothing is lost - the answers are on this device (and their field
  /// text says so) - so this is a "waiting for a connection" screen with a retry,
  /// not an error.
  bool _offlineSubmitPending = false;

  /// Local-first answer cache + durable retry queue for this session, read once
  /// in [_bootstrap] (the same instance the notifier logs violations through).
  OfflineSyncService? _sync;

  /// Deadline of the "return to fullscreen" window, or null when fullscreen is
  /// where it should be. The guard owns the deadline; this mirrors it for display.
  DateTime? _fullscreenDeadline;

  /// Cosmetic ticker behind the countdown above (the guard's own timer is what
  /// guarantees the strike).
  Timer? _fullscreenTicker;

  /// Fullscreen grace the page gives the student before the exit is a violation.
  /// The guard gets the same number, so the countdown on screen cannot disagree
  /// with when the strike lands.
  static const Duration fullscreenGrace = Duration(seconds: 5);

  /// The clock the browser-guard timings read (see [ExamTakingPage.clock]).
  DateTime Function() get _now => widget.clock ?? DateTime.now;

  /// Wakes the queue when the OS brings the exam back to the foreground - the
  /// mobile equivalent of the browser's `online` event, and the moment a
  /// connection usually comes back.
  AppLifecycleListener? _appLifecycle;

  /// Time left on the attempt; null when no duration was supplied.
  Duration? _remaining;
  Timer? _countdown;

  /// Screen pinning for this session; the page owns it so the escape poll only
  /// runs while the exam is on screen.
  KioskService? _kiosk;
  StreamSubscription<KioskExitReason>? _kioskEscapes;
  KioskResult? _kioskStatus;

  /// Browser-level guards (tab switch, blur, HTML5 fullscreen) for this session.
  WebExamGuard? _webGuard;

  /// Idle detection for this session: a screen nobody has touched for
  /// [AfkWatcher.defaultIdleThreshold] is an `idle_afk` violation.
  AfkWatcher? _afk;

  /// Whether this session's pointer route is registered on
  /// [GestureBinding.pointerRouter]. Tracked because removing a route that was
  /// never added *asserts* in debug builds: a bootstrap that failed before it got
  /// as far as registering one must still be releasable.
  bool _pointerRouteAttached = false;

  /// Device-integrity probe for this session (a second display, a camera that is
  /// not this device's own lens). Android only - see
  /// [HardwareIntegrityService.isSupportedPlatform].
  HardwareIntegrityService? _integrity;

  @override
  void initState() {
    super.initState();
    // Distinct from the notifier's lifecycle observer, which turns *leaving* into
    // a strike: this one only reacts to coming back.
    _appLifecycle = AppLifecycleListener(onResume: _onAppResumed);
    _bootstrap();
  }

  /// The exam app is in the foreground again: re-assert fullscreen and push
  /// whatever the queue is holding.
  ///
  /// On mobile there is no `online` event to listen to, so this is when a dropped
  /// connection is most likely to be back - and a student who was offline for the
  /// last ten minutes should not have to wait out a backoff timer to find out.
  void _onAppResumed() {
    _webGuard?.reassertFullscreen();
    final sync = _sync;
    if (sync != null) unawaited(sync.retryNow());
  }

  /// Runs the session setup for this attempt, at most once at a time.
  ///
  /// The blocking states all retry through here, and a retry that arrives while
  /// one is already running is dropped rather than queued: the pass in flight is
  /// about to decide what this page shows anyway (see [_bootstrapping]).
  Future<void> _bootstrap() async {
    if (_bootstrapping) return;
    _bootstrapping = true;
    try {
      await _runBootstrap();
    } finally {
      _bootstrapping = false;
    }
  }

  /// The bootstrap itself: the durable cache, the microphone, the browser/kiosk
  /// guards and the integrity probe, then the capture pipeline proctoring runs on.
  Future<void> _runBootstrap() async {
    final notifier = ref.read(proctoringProvider(widget.submissionId).notifier);

    // Local-first: load the durable cache before anything can be painted, so a
    // resumed attempt shows the answers that were typed before the app was killed
    // even when the server is unreachable.
    final sync = ref.read(offlineSyncServiceProvider);
    _sync = sync;
    await sync.ensureHydrated();
    _restoreCachedAnswers(sync);

    // Audio proctoring starts with the session rather than with the camera: it is
    // platform-independent (it works on the web, and in a mock-camera session too)
    // and it never throws, so it is started without being awaited - a permission
    // dialog stays on screen until the student answers it, and the question feed
    // must not be held behind that. Every failure becomes a state the indicator
    // shows and the prompt below offers a way out of.
    unawaited(_startAudioMonitoring());

    // A retry re-runs this method, so whatever the previous attempt pinned or
    // subscribed to is released first — otherwise the platform would get a
    // second lock task request and the DOM a second set of listeners.
    await _releaseKiosk();
    final previousGuard = _webGuard;
    _webGuard = null;
    if (previousGuard != null) await previousGuard.stop();

    // Pin the app first: with lock task on, home, recents and the notification
    // shade are gone, so the exam surface is all the student can interact with.
    // Off Android — or without Device Owner status — this degrades to
    // best-effort screen pinning, and the escape stream below still turns a
    // successful escape into an `app_minimized` violation.
    final kiosk = KioskService();
    _kiosk = kiosk;
    _kioskEscapes = kiosk.escapes.listen((_) => notifier.reportAppMinimized());
    final kioskStatus = await kiosk.startLock();
    if (!kioskStatus.granted) {
      debugPrint('ProctorGuard kiosk: not pinned — ${kioskStatus.message}');
    }
    if (mounted) setState(() => _kioskStatus = kioskStatus);

    // Browser guards — the web counterpart of the lock task above. A Chrome or
    // Edge session is put into HTML5 fullscreen, and a tab switch, a window
    // blur or leaving fullscreen becomes an `app_minimized` violation instead of
    // something nobody notices.
    final webGuard = WebExamGuard(
      guards: widget.webGuards ?? WebGuards(),
      fullscreenGrace: fullscreenGrace,
      clock: widget.clock,
      // Which strike an event costs is a page-level decision, not the guard's:
      // a blur and a copy attempt both arrive here, and only one of them is
      // leaving the exam surface. See [_reportWebGuardEvent].
      onViolation: (event) => _reportWebGuardEvent(notifier, event),
      // Leaving fullscreen is not logged immediately: the student gets the grace
      // window below, and only a window that runs out becomes the strike above.
      onFullscreenExitPending: _startFullscreenCountdown,
      onFullscreenRestored: _endFullscreenCountdown,
    );
    _webGuard = webGuard;
    final fullscreenEntered = await webGuard.start();
    if (webGuard.guards.isSupported && !fullscreenEntered) {
      // Chromium only grants fullscreen from a user gesture, so the automatic
      // attempt can be refused; the prompt's action button is that gesture.
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptFullscreen());
    }

    // Idle detection (`idle_afk`) and device integrity (a second display, a
    // camera that is not this device's own lens) start with the session rather
    // than with the camera: they are about the device and the student, not about
    // the video, so a session whose camera never came up is still watched.
    // Released first, because a retry of this bootstrap must not leave a second
    // watcher running behind the failed attempt's.
    _releaseSessionWatchers();

    final afk = AfkWatcher(onIdle: notifier.reportIdleAfk, clock: widget.clock);
    _afk = afk;
    afk.start();

    // Pointer input is what keeps that idle window quiet. A router *route*
    // rather than a `Listener` widget: this only observes (the exam's own
    // widgets must still act on the tap), and a global route sees the whole
    // surface - the answer options, the text fields, the scroll views, the app
    // bar - without nesting the layout inside a wrapper. Hover and scroll-wheel
    // events are routed here too, so a student reading with a mouse counts as
    // present exactly as a touch does; keys are [AfkWatcher]'s own business.
    if (!_pointerRouteAttached) {
      _pointerRouteAttached = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerActivity);
    }

    // Android is the only platform with a native half for this probe; anywhere
    // else it answers "cannot see", and an unanswered probe is silence rather
    // than an accusation ([HardwareIntegrityService]).
    //
    // Mock sessions are exempt on purpose: `--dart-define=MOCK_CAMERA=true` runs
    // on an emulator or a desktop by definition, where the camera *is*
    // synthesised - which is an integrity finding on its own - and there is no
    // student lens to judge.
    if (!widget.mockMode && HardwareIntegrityService.isSupportedPlatform) {
      final integrity = HardwareIntegrityService();
      _integrity = integrity;
      integrity.startMonitoring(
        onFinding: (finding) => _reportIntegrityFinding(notifier, finding),
        // Read per probe, not captured: only the camera controller can name the
        // lens in use, and it does not exist until the capture pipeline below
        // has started.
        cameraId: _cameraInUse,
      );
    }

    if (widget.mockMode) {
      // MOCK_CAMERA=true: emulators, desktops and CI runners have no usable
      // front camera, so skip the capture pipeline entirely. The engine emits
      // simulated violations on a timer, and no snapshot source is attached —
      // there is nothing to photograph, so those logs carry no image URL.
      await _loadQuestions();
      _startCountdown();
      return;
    }

    // Real proctoring needs a camera *and* a microphone, so both are checked
    // before either is opened: a denied permission used to surface as an
    // unhandled CameraException that left the page on its loading spinner with
    // no way out (the exam screen has no back button by design). Web/desktop are
    // skipped here — `permission_handler` cannot report a status there, and the
    // browser probe below plus the camera plugin are what ask for access.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final report = await PermissionService().checkCritical();
      if (report.denied.isNotEmpty) {
        _offerSettings = true;
        _failStart(
          'This exam needs ${report.deniedLabel} access. Grant it in your '
          'device settings, then tap Try again.',
        );
        return;
      }
      if (report.unknown.isNotEmpty) {
        // Could not read the status (a plugin that stayed silent, a platform
        // without the permission): keep going and let the camera plugin report
        // the real refusal, instead of blocking a device that is fine.
        debugPrint(
          'ProctorGuard: could not confirm ${_permissionLabel(report.unknown)} '
          'access — continuing with the camera plugin.',
        );
      }
    }

    // Front camera, low resolution is enough for face detection and keeps the
    // CameraImage stream cheap at 5–8 FPS inference.
    final List<CameraDescription> cameras;
    try {
      cameras = await _resolveCameras();
    } on CameraException catch (error) {
      _failStart(
        'Proctoring cannot start — ${cameraFailureMessage(error.code)}. Close '
        'anything else using the camera or microphone, then tap Try again.',
      );
      return;
    } catch (error) {
      debugPrint('ProctorGuard: camera enumeration failed: $error');
      _failStart('The camera could not be opened on this device.');
      return;
    }

    if (cameras.isEmpty) {
      _failStart(
        kIsWeb
            ? 'No camera is available. Allow camera access for this site in your '
              'browser (and check the device has one), then tap Try again.'
            : 'No camera is available on this device. Proctoring needs a working '
              'front camera.',
      );
      return;
    }

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(
      front,
      ResolutionPreset.low,
      // The microphone is part of the exam rather than an optional extra: this
      // opens the audio capture session alongside the video one, so the session
      // really holds the mic (RECORD_AUDIO on Android, the browser's mic grant on
      // web) for as long as the attempt lasts.
      enableAudio: true,
      imageFormatGroup: proctorImageFormatGroup(),
    );
    // Every step below can fail on a real device (another app holding the
    // camera, an OEM driver quirk, a permission revoked mid-session), so the
    // whole capture pipeline reports itself instead of throwing.
    try {
      await _cameraController!.initialize();
      // Watch the controller so a mid-session failure (device revoked, driver
      // crash) pauses proctoring and prompts the student rather than letting
      // the engine read the dead feed as "no face".
      _cameraController!.addListener(_onCameraValueChanged);

      // Route every frame through the face-detection engine owned by the
      // proctoring notifier for this session. The engine needs the camera's
      // sensor orientation (to upright frames) and the live device orientation.
      notifier.engineAttachCamera(front);
      // Violation evidence: the notifier pulls a still frame from here whenever
      // it logs something, then uploads it to the proctor-snapshots bucket.
      notifier.attachSnapshotSource(_captureSnapshot);
      await _cameraController!.startImageStream((image) {
        notifier.engineOnFrame(
          image,
          deviceOrientation: _cameraController!.value.deviceOrientation,
        );
      });
      // Frames are flowing: hand camera-derived tracking to the engine.
      _setCameraStreaming(true);
    } on CameraException catch (error) {
      _failStart(
        'Proctoring cannot start — ${cameraFailureMessage(error.code)}. Close '
        'anything else using the camera or microphone, then tap Try again.',
      );
      return;
    } catch (error) {
      debugPrint('ProctorGuard: camera pipeline failed: $error');
      _failStart('Proctoring could not start on this device.');
      return;
    }

    await _loadQuestions();
    _startCountdown();
  }

  /// Paints the answers this device already holds for the attempt.
  ///
  /// A resumed session (crash, refresh, an offline stretch) gets its answers back
  /// before the server is asked anything, and `putIfAbsent` means a retry of
  /// [_bootstrap] can never overwrite what the student has changed since.
  void _restoreCachedAnswers(OfflineSyncService sync) {
    final choices = sync.cachedChoices(widget.submissionId);
    final texts = sync.cachedText(widget.submissionId);
    if ((choices.isEmpty && texts.isEmpty) || !mounted) return;

    setState(() {
      choices.forEach((id, value) => _answers.putIfAbsent(id, () => value));
      texts.forEach((id, value) {
        _textAnswers.putIfAbsent(id, () => value);
        // "Saved" here means durably stored on this device; the queue owns the
        // server copy, and the banner is what reports that part. Hiding a restored
        // answer behind "Not saved yet" would tell the student their typing was
        // lost when it was not.
        _savedText.putIfAbsent(id, () => value);
      });
      _savedQuestions.addAll(choices.keys);
      _savedQuestions.addAll(texts.keys);
    });
  }

  /// Shows the blocking "return to fullscreen" overlay and starts its countdown.
  ///
  /// Called by the guard the moment fullscreen ends; no violation has been logged
  /// at this point, and the only way to avoid one is to come back.
  void _startFullscreenCountdown() {
    if (!mounted) return;
    _fullscreenTicker?.cancel();
    setState(() => _fullscreenDeadline = _now().add(fullscreenGrace));

    _fullscreenTicker = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _tickFullscreenCountdown(),
    );
  }

  void _tickFullscreenCountdown() {
    final deadline = _fullscreenDeadline;
    if (!mounted || deadline == null) return;

    if (_now().isBefore(deadline)) {
      setState(() {}); // repaint the remaining seconds
      return;
    }

    // Out of time: hand it to the guard, which logs the `app_minimized` strike
    // exactly once (its own timer is the backstop for a page that never ticks),
    // then take the overlay down so the violation overlay is what the student
    // reads next.
    _webGuard?.expireFullscreenGrace();
    _endFullscreenCountdown();
  }

  /// Hides the overlay: either the student returned to fullscreen inside the grace
  /// window, or the window ran out and became a strike.
  void _endFullscreenCountdown() {
    _fullscreenTicker?.cancel();
    _fullscreenTicker = null;
    if (!mounted) {
      _fullscreenDeadline = null;
      return;
    }
    setState(() => _fullscreenDeadline = null);
  }

  /// Ends the bootstrap in the blocking-error state (see [_blockingError]).
  void _failStart(String message) {
    // Released through the same path as the session teardown: a device asked to
    // stop a stream that never started (or that has already ended) answers with
    // an async error, and it must not escape a screen the student is looking at.
    final camera = _cameraController;
    _cameraController = null;
    if (camera != null) {
      camera.removeListener(_onCameraValueChanged);
      unawaited(_releaseCamera(camera));
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _blockingError = message;
    });
  }

  /// Releases one capture session: stop the frames, then dispose the controller.
  ///
  /// Every step is contained, because this only ever runs on the way *out* - of a
  /// failed start or of the whole attempt. The order is what Android needs: the
  /// lens is only handed back once the image stream is closed, and `dispose()`
  /// does not wait for that itself, so a session that skipped the stop could
  /// leave the next exam (or another app) with a camera that reports "in use".
  static Future<void> _releaseCamera(CameraController camera) async {
    try {
      // Guarded as well as caught: `stopImageStream()` throws when no stream is
      // running, which is the normal state of a controller that just failed.
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } catch (error) {
      debugPrint('ProctorGuard: stopping the camera stream failed: $error');
    }
    try {
      await camera.dispose();
    } catch (error) {
      debugPrint('ProctorGuard: releasing the camera failed: $error');
    }
  }

  /// Camera controller listener: pausing on error, resuming once frames flow
  /// again. A feed that reports `hasError` no longer gets read as "no face", and
  /// a recovered stream re-arms proctoring with fresh grace windows.
  void _onCameraValueChanged() {
    final controller = _cameraController;
    if (controller == null) return;
    final value = controller.value;

    if (value.hasError) {
      _setCameraStreaming(false);
    } else if (_cameraStreaming == false &&
        value.isInitialized &&
        value.isStreamingImages) {
      _setCameraStreaming(true);
    }
  }

  /// Keeps [_cameraStreaming] and the notifier's camera gate in sync.
  ///
  /// Going offline pauses camera-derived violation tracking (see
  /// [ProctoringNotifier.setCameraActive]) and tells the student why, so a
  /// broken feed cannot quietly accumulate disqualification flags. Mock sessions
  /// never reach here (no camera is opened) and keep tracking on.
  void _setCameraStreaming(bool streaming) {
    if (_cameraStreaming == streaming) return;
    _cameraStreaming = streaming;
    if (!mounted) return;

    ref
        .read(proctoringProvider(widget.submissionId).notifier)
        .setCameraActive(streaming);

    if (!streaming) {
      _showMessage(
        'Camera feed lost. Proctoring is paused - restore the camera to keep '
        'your attempt.',
      );
    }
  }

  /// Opens the microphone capture session for this attempt (see [AudioMonitor]).
  ///
  /// Idempotent: [AudioMonitor.start] is a no-op while levels are already flowing,
  /// so every bootstrap - including the retry after a blocking error - can call it
  /// without stacking a second session.
  Future<void> _startAudioMonitoring() async {
    if (!mounted) return;
    await ref
        .read(audioMonitoringProvider(widget.submissionId).notifier)
        .start();
  }

  /// Re-opens the microphone: the student tapped the indicator, or came back from
  /// the OS settings page.
  ///
  /// Recalibrates from scratch, because a microphone that was just unplugged and
  /// plugged back in - or a student who moved rooms - is a new noise floor, and the
  /// old one would either deafen or over-sensitise the detector.
  Future<void> _retryAudioMonitoring() async {
    if (!mounted) return;
    await ref
        .read(audioMonitoringProvider(widget.submissionId).notifier)
        .retry();
  }

  /// Tells the student that audio proctoring needs them, with the one action that
  /// fixes it.
  ///
  /// Only a refusal and a lost device prompt: those are the two states the student
  /// can act on, and the requirement is that a disconnected microphone is a
  /// visible, answerable prompt rather than a silent gap in proctoring.
  /// `unavailable` (no capture path on this platform, a desktop without a
  /// microphone) stays on the indicator - nagging a device that cannot report
  /// levels would be noise.
  void _promptAudioAttention(AudioMonitoringState state) {
    if (!mounted) return;
    final denied = state.monitor == AudioMonitorState.permissionDenied;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content:
              Text(state.message ?? 'Audio proctoring needs your attention.'),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            // A refusal cannot be fixed by asking again (Android and iOS stop
            // prompting after two "don't allow"s), so that state gets the settings
            // page instead of a retry - the same split the blocking screen makes.
            label: denied ? 'Settings' : 'Reconnect',
            onPressed: () => denied
                ? unawaited(PermissionService().openSettings())
                : unawaited(_retryAudioMonitoring()),
          ),
        ),
      );
  }

  /// "camera and microphone", for the permission message above.
  static String _permissionLabel(List<StartupPermission> missing) =>
      missing.map((permission) => permission.name).join(' and ');

  // `proctorImageFormatGroup()` now lives in `hardware_verification_service.dart`,
  // so the pre-exam gate and this screen agree on the format ML Kit can read.

  /// The camera list for this platform, asking the browser for access first when
  /// it has not been granted yet.
  ///
  /// `camera_web` enumerates with `navigator.mediaDevices.enumerateDevices()` and
  /// drops every device whose `deviceId` is empty — which is exactly what a
  /// browser reports *before* the camera grant. A web session therefore sees an
  /// empty list although devices obviously exist, and used to fall back to "no
  /// camera available". One `getUserMedia` probe (see [WebCameraPermission])
  /// unlocks enumeration, then this asks again.
  Future<List<CameraDescription>> _resolveCameras() async {
    final cameras = await availableCameras();
    if (cameras.isNotEmpty || !kIsWeb) return cameras;

    final probe = WebCameraPermission();
    if (!probe.isSupported) return cameras;

    debugPrint(
      'ProctorGuard: no camera visible yet — asking the browser for access.',
    );
    if (!await probe.ensureAccess()) return cameras;

    return availableCameras();
  }

  // `cameraFailureMessage()` now lives in `hardware_verification_service.dart`:
  // the gate and the session screen word a refused camera identically.

  Future<void> _loadQuestions() async {
    try {
      final questions =
          await ref.read(examRepositoryProvider).getQuestions(widget.examId);
      if (!mounted) return;
      setState(() {
        _questions = questions;
        if (_currentIndex >= questions.length) _currentIndex = 0;
        _loading = false;
      });
    } catch (error) {
      // Previously an unhandled async error: the page stayed on its spinner
      // forever, and the exam screen has no back button to escape with.
      debugPrint('ProctorGuard: could not load questions: $error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _blockingError = 'Could not load the questions for this exam. Check '
            'your connection and tap Try again.';
      });
    }
  }

  /// Enforces `exams.duration_minutes`.
  ///
  /// The deadline is anchored on the submission's `started_at` rather than
  /// "now", so a resumed attempt (crash, refresh, reconnect) keeps counting
  /// down from where it left off — and one that is already past its deadline is
  /// submitted on the first tick instead of being given a fresh hour.
  void _startCountdown() {
    final minutes = widget.durationMinutes;
    if (minutes == null || minutes <= 0) return;

    // Anchored and read through the page clock (see [ExamTakingPage.clock]) - the
    // same clock the fullscreen window counts on, so the two timings on this
    // screen cannot disagree about how much of the hour is gone.
    final deadline =
        (widget.startedAt ?? _now()).add(Duration(minutes: minutes));

    _countdown?.cancel();
    // The ticker is installed *before* the first tick: that tick is what submits
    // an attempt which resumes past its deadline, and it cancels the ticker it
    // finds. Creating the ticker afterwards used to re-arm the submission once a
    // second for as long as the page stayed on screen.
    _countdown = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(deadline),
    );
    _tickCountdown(deadline);
  }

  void _tickCountdown(DateTime deadline) {
    if (!mounted) return;

    final remaining = deadline.difference(_now());
    setState(() => _remaining = remaining.isNegative ? Duration.zero : remaining);

    if (!remaining.isNegative && remaining != Duration.zero) return;

    // Time is up: submit without asking. `submit_exam` is idempotent, so a
    // double fire (a slow tick while the first call is in flight) is harmless.
    _countdown?.cancel();
    _countdown = null;
    unawaited(_finalSubmit(timeUp: true));
  }

  /// Grabs a still frame as violation evidence, or null when the camera can't
  /// provide one at this moment (some Android devices refuse `takePicture`
  /// while an image stream is running) — the violation is logged either way.
  Future<Uint8List?> _captureSnapshot() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;

    try {
      final shot = await controller.takePicture();
      return shot.readAsBytes();
    } on CameraException {
      return null;
    }
  }

  /// Tells the student that secure fullscreen is required, and gives them the
  /// tap Chromium needs before it will grant it.
  void _promptFullscreen() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Fullscreen is required for this exam.'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Enter',
            onPressed: () => _webGuard?.requestFullscreen(),
          ),
        ),
      );
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _countdown = null;
    _fullscreenTicker?.cancel();
    _fullscreenTicker = null;
    _appLifecycle?.dispose();
    _appLifecycle = null;
    // Detached before it is released: a teardown in flight must not find a
    // controller this page still calls "the camera" (see [_releaseCamera]).
    final camera = _cameraController;
    _cameraController = null;
    if (camera != null) {
      camera.removeListener(_onCameraValueChanged);
      // Not awaited - `dispose()` cannot be - and fully contained, so no error
      // out of a dying capture session can reach the zone as unhandled.
      unawaited(_releaseCamera(camera));
    }

    // Unpin before releasing the bridge: `stopLock` tells the platform the exit
    // is intentional, so finishing the exam is not logged as an escape.
    unawaited(_releaseKiosk());

    // And the same for this session's watchers: the idle window and the
    // integrity poll belong to the attempt that just ended, so neither may
    // survive it (a strike logged from a closed exam would land on nobody).
    _releaseSessionWatchers();

    // Same idea in the browser: leave fullscreen and drop the DOM listeners, so
    // a finished exam neither traps the student nor keeps counting strikes.
    final webGuard = _webGuard;
    _webGuard = null;
    if (webGuard != null) unawaited(webGuard.stop());

    super.dispose();
  }

  /// Releases the kiosk pin and its escape subscription. Called by [dispose] and
  /// at the start of [bootstrap] so a retry cannot stack a second pin.
  Future<void> _releaseKiosk() async {
    // Cancelling the escape subscription is deliberately not awaited: dropping
    // the subscription is what matters, while a teardown future the platform
    // stream may never complete (the controller lives until dispose) must not be
    // able to hold up the exam bootstrap or a retry of it.
    unawaited(_kioskEscapes?.cancel());
    _kioskEscapes = null;

    final kiosk = _kiosk;
    _kiosk = null;
    if (kiosk == null) return;

    await kiosk.stopLock();
    kiosk.dispose();
  }

  /// Releases the idle watcher and the device-integrity probe.
  ///
  /// Called by [dispose] and at the start of [_bootstrap]: a retry of the
  /// bootstrap re-runs the whole session setup, so without this the watcher the
  /// failed attempt started would keep its timer - and its key handler - behind
  /// the session that replaced it. Both are idempotent, so releasing a session
  /// that never started one is harmless.
  void _releaseSessionWatchers() {
    _afk?.stop();
    _afk = null;
    // Guarded: this also runs for a bootstrap that never reached the
    // registration below, and `removeGlobalRoute` asserts on a route it does not
    // know (see [_pointerRouteAttached]).
    if (_pointerRouteAttached) {
      _pointerRouteAttached = false;
      GestureBinding.instance.pointerRouter
          .removeGlobalRoute(_onPointerActivity);
    }
    _integrity?.stopMonitoring();
    _integrity = null;
  }

  /// Any pointer event - a tap, a drag, a hover, a scroll - is somebody at the
  /// device, which is what keeps [AfkWatcher] quiet. Registered while the
  /// attempt runs; see [_bootstrap].
  void _onPointerActivity(PointerEvent event) => _afk?.noteActivity();

  /// The id of the camera actually feeding this attempt, or null while the
  /// capture pipeline is still coming up.
  ///
  /// Android's integrity probe uses it to be exact about *which* lens is being
  /// judged: one known to be external is a stronger finding than one merely
  /// attached. It is read on every probe rather than handed over once, so a
  /// session that re-opens its camera is judged by the lens it is using now
  /// (see [HardwareIntegrityService.startMonitoring]).
  String? _cameraInUse() => _cameraController?.description.name;

  /// Turns one browser-guard event into the violation it is evidence of.
  ///
  /// The guard knows *that* something happened; which strike it costs depends on
  /// what it was, and that is a page-level mapping because one callback carries
  /// two different families of events: leaving the exam surface (a tab switch, a
  /// window blur, a fullscreen exit whose countdown ran out) is
  /// `app_minimized`, while the lockdown's own events - a refused copy, cut or
  /// paste, a suppressed context menu, a developer-tools panel - are the
  /// attempts themselves, and each has its own violation type on the server.
  void _reportWebGuardEvent(ProctoringNotifier notifier, WebGuardEvent event) {
    switch (event) {
      case WebGuardEvent.tabHidden:
      case WebGuardEvent.windowBlurred:
      case WebGuardEvent.fullscreenExited:
        notifier.reportAppMinimized();
      case WebGuardEvent.copyBlocked:
      case WebGuardEvent.cutBlocked:
      case WebGuardEvent.pasteBlocked:
        // Three DOM events, one behaviour: the student tried to move content
        // through the clipboard.
        notifier.reportCopyPasteAttempt();
      case WebGuardEvent.contextMenuBlocked:
        notifier.reportRightClickBlocked();
      case WebGuardEvent.devtoolsDetected:
        notifier.reportDevtoolsDetected();
      case WebGuardEvent.fullscreenEntered:
        // Bookkeeping: it closes a pending countdown and is never a strike (the
        // guard never routes it here either).
        break;
    }
  }

  /// Turns one device-integrity finding into its violation: a second display is
  /// `secondary_display_detected`, a camera that is not this device's own lens is
  /// `virtual_camera_detected`.
  ///
  /// The service reports a finding when it appears rather than while it lasts
  /// (see [HardwareIntegrityService.startMonitoring]), so this is a straight
  /// mapping and needs no dedupe of its own.
  void _reportIntegrityFinding(
    ProctoringNotifier notifier,
    HardwareFinding finding,
  ) {
    switch (finding) {
      case HardwareFinding.secondaryDisplay:
        notifier.reportSecondaryDisplayDetected();
      case HardwareFinding.virtualCamera:
        notifier.reportVirtualCameraDetected();
    }
  }

  /// Retry for the blocking states: re-runs only the stage that failed, so a
  /// camera that is already streaming (and the kiosk pin that came with it) is
  /// never reopened.
  Future<void> _retryBootstrap() async {
    setState(() {
      _blockingError = null;
      _offerSettings = false;
      _loading = true;
    });

    if (_cameraController == null && !widget.mockMode) {
      await _bootstrap();
      return;
    }

    await _loadQuestions();
    _startCountdown();
  }

  Future<void> _selectAnswer(int optionIndex) async {
    final question = _questions[_currentIndex];

    // Paint first: nothing below is allowed to gate the tap feedback.
    setState(() => _answers[question.id] = optionIndex);

    try {
      // Local first: this resolves once the answer is durable on the device, so a
      // dropped connection no longer costs the student the choice they just made.
      await _persistChoice(question.id, optionIndex);
    } catch (error) {
      // Only reachable without a queue (see [_persistChoice]). Grading reads the
      // *server* copy, so stay on the question instead of advancing past the only
      // chance to save it.
      debugPrint('ProctorGuard: answer autosave failed: $error');
      _showMessage(
        'Could not save that answer. Check your connection and tap your choice '
        'again.',
      );
      return;
    }

    if (!mounted) return;
    setState(() {
      _savedQuestions.add(question.id);
      if (_currentIndex < _questions.length - 1) _currentIndex++;
    });
  }

  /// Durable write for a multiple-choice answer.
  ///
  /// The queue is the normal path: it stores the answer locally and syncs it in
  /// the background, reporting a failure through the banner instead of throwing.
  /// Without one (a host that wired no offline layer) this is the old
  /// straight-to-SQL call, whose failure is again shown to the student.
  Future<void> _persistChoice(String questionId, int optionIndex) {
    final sync = _sync;
    if (sync == null) {
      return ref.read(examRepositoryProvider).saveAnswer(
            submissionId: widget.submissionId,
            questionId: questionId,
            selectedOption: optionIndex,
          );
    }
    return sync.cacheChoice(
      submissionId: widget.submissionId,
      questionId: questionId,
      selectedOption: optionIndex,
    );
  }

  /// Durable write for a fill-in-the-blank answer: "Save & next", the keyboard's
  /// done action, and the flush before submitting all go through here.
  Future<void> _persistText(String questionId, String text) {
    final sync = _sync;
    if (sync == null) {
      return ref.read(examRepositoryProvider).saveTextAnswer(
            submissionId: widget.submissionId,
            questionId: questionId,
            answer: text,
          );
    }
    return sync.cacheText(
      submissionId: widget.submissionId,
      questionId: questionId,
      text: text,
    );
  }

  /// Mirrors a keystroke into the local cache, with **no** network write: an
  /// answer that is still being typed has to survive the app being killed too, but
  /// the server does not need every character.
  void _cacheDraftText(String questionId, String value) {
    _textAnswers[questionId] = value;
    _sync?.cacheTextDraft(
      submissionId: widget.submissionId,
      questionId: questionId,
      text: value,
    );
  }

  /// Saves the current free-text answer through the local-first queue.
  ///
  /// Returns whether the answer is now durable. [advance] moves to the next
  /// question *after* the local write, so a failure (no queue and no network) still
  /// keeps the student on the question with their text intact.
  Future<bool> _saveTextAnswer(Question question, {bool advance = false}) async {
    if (_savingText || !mounted) return false;

    final text = _textAnswers[question.id] ?? '';
    setState(() => _savingText = true);

    try {
      await _persistText(question.id, text);
    } catch (error) {
      debugPrint('ProctorGuard: text answer save failed: $error');
      if (!mounted) return false;
      setState(() => _savingText = false);
      _showMessage(
        'Could not save that answer. Check your connection and tap Save again.',
      );
      return false;
    }

    if (!mounted) return false;
    setState(() {
      _savingText = false;
      _savedText[question.id] = text;
      _savedQuestions.add(question.id);
      if (advance && _currentIndex < _questions.length - 1) _currentIndex++;
    });
    return true;
  }

  /// Writes the current fill-in-the-blank answer if the cache does not have it
  /// yet. Called before navigating away and before closing the attempt: grading
  /// reads the server copy, and the queue is what gets it there.
  Future<bool> _flushTextAnswer() async {
    if (!mounted) return true;

    final question = _questions[_currentIndex];
    if (!question.isFillInTheBlank) return true;

    final text = _textAnswers[question.id] ?? '';
    if (_savedText[question.id] == text) return true;
    return _saveTextAnswer(question);
  }

  /// Moves to [index], persisting the current text answer first.
  Future<void> _goTo(int index) async {
    if (index < 0 || index >= _questions.length) return;
    await _flushTextAnswer();
    if (!mounted) return;
    setState(() => _currentIndex = index);
  }

  /// Closes the attempt. `timeUp` is the countdown's path: no confirmation
  /// dialog (the clock already decided) and a retry screen if the server is
  /// unreachable.
  Future<void> _finalSubmit({bool timeUp = false}) async {
    if (_submitting || !mounted) return;

    if (!timeUp) {
      final confirmed = await _confirmSubmit();
      if (confirmed != true || !mounted) return;

      // Only close the attempt once the last typed answer is durable: grading
      // reads the server copy, so submitting without it would drop it silently.
      if (!await _flushTextAnswer()) return;
    } else {
      // The clock decides, so submission wins over a failed save - but still try
      // once, because a fill-in-the-blank field is normally the only unsaved
      // thing on screen.
      await _flushTextAnswer();
    }

    // Everything the student typed is on the device by now; make sure it is on the
    // server before the attempt closes. A queue that cannot drain means the
    // network is gone (or the last retry is still in flight), and nothing the
    // student typed is lost by *not* submitting yet.
    if (!await _drainedBeforeSubmit(timeUp: timeUp)) return;

    setState(() => _submitting = true);
    try {
      // `submit_exam` grades on the server and is idempotent, so a retry after a
      // dropped connection is safe.
      await ref.read(examRepositoryProvider).submitExam(widget.submissionId);
      if (!mounted) return;
      _countdown?.cancel();
      _countdown = null;
      // The server owns the answers now, so the drafts for this attempt are only
      // clutter. Queued violations are deliberately kept (see clearSession).
      await _sync?.clearSession(widget.submissionId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      debugPrint('ProctorGuard: submit failed: $error');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _timeUpPending = timeUp;
        _offlineSubmitPending = !timeUp;
      });
      if (!timeUp) {
        _showMessage(
          'Could not submit your exam. Check your connection and try again.',
        );
      }
    }
  }

  /// Returns whether it is safe to close the attempt, holding it back otherwise.
  ///
  /// The hold is not an error state: the answers are already durable locally, so
  /// the student sees "waiting for a connection" with a retry (and can leave - the
  /// attempt stays `ongoing` and its answers are still on the device when they
  /// come back).
  Future<bool> _drainedBeforeSubmit({required bool timeUp}) async {
    final sync = _sync;
    if (sync == null) return true; // no queue: nothing to drain

    await sync.flush();
    // Only *answers* hold the attempt open: grading reads the server's copy of
    // them. A queued violation is delivered - and still counted - after the
    // attempt closes, so blocking an otherwise finished student on evidence
    // delivery would let one log row the server refuses strand them for good
    // (see [SyncState.hasPendingAnswers]).
    if (!sync.state.hasPendingAnswers) {
      await _drainViolationsBeforeClose(sync);
      return true;
    }
    if (!mounted) return false;

    setState(() {
      _submitting = false;
      _timeUpPending = timeUp;
      _offlineSubmitPending = !timeUp;
    });
    return false;
  }

  /// One last, backoff-free push of the violation queue, while the session screen
  /// is still alive to make it.
  ///
  /// `register_violation` counts a log that arrives after the attempt closed, so
  /// this is not about the window about to end - it is about the queue's own
  /// durability. The retry backoff and the queue's timers only run while the app
  /// runs, and the student's next move is to close the exam (possibly the app):
  /// whatever `flush()` above could not place - the pass before it may have given
  /// up after [OfflineSyncService.maxPassFailures] rows - would then wait for the
  /// next launch to be delivered, i.e. possibly never. `retryNow()` drops the
  /// backoff for this one attempt at the network.
  ///
  /// It is deliberately best-effort: evidence that cannot be delivered is a
  /// weaker console signal, but it is not the student's to fix and no retry the
  /// student can perform would change it, which is why the hold above is on
  /// answers only.
  Future<void> _drainViolationsBeforeClose(OfflineSyncService sync) async {
    final queued = sync.state.pendingViolations;
    if (queued == 0) return;

    await sync.retryNow();

    final left = sync.state.pendingViolations;
    if (left > 0) {
      // Never silently: this is the one proctoring signal that can be missing
      // from a closed attempt's audit, and a support engineer has to be able to
      // see that it was the connection and not the session.
      debugPrint(
        'ProctorGuard: $left of $queued proctoring log(s) still queued as the '
        'attempt closes - they will be delivered on the next connection.',
      );
    }
  }

  /// The "waiting for a connection" screen's retry: drain the queue and, when it
  /// is empty, go straight back to submitting (no second confirmation dialog -
  /// the student already asked).
  Future<void> _retryOfflineSubmit() async {
    setState(() {
      _offlineSubmitPending = false;
      _submitting = false;
    });

    final sync = _sync;
    if (sync != null) await sync.flush();
    if (!mounted) return;

    if (sync != null && sync.state.hasPendingAnswers) {
      setState(() => _offlineSubmitPending = true);
      _showMessage(
        'Still offline - your answers are safe on this device. Reconnect and '
        'tap Submit again.',
      );
      return;
    }

    await _finalSubmit();
  }

  Future<bool?> _confirmSubmit() => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Submit your exam?'),
          content: Text(
            'You have answered ${_savedQuestions.length} of '
            '${_questions.length} questions. Submitting closes the attempt for '
            'good.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep working'),
            ),
            FilledButton(
              key: const Key('exam-submit-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Submit'),
            ),
          ],
        ),
      );

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
  }

  @override
  Widget build(BuildContext context) {
    final proctoringState = ref.watch(proctoringProvider(widget.submissionId));

    // The app-wide offline queue: the banner renders its state, and watching it
    // here is also what keeps the instance the notifier logs violations through.
    final sync = ref.watch(offlineSyncServiceProvider);

    // A disqualification ends the session server-side; the overlay explains it
    // and its Exit button pops the route. All this listener has to do is stop
    // the clock and clear the signal, so it cannot leak into a later exam.
    ref.listen<String?>(forceExitSignalProvider, (prev, next) {
      if (next != widget.submissionId) return;
      _countdown?.cancel();
      _countdown = null;
      ref.read(forceExitSignalProvider.notifier).state = null;
    });

    // Audio proctoring for this attempt. Watching it is what keeps the
    // `autoDispose` microphone session alive for as long as the exam screen is
    // (see `audioMonitoringProvider`); the question pane's header renders it.
    final audioState = ref.watch(audioMonitoringProvider(widget.submissionId));

    // A refusal or a lost device is announced once per transition, so a microphone
    // that goes away mid-exam prompts the student instead of leaving a silent hole
    // in proctoring. Listening to the *change* is what keeps it once - the
    // optimistic rebuilds that follow all report the same state.
    ref.listen<AudioMonitoringState>(
      audioMonitoringProvider(widget.submissionId),
      (previous, next) {
        if (previous?.monitor == next.monitor) return;
        if (next.monitor == AudioMonitorState.permissionDenied ||
            next.monitor == AudioMonitorState.interrupted) {
          _promptAudioAttention(next);
        }
      },
    );

    // --- Blocking states (each one offers a way out) --------------------
    final blockingError = _blockingError;
    if (blockingError != null) {
      return _BlockingState(
        message: blockingError,
        onRetry: _retryBootstrap,
        // Only a permission failure can be fixed in the OS settings, so the
        // extra action appears exactly then.
        onOpenSettings: _offerSettings
            ? () => PermissionService().openSettings()
            : null,
        allowExit: true,
      );
    }

    if (_timeUpPending) {
      return _BlockingState(
        key: const Key('exam-time-up'),
        icon: Icons.timer_off_outlined,
        title: 'Time is up',
        message: 'Your answers are saved, but the submission has not reached '
            'the server yet.',
        onRetry: () => _finalSubmit(timeUp: true),
        retryLabel: 'Send again',
        allowExit: true,
      );
    }

    if (_offlineSubmitPending) {
      return _BlockingState(
        key: const Key('exam-offline-submit'),
        icon: Icons.cloud_off,
        title: 'Waiting for a connection',
        message: 'Every answer is saved on this device, so nothing is lost. '
            'Reconnect to hand the attempt in - it will go through as soon as '
            'the answers reach the server.',
        onRetry: _retryOfflineSubmit,
        retryLabel: 'Submit again',
        allowExit: true,
      );
    }

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_questions.isEmpty) {
      // No questions is a supervisor's setup mistake, not a used-up attempt:
      // leaving keeps the submission `ongoing` so it can be resumed once the
      // questions are published.
      return _BlockingState(
        key: const Key('exam-no-questions'),
        icon: Icons.help_outline,
        title: 'No questions yet',
        message: 'This exam has no questions published yet. Tell your '
            'supervisor — you can come back once they are added.',
        allowExit: true,
      );
    }

    final question = _questions[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        // Explicit numbering on every question, both shapes: "Question 3 of 5".
        title: Text('Question ${_currentIndex + 1} of ${_questions.length}'),
        automaticallyImplyLeading: false, // no manual exit mid-exam
        // Only the clock stays here: the question number plus three chips
        // overflow a 360 dp phone's app bar. The answered count and the kiosk
        // badge moved into the question pane's header, where they wrap instead.
        actions: [
          if (_remaining != null) _RemainingChip(remaining: _remaining!),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Breakpoint off the *actual* box, not the window: inside a
                // split view or a resized browser window this is what matters.
                final wide = constraints.maxWidth >= Breakpoints.expanded;
                final gutter = ResponsiveSizing.horizontalPadding(context);
                final questionPane = _buildQuestionPane(question, audioState);

                return Column(
                  children: [
                    // Above the question, so "your work is safe, it just has not
                    // reached the server yet" is the first thing on screen.
                    ExamSyncBanner(service: sync),
                    Expanded(
                      child: wide
                          // Desktop / tablet landscape: the self-view sits
                          // beside the question instead of on top of it.
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: questionPane),
                                Padding(
                                  padding:
                                      EdgeInsets.fromLTRB(0, 16, gutter, 16),
                                  child: SizedBox(
                                    width: 300,
                                    height: 220,
                                    child: _buildCameraPane(),
                                  ),
                                ),
                              ],
                            )
                          // Phone portrait: a compact strip above the question,
                          // right-aligned so the text keeps the full width.
                          : Column(
                              children: [
                                Padding(
                                  padding:
                                      EdgeInsets.fromLTRB(gutter, 12, gutter, 0),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: SizedBox(
                                      width: 128,
                                      height: 96,
                                      child: _buildCameraPane(),
                                    ),
                                  ),
                                ),
                                Expanded(child: questionPane),
                              ],
                            ),
                    ),
                    _buildActionBar(question),
                  ],
                );
              },
            ),
          ),
          if (proctoringState.showViolationOverlay)
            ViolationOverlay(
              type: proctoringState.lastViolation,
              warningCount: proctoringState.warningCount,
              isFinal: proctoringState.disqualified,
              onDismiss: () {
                if (proctoringState.disqualified) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                } else {
                  ref.read(proctoringProvider(widget.submissionId).notifier).dismissOverlay();
                }
              },
            ),
          // Above the violation overlay: while this countdown is running nothing
          // has been logged yet, and the only thing the student should be able to
          // do is come back to fullscreen (which is also the user gesture the
          // browser needs to grant it).
          if (_fullscreenDeadline != null)
            FullscreenLockOverlay(
              remaining: _fullscreenDeadline!.difference(_now()),
              onReturnToFullscreen: () => _webGuard?.requestFullscreen(),
            ),
        ],
      ),
    );
  }

  /// The question and its answer surface.
  ///
  /// Scrollable by construction. It used to be a `Column` with a `Spacer` inside
  /// a non-scrollable body, so a five-option question on a phone in landscape (or
  /// any large accessibility text scale) overflowed — and the overflow banner
  /// covered the last option.
  Widget _buildQuestionPane(Question question, AudioMonitoringState audioState) {
    final theme = Theme.of(context);
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final selectedOption = _answers[question.id];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The counters live here rather than in the app bar: three chips plus
          // the question number overflow a 360 dp phone's app bar, while a `Wrap`
          // here simply folds onto a second line.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_savedQuestions.isNotEmpty)
                _AnsweredChip(
                  count: _savedQuestions.length,
                  total: _questions.length,
                ),
              if (_kioskStatus != null) _KioskBadge(status: _kioskStatus!),
              // Always present, in every build: "the microphone is being
              // monitored" is part of the exam's state rather than an optional
              // extra, and its absence is the one silent failure this screen must
              // not have. Tapping it re-opens a microphone that was blocked or
              // unplugged; the settings action appears only for a refusal, the one
              // case where asking again cannot help.
              AudioMonitorIndicator(
                key: const Key('audio-indicator'),
                state: audioState,
                onRetry: () => unawaited(_retryAudioMonitoring()),
                onOpenSettings:
                    audioState.monitor == AudioMonitorState.permissionDenied
                        ? () => unawaited(PermissionService().openSettings())
                        : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(question.questionText, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          if (question.isFillInTheBlank)
            // Fill in the blank: no options, a text field, and a "Save &
            // next" action (the field has no auto-advance to trigger on).
            _FillInTheBlankField(
              key: ValueKey(question.id),
              initialValue: _textAnswers[question.id] ?? '',
              saved: _savedQuestions.contains(question.id) &&
                  _savedText[question.id] == (_textAnswers[question.id] ?? ''),
              enabled: !_submitting,
              // Keystrokes go to the durable cache (no network write): losing the
              // app must not lose an answer that is still being typed.
              onChanged: (value) => _cacheDraftText(question.id, value),
              onSubmitted: (_) => _saveTextAnswer(question),
            )
          else ...[
            ...List.generate(question.options.length, (i) {
              final isSelected = selectedOption == i;
              return Card(
                color: isSelected ? theme.colorScheme.secondaryContainer : null,
                child: ListTile(
                  key: Key('option-$i'),
                  title: Text(question.options[i]),
                  // Mirrors the local map, so a tap paints immediately even
                  // while its autosave RPC is still in flight.
                  selected: isSelected,
                  trailing: isSelected
                      ? const Icon(Icons.radio_button_checked)
                      : null,
                  onTap: _submitting ? null : () => _selectAnswer(i),
                ),
              );
            }),
            if (question.options.isEmpty)
              const Text(
                'This question has no options yet — tell your supervisor.',
              ),
          ],
        ],
      ),
    );
  }

  /// The proctoring self-view.
  ///
  /// Three states, and only one of them is a placeholder: mock mode (an explicit
  /// `--dart-define=MOCK_CAMERA=true` build) shows the loud MOCK tile, a live
  /// controller shows the preview, and anything else is a hard "camera offline"
  /// notice. There is deliberately no silent crossed-out stand-in for a real
  /// camera that failed — that made an unproctored session look normal.
  ///
  /// `BoxFit.cover` inside the caller's fixed box means the preview can never
  /// distort: whatever preview size the platform reports, the frame fills the box
  /// and crops the excess.
  Widget _buildCameraPane() {
    final controller = _cameraController;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ColoredBox(
        color: Colors.black,
        child: widget.mockMode
            ? const _MockCameraTile()
            : controller != null &&
                    controller.value.isInitialized &&
                    !controller.value.hasError
                ? FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: controller.value.previewSize?.height ?? 480,
                      height: controller.value.previewSize?.width ?? 640,
                      child: CameraPreview(controller),
                    ),
                  )
                : const _CameraOfflineNotice(),
      ),
    );
  }

  /// The action bar, pinned below the question instead of scrolling with it: on
  /// a long option list the buttons used to be pushed off the bottom of the body.
  Widget _buildActionBar(Question question) {
    final theme = Theme.of(context);
    final gutter = ResponsiveSizing.horizontalPadding(context);

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
          child: Row(
            children: [
              if (_currentIndex > 0)
                TextButton.icon(
                  key: const Key('exam-previous'),
                  onPressed:
                      _submitting ? null : () => _goTo(_currentIndex - 1),
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('Previous'),
                ),
              const Spacer(),
              // Explicit per-question navigation. A multiple-choice answer still
              // saves (and advances) on tap, but the student always has a
              // prominent Next to move on without answering or after reviewing;
              // a typed answer uses "Save & next", which persists through
              // merge_submission_text_answer before it moves.
              if (!question.isFillInTheBlank &&
                  _currentIndex < _questions.length - 1)
                FilledButton.icon(
                  key: const Key('exam-next'),
                  onPressed:
                      _submitting ? null : () => _goTo(_currentIndex + 1),
                  icon: const Icon(Icons.chevron_right),
                  iconAlignment: IconAlignment.end,
                  label: const Text('Next'),
                ),
              if (question.isFillInTheBlank &&
                  _currentIndex < _questions.length - 1)
                FilledButton.icon(
                  key: const Key('exam-save-text'),
                  onPressed: _submitting || _savingText
                      ? null
                      : () => _saveTextAnswer(question, advance: true),
                  icon: const Icon(Icons.check),
                  label: Text(_savingText ? 'Saving…' : 'Save & next'),
                ),
              if (_currentIndex == _questions.length - 1)
                FilledButton(
                  key: const Key('exam-submit'),
                  onPressed: _submitting ? null : () => _finalSubmit(),
                  child: Text(_submitting ? 'Submitting…' : 'Submit exam'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lock state of the exam surface, so a student and a roaming supervisor can
/// both see whether pinning is enforced (device owner) or best-effort (screen
/// pinning, which can still be escaped).
class _KioskBadge extends StatelessWidget {
  const _KioskBadge({required this.status});

  final KioskResult status;

  @override
  Widget build(BuildContext context) {
    final locked = status.granted;
    final strict = status.strict;
    final (IconData icon, Color color, String label) = switch ((locked, strict)) {
      (true, true) => (Icons.lock, Colors.green, 'Kiosk'),
      (true, false) => (Icons.lock_outline, Colors.amber, 'Pinned'),
      _ => (Icons.lock_open_outlined, Colors.redAccent, 'Unpinned'),
    };

    return Tooltip(
      message: status.message ?? 'Kiosk mode unavailable',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}

/// Shown in place of the self-view when a **real** session has no live camera.
///
/// Deliberately *not* a neutral camera placeholder: the blocking error above
/// already explains what went wrong, and this tile says plainly that the feed is
/// gone — an unproctored exam must never look like a normal one.
class _CameraOfflineNotice extends StatelessWidget {
  const _CameraOfflineNotice();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.videocam_off, color: Colors.redAccent, size: 26),
        const SizedBox(height: 6),
        Text(
          'CAMERA\nOFFLINE',
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: Colors.redAccent, height: 1.2),
        ),
      ],
    );
  }
}

/// Sits where the camera self-view would be on the only path with no real
/// hardware: `flutter run --dart-define=MOCK_CAMERA=true`. It is unreachable
/// without that compile-time flag (a failed real camera blocks the session
/// instead, see [_CameraOfflineNotice]), and loud on purpose — a tester should
/// never mistake simulated violations for real detection.
class _MockCameraTile extends StatelessWidget {
  const _MockCameraTile();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black87,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam_off_outlined, color: Colors.amber, size: 26),
          const SizedBox(height: 6),
          Text(
            'MOCK\nCAMERA',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Colors.amber, height: 1.2),
          ),
        ],
      ),
    );
  }
}

/// Full-screen blocking state for the exam session (permission refused, no
/// camera, questions unreachable, clock expired). It always offers a way out:
/// the exam chrome deliberately has no back button, so without one of these a
/// failure would strand the student with no escape.
class _BlockingState extends StatelessWidget {
  const _BlockingState({
    super.key,
    required this.message,
    this.title = 'Cannot start this exam',
    this.icon = Icons.error_outline,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.onOpenSettings,
    this.allowExit = false,
  });

  final String title;
  final String message;
  final IconData icon;

  /// Retry action, or null when retrying cannot help (e.g. an exam with no
  /// questions — only a supervisor can fix that).
  final VoidCallback? onRetry;
  final String retryLabel;

  /// Opens the OS app-settings page, for a permission the student has to change
  /// there (Android/iOS stop prompting after a permanent denial).
  final VoidCallback? onOpenSettings;

  /// Shows the "Leave" button.
  final bool allowExit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retry = onRetry;
    final openSettings = onOpenSettings;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(title),
      ),
      // Scrollable and width-capped: a phone in landscape, a resized desktop
      // window or a large accessibility text scale can still reach every button.
      // This screen is the only way out of a blocked session, so it must never
      // clip its own actions.
      body: SafeArea(
        child: ResponsiveScrollView(
          maxWidth: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.error),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (retry != null)
                FilledButton.icon(
                  key: const Key('exam-retry'),
                  onPressed: retry,
                  icon: const Icon(Icons.refresh),
                  label: Text(retryLabel),
                ),
              if (openSettings != null) ...[
                if (retry != null) const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('exam-open-settings'),
                  onPressed: openSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open settings'),
                ),
              ],
              if (allowExit) ...[
                if (retry != null || openSettings != null)
                  const SizedBox(height: 8),
                TextButton(
                  key: const Key('exam-leave'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Leave'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Countdown chip in the exam app bar: neutral, amber inside the last five
/// minutes and red in the last one, so the clock is visible without stealing
/// attention from the question.
class _RemainingChip extends StatelessWidget {
  const _RemainingChip({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final seconds = remaining.inSeconds;
    final scheme = Theme.of(context).colorScheme;
    final color = seconds <= 60
        ? Colors.redAccent
        : seconds <= 300
            ? Colors.amber
            : scheme.onSurface;

    return Tooltip(
      message: 'Time remaining',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              _format(seconds),
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  /// `m:ss` with the negative case clamped to zero (the auto-submit that
  /// follows the zero tick is asynchronous, so a tick can render at -1s).
  static String _format(int seconds) {
    final clamped = seconds < 0 ? 0 : seconds;
    return '${clamped ~/ 60}:${(clamped % 60).toString().padLeft(2, '0')}';
  }
}

/// Text input for a fill-in-the-blank question.
///
/// Stateful and keyed by question id (the parent passes `ValueKey(question.id)`),
/// so moving between questions creates a fresh controller holding *that*
/// question's saved text instead of leaking the previous answer into the next
/// field.
class _FillInTheBlankField extends StatefulWidget {
  const _FillInTheBlankField({
    super.key,
    required this.initialValue,
    required this.saved,
    required this.enabled,
    required this.onChanged,
    required this.onSubmitted,
  });

  final String initialValue;
  final bool saved;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  State<_FillInTheBlankField> createState() => _FillInTheBlankFieldState();
}

class _FillInTheBlankFieldState extends State<_FillInTheBlankField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Type your answer', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(
          key: const Key('exam-text-answer'),
          controller: _controller,
          enabled: widget.enabled,
          textInputAction: TextInputAction.done,
          minLines: 1,
          maxLines: 4,
          // Matches the server-side cap in merge_submission_text_answer().
          maxLength: 2000,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Your answer',
          ),
        ),
        Row(
          children: [
            Icon(
              widget.saved ? Icons.check_circle_outline : Icons.cloud_off_outlined,
              size: 14,
              color: widget.saved
                  ? Colors.green
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                widget.saved
                    ? 'Answer saved'
                    : 'Not saved yet — tap "Save & next", or Submit on the last '
                        'question, to send it.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: widget.saved
                      ? Colors.green
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// "3 of 5 answered" chip in the exam app bar.
class _AnsweredChip extends StatelessWidget {
  const _AnsweredChip({required this.count, required this.total});

  final int count;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Answers stored for this attempt',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '$count of $total answered',
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ),
    );
  }
}
