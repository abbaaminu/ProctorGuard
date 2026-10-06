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
import '../../../../core/services/permission_service.dart';
import '../../../../core/services/web_camera_permission.dart';
import '../../../../core/services/web_exam_guard.dart';
import '../../../../core/services/web_guards.dart';
import '../../../../core/utils/proctor_log.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../../proctoring/presentation/providers/audio_monitoring_provider.dart';
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../../proctoring/presentation/widgets/audio_monitor_indicator.dart';
import '../../../proctoring/presentation/widgets/fullscreen_lock_overlay.dart';
import '../../../proctoring/presentation/widgets/violation_overlay.dart';
import '../../domain/entities/question.dart';
import '../exam_strike_mapping.dart';
import '../providers/exam_session_controller.dart';
import '../widgets/exam_session_widgets.dart';
import '../widgets/exam_sync_banner.dart';

/// Route arguments: examId + submissionId (submission is created/resumed
/// by ExamRepository *before* navigating here — see exam list page) plus the
/// clock the attempt runs on: `durationMinutes` comes from `exams` and
/// `startedAt` from the submission row, so a resumed session keeps its
/// remaining time instead of restarting.
///
/// The page is now a thin *view*: it binds the platform services that need a
/// widget lifecycle (the camera, the kiosk lock, the browser guards, the idle
/// watcher, the device-integrity probe) and renders. Everything about the
/// session's data — the question feed, the answers, the countdown and the
/// offline-queue orchestration — lives in [ExamSessionController], and the
/// chrome lives in `widgets/exam_session_widgets.dart`.
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

  /// `profiles.full_name`, printed on the exam surface by
  /// [ExamCandidateHeader] so a roaming supervisor looking over a shoulder can
  /// see whose attempt it is without opening the dashboard.
  ///
  /// Optional on purpose: the session itself needs neither of these, and a build
  /// with no profile (widget tests, a desktop demo) simply renders no header
  /// rather than a strip of blanks.
  final String? candidateName;

  /// `exams.title`, shown beside the candidate's name.
  final String? examTitle;

  /// `auth.users.email` — the closest thing to an identifier `profiles` has
  /// (it carries no matric/registration column).
  final String? candidateEmail;

  const ExamTakingPage({
    super.key,
    required this.examId,
    required this.submissionId,
    this.durationMinutes,
    this.startedAt,
    this.webGuards,
    this.clock,
    this.mockCamera,
    this.candidateName,
    this.examTitle,
    this.candidateEmail,
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

  /// Wakes the queue when the OS brings the exam back to the foreground - the
  /// mobile equivalent of the browser's `online` event, and the moment a
  /// connection usually comes back.
  AppLifecycleListener? _appLifecycle;

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

  /// In-flight guard for the bootstrap (see [_bootstrap]).
  ///
  /// A blocking screen's "Try again" button is only rebuilt on the next turn of
  /// the event loop, so a double tap used to start a second session setup on top
  /// of the first: two capture pipelines competing for one lens, and a first
  /// kiosk pin, watcher set and integrity probe that nothing released.
  bool _bootstrapping = false;

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

  /// Identity of this session's controller. Rebuilt every frame, but `==` makes
  /// Riverpod hand back the same instance (see [ExamSessionArgs]).
  ExamSessionArgs get _args => ExamSessionArgs(
        examId: widget.examId,
        submissionId: widget.submissionId,
        durationMinutes: widget.durationMinutes,
        startedAt: widget.startedAt,
        clock: widget.clock,
      );

  ExamSessionController get _session =>
      ref.read(examSessionControllerProvider(_args).notifier);

  @override
  void initState() {
    super.initState();
    // Distinct from the notifier's lifecycle observer, which turns *leaving* into
    // a strike: this one only reacts to coming back.
    _appLifecycle = AppLifecycleListener(onResume: _onAppResumed);

    // Hand the controller the two things only the widget knows how to do: submit
    // when the clock runs out, and speak to the student.
    final session = _session;
    session.onTimeUp = () => _finalSubmit(timeUp: true);
    session.onMessage = _showMessage;

    _bootstrap();
  }

  /// The exam app is in the foreground again: re-assert fullscreen and push
  /// whatever the queue is holding.
  ///
  /// On mobile there is no `online` event to listen to, so this is when a dropped
  /// connection is most likely to be back - and a student who was offline for the
  /// last ten minutes should not have to wait out a backoff timer to find out.
  void _onAppResumed() {
    if (!mounted) return;
    _webGuard?.reassertFullscreen();
    unawaited(_session.retrySyncNow());
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

    // Local-first: the controller loads the durable cache before anything can be
    // painted, so a resumed attempt shows the answers typed before the app was
    // killed even when the server is unreachable.
    await _session.hydrateCache();

    // Audio proctoring starts with the session rather than with the camera: it is
    // platform-independent and never throws, so it is started without being
    // awaited - a permission dialog stays on screen until the student answers it,
    // and the question feed must not be held behind that.
    unawaited(_startAudioMonitoring());

    // A retry re-runs this method, so whatever the previous attempt pinned or
    // subscribed to is released first.
    await _releaseKiosk();
    final previousGuard = _webGuard;
    _webGuard = null;
    if (previousGuard != null) await previousGuard.stop();

    // Pin the app first: with lock task on, home, recents and the notification
    // shade are gone. Off Android - or without Device Owner status - this degrades
    // to best-effort screen pinning, and the escape stream still turns a
    // successful escape into an `app_minimized` violation.
    final kiosk = KioskService();
    _kiosk = kiosk;
    _kioskEscapes = kiosk.escapes.listen((_) => notifier.reportAppMinimized());
    final kioskStatus = await kiosk.startLock();
    if (!kioskStatus.granted) {
      proctorLog('ProctorGuard kiosk: not pinned — ${kioskStatus.message}');
    }
    if (mounted) setState(() => _kioskStatus = kioskStatus);

    // Browser guards — the web counterpart of the lock task above. A tab switch,
    // a window blur or leaving fullscreen becomes an `app_minimized` violation.
    final webGuard = WebExamGuard(
      guards: widget.webGuards ?? WebGuards(),
      fullscreenGrace: fullscreenGrace,
      clock: widget.clock,
      // Which strike an event costs is decided in `exam_strike_mapping.dart`, not
      // by the guard: a blur and a copy attempt both arrive here, and only one of
      // them is leaving the exam surface.
      onViolation: (event) => _reportWebGuardEvent(notifier, event),
      // Leaving fullscreen is not logged immediately: the student gets the grace
      // window below, and only a window that runs out becomes the strike.
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

    // Idle detection and device integrity start with the session rather than with
    // the camera: they are about the device and the student, not about the video.
    // Released first, because a retry must not leave a second watcher running.
    _releaseSessionWatchers();

    final afk = AfkWatcher(onIdle: notifier.reportIdleAfk, clock: widget.clock);
    _afk = afk;
    afk.start();

    // Pointer input is what keeps that idle window quiet. A router *route* rather
    // than a `Listener` widget: this only observes, and a global route sees the
    // whole surface without nesting the layout inside a wrapper.
    if (!_pointerRouteAttached) {
      _pointerRouteAttached = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerActivity);
    }

    // Android is the only platform with a native half for this probe; anywhere
    // else it answers "cannot see". Mock sessions are exempt on purpose: a mock
    // session runs on an emulator by definition, where the camera *is*
    // synthesised, and there is no student lens to judge.
    if (!widget.mockMode && HardwareIntegrityService.isSupportedPlatform) {
      final integrity = HardwareIntegrityService();
      _integrity = integrity;
      integrity.startMonitoring(
        onFinding: (finding) => _reportIntegrityFinding(notifier, finding),
        // Read per probe, not captured: only the camera controller can name the
        // lens in use, and it does not exist until the pipeline below has started.
        cameraId: _cameraInUse,
      );
    }

    if (widget.mockMode) {
      // MOCK_CAMERA=true: emulators, desktops and CI runners have no usable front
      // camera, so skip the capture pipeline entirely. No snapshot source is
      // attached — there is nothing to photograph.
      await _session.loadQuestions();
      _session.startCountdown();
      return;
    }

    // Real proctoring needs a camera *and* a microphone, so both are checked
    // before either is opened. Web/desktop are skipped here — `permission_handler`
    // cannot report a status there, and the browser probe below asks for access.
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final report = await PermissionService().checkCritical();
      if (report.denied.isNotEmpty) {
        _failStart(
          'This exam needs ${report.deniedLabel} access. Grant it in your '
          'device settings, then tap Try again.',
          offerSettings: true,
        );
        return;
      }
      if (report.unknown.isNotEmpty) {
        proctorLog(
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
      proctorLog('ProctorGuard: camera enumeration failed: $error');
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
      // The camera is the camera: video frames for face detection, plus the
      // occasional still as violation evidence. Nothing here records sound.
      //
      // Audio proctoring owns the microphone through its own capture session
      // (`AudioMonitor` -> `record`), so a `CameraController` that claims the
      // microphone too is competing with it for the input device - and where the
      // OS hands the microphone to one client at a time, the second capture fails
      // to open and audio proctoring sits in "Mic unavailable" for the whole
      // attempt. The mic is opened by the session, not by the lens.
      enableAudio: false,
      imageFormatGroup: proctorImageFormatGroup(),
    );
    // Every step below can fail on a real device, so the whole capture pipeline
    // reports itself instead of throwing.
    try {
      await _cameraController!.initialize();
      // Watch the controller so a mid-session failure pauses proctoring and
      // prompts the student rather than letting the engine read a dead feed as
      // "no face".
      _cameraController!.addListener(_onCameraValueChanged);

      // Route every frame through the face-detection engine owned by the
      // proctoring notifier for this session.
      notifier.engineAttachCamera(front);
      // Violation evidence: the notifier pulls a still frame from here whenever it
      // logs something, then uploads it to the proctor-snapshots bucket.
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
      proctorLog('ProctorGuard: camera pipeline failed: $error');
      _failStart('Proctoring could not start on this device.');
      return;
    }

    await _session.loadQuestions();
    _session.startCountdown();
  }

  /// Turns one browser-guard event into the violation it is evidence of.
  ///
  /// The mapping itself (which event costs which strike) lives in
  /// `exam_strike_mapping.dart` so it can be tested on its own; the guard knows
  /// *that* something happened, and the mapping names the strike.
  void _reportWebGuardEvent(ProctoringNotifier notifier, WebGuardEvent event) {
    final strike = strikeForWebGuardEvent(event);
    if (strike != null) applyStrike(notifier, strike);
  }

  /// Turns a device-integrity finding into its violation via the same mapping
  /// module: a second display is `secondary_display_detected`, a camera that is
  /// not this device's own lens is `virtual_camera_detected`.
  void _reportIntegrityFinding(
    ProctoringNotifier notifier,
    HardwareFinding finding,
  ) {
    final strike = strikeForHardwareFinding(finding);
    if (strike != null) applyStrike(notifier, strike);
  }

  /// Ends the bootstrap in the blocking-error state (see
  /// [ExamSessionState.blockingError]).
  void _failStart(String message, {bool offerSettings = false}) {
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
    _session.failStart(message, offerSettings: offerSettings);
  }

  /// Releases one capture session: stop the frames, then dispose the controller.
  ///
  /// Every step is contained, because this only ever runs on the way *out* - of a
  /// failed start or of the whole attempt. The order is what Android needs: the
  /// lens is only handed back once the image stream is closed.
  static Future<void> _releaseCamera(CameraController camera) async {
    try {
      // Guarded as well as caught: `stopImageStream()` throws when no stream is
      // running, which is the normal state of a controller that just failed.
      if (camera.value.isStreamingImages) await camera.stopImageStream();
    } catch (error) {
      proctorLog('ProctorGuard: stopping the camera stream failed: $error');
    }
    try {
      await camera.dispose();
    } catch (error) {
      proctorLog('ProctorGuard: releasing the camera failed: $error');
    }
  }

  /// Camera controller listener: pausing on error, resuming once frames flow
  /// again. A feed that reports `hasError` no longer gets read as "no face", and
  /// a recovered stream re-arms proctoring with fresh frame counts.
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
  /// [ProctoringNotifier.setCameraActive]) and tells the student why, so a broken
  /// feed cannot quietly accumulate disqualification flags. Mock sessions never
  /// reach here (no camera is opened) and keep tracking on.
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
  /// plugged back in - or a student who moved rooms - is a new noise floor.
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
  /// `unavailable` stays on the indicator - nagging a device that cannot report
  /// levels would be noise.
  void _promptAudioAttention(AudioMonitoringState state) {
    if (!mounted) return;
    final denied = state.monitor == AudioMonitorState.permissionDenied;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            state.message ?? 'Audio proctoring needs your attention.',
          ),
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

  /// "camera and microphone", for the permission message in [_runBootstrap].
  static String _permissionLabel(List<StartupPermission> missing) =>
      missing.map((permission) => permission.name).join(' and ');

  /// The camera list for this platform, asking the browser for access first when
  /// it has not been granted yet.
  ///
  /// `camera_web` enumerates with `navigator.mediaDevices.enumerateDevices()` and
  /// drops every device whose `deviceId` is empty — which is exactly what a
  /// browser reports *before* the camera grant. A web session therefore sees an
  /// empty list although devices obviously exist. One `getUserMedia` probe (see
  /// [WebCameraPermission]) unlocks enumeration, then this asks again.
  Future<List<CameraDescription>> _resolveCameras() async {
    final cameras = await availableCameras();
    if (cameras.isNotEmpty || !kIsWeb) return cameras;

    final probe = WebCameraPermission();
    if (!probe.isSupported) return cameras;

    proctorLog(
      'ProctorGuard: no camera visible yet — asking the browser for access.',
    );
    if (!await probe.ensureAccess()) return cameras;

    return availableCameras();
  }

  /// Grabs a still frame as violation evidence, or null when the camera can't
  /// provide one at this moment (some Android devices refuse `takePicture`
  /// while an image stream is running) — the violation is logged either way.
  Future<Uint8List?> _captureSnapshot() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return null;

    try {
      final shot = await controller.takePicture();
      return await shot.readAsBytes();
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

  @override
  void dispose() {
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

    // The countdown is the controller's to cancel; Riverpod disposes it with the
    // provider when this page's watch goes away.
    super.dispose();
  }

  /// Releases the kiosk pin and its escape subscription. Called by [dispose] and
  /// at the start of [_runBootstrap] so a retry cannot stack a second pin.
  Future<void> _releaseKiosk() async {
    // Cancelling the escape subscription is deliberately not awaited: dropping
    // the subscription is what matters, while a teardown future the platform
    // stream may never complete must not be able to hold up the bootstrap.
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
  /// Called by [dispose] and at the start of [_runBootstrap]: a retry re-runs the
  /// whole session setup, so without this the watcher the failed attempt started
  /// would keep its timer - and its key handler - behind the session that
  /// replaced it. Both are idempotent.
  void _releaseSessionWatchers() {
    _afk?.stop();
    _afk = null;
    // Guarded: this also runs for a bootstrap that never reached the registration
    // below, and `removeGlobalRoute` asserts on a route it does not know (see
    // [_pointerRouteAttached]).
    if (_pointerRouteAttached) {
      _pointerRouteAttached = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(
        _onPointerActivity,
      );
    }
    _integrity?.stopMonitoring();
    _integrity = null;
  }

  /// Any pointer event - a tap, a drag, a hover, a scroll - is somebody at the
  /// device, which is what keeps [AfkWatcher] quiet.
  void _onPointerActivity(PointerEvent event) => _afk?.noteActivity();

  /// The id of the camera actually feeding this attempt, or null while the
  /// capture pipeline is still coming up.
  ///
  /// Android's integrity probe uses it to be exact about *which* lens is being
  /// judged: one known to be external is a stronger finding than one merely
  /// attached. It is read on every probe rather than handed over once.
  String? _cameraInUse() => _cameraController?.description.name;

  /// Retry for the blocking states: re-runs only the stage that failed, so a
  /// camera that is already streaming (and the kiosk pin that came with it) is
  /// never reopened.
  Future<void> _retryBootstrap() async {
    _session.resetForRetry();

    if (_cameraController == null && !widget.mockMode) {
      await _bootstrap();
      return;
    }

    await _session.loadQuestions();
    _session.startCountdown();
  }

  /// Closes the attempt. `timeUp` is the countdown's path: no confirmation
  /// dialog (the clock already decided) and a retry screen if the server is
  /// unreachable.
  Future<void> _finalSubmit({bool timeUp = false}) async {
    final session = _session;
    if (session.isSubmitting || !mounted) return;

    if (!timeUp) {
      final confirmed = await _confirmSubmit();
      if (confirmed != true || !mounted) return;

      // Only close the attempt once the last typed answer is durable: grading
      // reads the server copy, so submitting without it would drop it silently.
      if (!await session.flushTextAnswer()) return;
    } else {
      // The clock decides, so submission wins over a failed save - but still try
      // once, because a fill-in-the-blank field is normally the only unsaved
      // thing on screen.
      await session.flushTextAnswer();
    }

    // Everything the student typed is on the device by now; make sure it is on
    // the server before the attempt closes. A queue that cannot drain means the
    // network is gone, and nothing typed is lost by *not* submitting yet.
    var outcome = await session.prepareSubmit(timeUp: timeUp);
    if (!mounted) return;

    if (outcome.gate == SubmitGate.rejectedAnswers) {
      final accepted = await _confirmRejectedAnswers(outcome.rejectedCount);
      if (!mounted) return;
      if (accepted != true) {
        session.abortSubmit(timeUp: timeUp);
        return;
      }
      outcome = await session.prepareSubmit(timeUp: timeUp, acknowledged: true);
      if (!mounted) return;
    }

    // Still owed the server an answer: the controller has put the page on its
    // "waiting for a connection" screen.
    if (outcome.gate == SubmitGate.pendingAnswers) return;

    session.markSubmitting();
    try {
      // `submit_exam` grades on the server and is idempotent, so a retry after a
      // dropped connection is safe.
      await session.submitToServer();
      if (!mounted) return;
      session.onSubmitted();
      // The server owns the answers now, so the drafts for this attempt are only
      // clutter. Queued violations are deliberately kept (see clearSession).
      await session.clearSession();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      proctorLog('ProctorGuard: submit failed: $error');
      if (!mounted) return;
      session.onSubmitFailed(timeUp: timeUp);
      if (!timeUp) {
        _showMessage(
          'Could not submit your exam. Check your connection and try again.',
        );
      }
    }
  }

  /// The "waiting for a connection" screen's retry: drain the queue and, when it
  /// is empty, go straight back to submitting (no second confirmation dialog -
  /// the student already asked).
  Future<void> _retryOfflineSubmit() async {
    final ready = await _session.retryOfflineSubmit();
    if (!mounted) return;

    if (!ready) {
      _showMessage(
        'Still offline - your answers are safe on this device. Reconnect and '
        'tap Submit again.',
      );
      return;
    }

    await _finalSubmit();
  }

  Future<bool?> _confirmSubmit() {
    final session = ref.read(examSessionControllerProvider(_args));
    final marked = session.markedForReview.length;
    // Only when there is something to warn about: the sentence is the last
    // reminder a flag ever gets, and it would be noise on an exam where nobody
    // used the marker.
    final markedNote = marked == 0
        ? ''
        : '\n\n$marked '
            '${marked == 1 ? 'question is' : 'questions are'} still marked '
            'for review.';
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit your exam?'),
        content: Text(
          'You have answered ${session.savedQuestions.length} of '
          '${session.questions.length} questions. Submitting closes the attempt '
          'for good.$markedNote',
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
  }

  /// Warns that the server refused some answers (a closed attempt or a passed
  /// deadline) before the student closes the attempt for good.
  Future<bool?> _confirmRejectedAnswers(int rejectedAnswers) =>
      showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Some answers were not saved'),
          content: Text(
            '$rejectedAnswers '
            '${rejectedAnswers == 1 ? 'answer could' : 'answers could'} '
            'not be saved because the attempt was closed or its deadline passed. '
            'The server will grade only answers it accepted.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Submit saved answers'),
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
    final session = ref.watch(examSessionControllerProvider(_args));
    final proctoringState = ref.watch(proctoringProvider(widget.submissionId));

    // The app-wide offline queue: the banner renders its state, and watching it
    // here is also what keeps the instance the notifier logs violations through.
    final sync = ref.watch(offlineSyncServiceProvider);

    // A disqualification ends the session server-side; the overlay explains it
    // and its Exit button pops the route. All this listener has to do is stop
    // the clock and clear the signal, so it cannot leak into a later exam.
    ref.listen<String?>(forceExitSignalProvider, (prev, next) {
      if (next != widget.submissionId) return;
      _session.stopCountdown();
      ref.read(forceExitSignalProvider.notifier).state = null;
    });

    // Audio proctoring for this attempt. Watching it is what keeps the
    // `autoDispose` microphone session alive for as long as the exam screen is
    // (see `audioMonitoringProvider`); the question pane's header renders it.
    final audioState = ref.watch(audioMonitoringProvider(widget.submissionId));

    // A refusal or a lost device is announced once per transition, so a
    // microphone that goes away mid-exam prompts the student instead of leaving
    // a silent hole in proctoring.
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
    final blockingError = session.blockingError;
    if (blockingError != null) {
      return ExamBlockingState(
        message: blockingError,
        onRetry: _retryBootstrap,
        // Only a permission failure can be fixed in the OS settings, so the
        // extra action appears exactly then.
        onOpenSettings: session.offerSettings
            ? () => PermissionService().openSettings()
            : null,
        allowExit: true,
      );
    }

    if (session.timeUpPending) {
      return ExamBlockingState(
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

    if (session.offlineSubmitPending) {
      return ExamBlockingState(
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

    if (session.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (session.questions.isEmpty) {
      // No questions is a supervisor's setup mistake, not a used-up attempt:
      // leaving keeps the submission `ongoing` so it can be resumed once the
      // questions are published.
      return ExamBlockingState(
        key: const Key('exam-no-questions'),
        icon: Icons.help_outline,
        title: 'No questions yet',
        message: 'This exam has no questions published yet. Tell your '
            'supervisor — you can come back once they are added.',
        allowExit: true,
      );
    }

    final question = session.questions[session.currentIndex];

    return Scaffold(
      appBar: AppBar(
        // Explicit numbering on every question, both shapes: "Question 3 of 5".
        title: Text(
          'Question ${session.currentIndex + 1} of ${session.questions.length}',
        ),
        automaticallyImplyLeading: false, // no manual exit mid-exam
        // Only the clock stays here: the question number plus three chips
        // overflow a 360 dp phone's app bar. The answered count and the kiosk
        // badge moved into the question pane's header, where they wrap instead.
        actions: [
          if (session.remaining != null)
            ExamRemainingChip(remaining: session.remaining!),
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
                final questionPane = _buildQuestionPane(
                  session,
                  question,
                  audioState,
                );

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
                                  padding: EdgeInsets.fromLTRB(
                                    0,
                                    16,
                                    gutter,
                                    16,
                                  ),
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
                                  padding: EdgeInsets.fromLTRB(
                                    gutter,
                                    12,
                                    gutter,
                                    0,
                                  ),
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
                    _buildActionBar(session, question),
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
              // The same index the supervisor's grid shows for this attempt: it is
              // derived from this session's own violation list, not passed in.
              risk: proctoringState.risk,
              onDismiss: () {
                if (proctoringState.disqualified) {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                } else {
                  ref
                      .read(proctoringProvider(widget.submissionId).notifier)
                      .dismissOverlay();
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
  /// Whether the answer stored for [question] is the one on screen — what the
  /// three answer widgets mean by "saved".
  ///
  /// It works for the typed shapes *and* true/false: a true/false tap stores the
  /// word through the same text plumbing, so both halves of the comparison come
  /// from `textAnswers` / `savedText`.
  bool _isAnswerSaved(ExamSessionState session, Question question) =>
      session.savedQuestions.contains(question.id) &&
      session.savedText[question.id] ==
          (session.textAnswers[question.id] ?? '');

  Widget _buildQuestionPane(
    ExamSessionState session,
    Question question,
    AudioMonitoringState audioState,
  ) {
    final theme = Theme.of(context);
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final selectedOption = session.answers[question.id];

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Who is sitting this exam: the app bar is spent on the question
          // number and the clock, and the counters below are about the paper,
          // so identity gets its own strip.
          if (widget.candidateName != null || widget.examTitle != null) ...[
            ExamCandidateHeader(
              candidateName: widget.candidateName ?? 'Candidate',
              examTitle: widget.examTitle,
              candidateEmail: widget.candidateEmail,
            ),
            const SizedBox(height: 12),
          ],
          // The counters live here rather than in the app bar: three chips plus
          // the question number overflow a 360 dp phone's app bar, while a `Wrap`
          // here simply folds onto a second line.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (session.savedQuestions.isNotEmpty)
                ExamAnsweredChip(
                  count: session.savedQuestions.length,
                  total: session.questions.length,
                ),
              if (_kioskStatus != null) ExamKioskBadge(status: _kioskStatus!),
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
          // The review grid, above the question: every number in the paper with
          // what has been done to it so far, and a tap to go there. Answers are
          // the one thing on this screen that cannot be reconstructed from memory
          // at the end of an exam, so "what is still unanswered" has to be
          // readable without hunting.
          ExamQuestionPalette(
            key: const Key('exam-palette'),
            questions: session.questions,
            currentIndex: session.currentIndex,
            // The same "answered" set the counted chip and the submit summary use
            // (`savedQuestions`), so the header never shows two different counts:
            // an answer is answered once it is stored, and a draft the student has
            // not saved is what the text field's own "Not saved yet" line already
            // says it is.
            answeredIds: session.savedQuestions,
            // "I have to come back to this one" - the grid is the only place a
            // flag can be seen next to what is still unanswered.
            markedIds: session.markedForReview,
            onSelect: session.submitting
                ? null
                : (index) => unawaited(_session.goTo(index)),
          ),
          const SizedBox(height: 16),
          Text(question.questionText, style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          if (question.isTrueFalse)
            // True/false: two tap targets. The tap stores the word through the
            // text path (see `ExamSessionController.selectTrueFalse`), so it
            // paints and advances exactly like a multiple-choice answer.
            ExamTrueFalseField(
              key: ValueKey(question.id),
              selectedValue: session.textAnswers[question.id],
              saved: _isAnswerSaved(session, question),
              enabled: !session.submitting,
              onSelected: (value) => unawaited(_session.selectTrueFalse(value)),
            )
          else if (question.isSubjective)
            // An essay: the same durable plumbing as a fill-in-the-blank answer
            // (draft to the cache on every keystroke, saved through
            // merge_submission_text_answer) in a taller box. Nothing here scores
            // it — its marks come from the lecturer after the attempt is handed
            // in.
            ExamEssayField(
              key: ValueKey(question.id),
              initialValue: session.textAnswers[question.id] ?? '',
              saved: _isAnswerSaved(session, question),
              enabled: !session.submitting,
              onChanged: (value) => _session.cacheDraftText(question.id, value),
              onSubmitted: (_) => _session.saveTextAnswer(question.id),
            )
          else if (question.isFillInTheBlank)
            // Fill in the blank: no options, a text field, and a "Save &
            // next" action (the field has no auto-advance to trigger on).
            ExamFillInTheBlankField(
              key: ValueKey(question.id),
              initialValue: session.textAnswers[question.id] ?? '',
              saved: _isAnswerSaved(session, question),
              enabled: !session.submitting,
              // Keystrokes go to the durable cache (no network write): losing the
              // app must not lose an answer that is still being typed.
              onChanged: (value) => _session.cacheDraftText(question.id, value),
              onSubmitted: (_) => _session.saveTextAnswer(question.id),
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
                  onTap: session.submitting
                      ? null
                      : () => _session.selectOption(i),
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
            ? const ExamMockCameraTile()
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
                : const ExamCameraOfflineNotice(),
      ),
    );
  }

  /// The action bar, pinned below the question instead of scrolling with it: on
  /// a long option list the buttons used to be pushed off the bottom of the body.
  Widget _buildActionBar(ExamSessionState session, Question question) {
    final theme = Theme.of(context);
    final gutter = ResponsiveSizing.horizontalPadding(context);
    final first = session.currentIndex == 0;
    final last = session.currentIndex == session.questions.length - 1;
    final blocked = session.submitting;
    final marked = session.markedForReview.contains(question.id);

    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: theme.dividerColor)),
          ),
          padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
          // Both directions sit together on the right, "Previous" immediately
          // beside "Next": it is the pair a student moves with, and it used to be
          // pushed to the opposite edge of the bar - hidden outright on the first
          // question, so the way back was invisible whenever it mattered least.
          // Keeping it on screen (disabled on question 1) is what makes the
          // back-and-forth affordance discoverable at all.
          child: Row(
            children: [
              // The mark toggle sits on the left, away from the Previous/Next
              // pair: flagging is not navigation, and squeezing it between the two
              // arrows would put "go back" and "flag this" one mis-tap apart.
              IconButton(
                key: const Key('exam-mark-review'),
                onPressed: blocked
                    ? null
                    : () => _session.toggleMarkForReview(question.id),
                tooltip: marked ? 'Marked for review' : 'Mark for review',
                icon: Icon(marked ? Icons.flag : Icons.outlined_flag),
                color: marked ? theme.colorScheme.tertiary : null,
              ),
              const SizedBox(width: 8),
              // The nav pair lives in the *slack* of the bar rather than being
              // pushed to the right edge with a Spacer: a Spacer would take an
              // equal share of the free space and leave the labels shrinking into
              // the middle of an empty bar (see [_ShrinkableLabel]).
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Flexible, so the two labels share whatever the bar has
                    // left after the toggle rather than overflowing it: on a 360 dp
                    // phone this row holds three controls, and the *word* is the
                    // only part of a button that can give - the horizontal pads and
                    // the 48 dp touch targets are Material minimums.
                    Flexible(
                      child: TextButton.icon(
                        key: const Key('exam-previous'),
                        onPressed: blocked || first
                            ? null
                            : () => _session.goTo(session.currentIndex - 1),
                        icon: const Icon(Icons.chevron_left),
                        label: const _ShrinkableLabel('Previous'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Explicit per-question navigation. A multiple-choice or
                    // true/false answer still saves (and advances) on tap, but
                    // the student always has a prominent Next to move on without
                    // answering or after reviewing; a typed answer (fill in the
                    // blank, essay) uses "Save & next", which persists through
                    // merge_submission_text_answer before it moves.
                    if (question.usesTextAnswer && !last)
                      Flexible(
                        child: FilledButton.icon(
                          key: const Key('exam-save-text'),
                          onPressed: blocked || session.savingText
                              ? null
                              : () => _session.saveTextAnswer(
                                    question.id,
                                    advance: true,
                                  ),
                          icon: const Icon(Icons.check),
                          label: _ShrinkableLabel(
                            session.savingText ? 'Saving…' : 'Save & next',
                          ),
                        ),
                      )
                    else if (!last)
                      Flexible(
                        child: FilledButton.icon(
                          key: const Key('exam-next'),
                          onPressed: blocked
                              ? null
                              : () => _session.goTo(session.currentIndex + 1),
                          icon: const Icon(Icons.chevron_right),
                          iconAlignment: IconAlignment.end,
                          label: const _ShrinkableLabel('Next'),
                        ),
                      )
                    else
                      Flexible(
                        child: FilledButton(
                          key: const Key('exam-submit'),
                          onPressed: blocked ? null : () => _finalSubmit(),
                          child: _ShrinkableLabel(
                            session.submitting ? 'Submitting…' : 'Submit exam',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A button label that shrinks instead of overflowing its row.
///
/// The action bar has to hold three controls on a 360 dp phone, and a label is
/// the only part of a button that can give: the horizontal pads and the 48 dp
/// touch targets are Material minimums, and the icons say as much as the second
/// half of the longest word. Scaling the *text* down (never up) means a wide
/// system font, a long translation or a large accessibility text scale costs a
/// slightly smaller word instead of a striped overflow past the bar.
class _ShrinkableLabel extends StatelessWidget {
  const _ShrinkableLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1, softWrap: false),
    );
  }
}
