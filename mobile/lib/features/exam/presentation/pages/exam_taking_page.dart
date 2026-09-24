import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/kiosk_service.dart';
import '../../../../core/services/mediapipe_proctoring_service.dart';
import '../../../../core/services/permission_service.dart';
import '../../../../core/services/web_exam_guard.dart';
import '../../../../core/services/web_guards.dart';
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../../proctoring/presentation/widgets/violation_overlay.dart';
import '../../domain/entities/question.dart';

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

  const ExamTakingPage({
    super.key,
    required this.examId,
    required this.submissionId,
    this.durationMinutes,
    this.startedAt,
    this.webGuards,
  });

  @override
  ConsumerState<ExamTakingPage> createState() => _ExamTakingPageState();
}

class _ExamTakingPageState extends ConsumerState<ExamTakingPage> {
  CameraController? _cameraController;
  List<Question> _questions = [];

  /// Selected option per question id, mirrored locally so a tap paints
  /// immediately — the RPC round-trip is not on the UI's critical path, and the
  /// server copy (what grading reads) is written by [ExamRepository.saveAnswer].
  final Map<String, int> _answers = <String, int>{};

  int _currentIndex = 0;
  bool _loading = true;

  /// Set when the session cannot be proctored at all (permission refused, no
  /// camera) or when the question feed fails to load. Both are blocking states
  /// with a retry, because silently running an unproctored exam is worse than
  /// not starting it.
  String? _blockingError;

  /// In-flight guard for the final submit (double taps, retry storms).
  bool _submitting = false;

  /// True when the clock ran out but the server has not acknowledged the
  /// submission yet; build() then shows a retry/exit screen instead of silently
  /// dropping the attempt.
  bool _timeUpPending = false;

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

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final notifier = ref.read(proctoringProvider(widget.submissionId).notifier);

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
      onViolation: (event) {
        notifier.reportAppMinimized();
        if (event == WebGuardEvent.fullscreenExited) _promptFullscreen();
      },
    );
    _webGuard = webGuard;
    final fullscreenEntered = await webGuard.start();
    if (webGuard.guards.isSupported && !fullscreenEntered) {
      // Chromium only grants fullscreen from a user gesture, so the automatic
      // attempt can be refused; the prompt's action button is that gesture.
      WidgetsBinding.instance.addPostFrameCallback((_) => _promptFullscreen());
    }

    if (MediaPipeProctoringService.mockCameraFromEnvironment) {
      // MOCK_CAMERA=true: emulators, desktops and CI runners have no usable
      // front camera, so skip the capture pipeline entirely. The engine emits
      // simulated violations on a timer, and no snapshot source is attached —
      // there is nothing to photograph, so those logs carry no image URL.
      await _loadQuestions();
      _startCountdown();
      return;
    }

    // Real proctoring needs a camera, so this is checked *before* opening one:
    // a denied permission used to surface as an unhandled CameraException and
    // left the page on its loading spinner with no way out (the exam screen has
    // no back button by design). Mock sessions skip it above — there is no
    // camera to grant access to — and so do web/desktop, where
    // `permission_handler` cannot report a status and the camera plugin itself
    // is what reports a refusal (handled by the try/catch further down).
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final missingPermissions =
          await PermissionService().missingCriticalPermissions();
      if (missingPermissions.isNotEmpty) {
        _failStart(
          'This exam needs ${_permissionLabel(missingPermissions)} access. '
          'Grant it in your device settings, then tap Try again.',
        );
        return;
      }
    }

    // Front camera, low resolution is enough for face detection and keeps the
    // CameraImage stream cheap at 5–8 FPS inference.
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (error) {
      _failStart('No camera is available on this device (${error.code}).');
      return;
    } catch (error) {
      debugPrint('ProctorGuard: camera enumeration failed: $error');
      _failStart('The camera could not be opened on this device.');
      return;
    }

    if (cameras.isEmpty) {
      _failStart('No camera is available on this device.');
      return;
    }

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    _cameraController = CameraController(
      front,
      ResolutionPreset.low,
      enableAudio: false, // audio is a separate hook — see reportAudioLevel()
      // ML Kit reads exactly one plane: NV21 on Android, BGRA8888 elsewhere. On
      // the web `kIsWeb` short-circuits before ML Kit (no web implementation), so
      // the group only has to be streamable for the self-view.
      imageFormatGroup:
          !kIsWeb && defaultTargetPlatform == TargetPlatform.android
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
    );
    // Every step below can fail on a real device (another app holding the
    // camera, an OEM driver quirk, a permission revoked mid-session), so the
    // whole capture pipeline reports itself instead of throwing.
    try {
      await _cameraController!.initialize();

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
    } on CameraException catch (error) {
      _failStart(
        'The camera could not be started (${error.code}). Close any other app '
        'using it, then tap Try again.',
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

  /// Ends the bootstrap in the blocking-error state (see [_blockingError]).
  void _failStart(String message) {
    _cameraController?.dispose();
    _cameraController = null;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _blockingError = message;
    });
  }

  /// "camera and microphone", for the permission message above.
  static String _permissionLabel(List<StartupPermission> missing) =>
      missing.map((permission) => permission.name).join(' and ');

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

    final deadline =
        (widget.startedAt ?? DateTime.now()).add(Duration(minutes: minutes));

    _countdown?.cancel();
    _tickCountdown(deadline);
    _countdown = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(deadline),
    );
  }

  void _tickCountdown(DateTime deadline) {
    if (!mounted) return;

    final remaining = deadline.difference(DateTime.now());
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
    _cameraController?.stopImageStream();
    _cameraController?.dispose();

    // Unpin before releasing the bridge: `stopLock` tells the platform the exit
    // is intentional, so finishing the exam is not logged as an escape.
    unawaited(_releaseKiosk());

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

  /// Retry for the blocking states: re-runs only the stage that failed, so a
  /// camera that is already streaming (and the kiosk pin that came with it) is
  /// never reopened.
  Future<void> _retryBootstrap() async {
    setState(() {
      _blockingError = null;
      _loading = true;
    });

    if (_cameraController == null &&
        !MediaPipeProctoringService.mockCameraFromEnvironment) {
      await _bootstrap();
      return;
    }

    await _loadQuestions();
    _startCountdown();
  }

  Future<void> _selectAnswer(int optionIndex) async {
    final question = _questions[_currentIndex];

    // Paint first: the round-trip below must not gate the tap feedback.
    setState(() => _answers[question.id] = optionIndex);

    try {
      await ref.read(examRepositoryProvider).saveAnswer(
            submissionId: widget.submissionId,
            questionId: question.id,
            selectedOption: optionIndex,
          );
    } catch (error) {
      // Grading reads the *server* copy of the answers, so a failed autosave
      // means this answer is not stored yet. Say so and stay on the question so
      // the student can tap their choice again — advancing would move past the
      // only chance to save it.
      debugPrint('ProctorGuard: answer autosave failed: $error');
      _showMessage(
        'Could not save that answer. Check your connection and tap your choice '
        'again.',
      );
      return;
    }

    if (!mounted) return;
    if (_currentIndex < _questions.length - 1) {
      setState(() => _currentIndex++);
    }
  }

  /// Closes the attempt. `timeUp` is the countdown's path: no confirmation
  /// dialog (the clock already decided) and a retry screen if the server is
  /// unreachable.
  Future<void> _finalSubmit({bool timeUp = false}) async {
    if (_submitting || !mounted) return;

    if (!timeUp) {
      final confirmed = await _confirmSubmit();
      if (confirmed != true || !mounted) return;
    }

    setState(() => _submitting = true);
    try {
      // `submit_exam` grades on the server and is idempotent, so a retry after a
      // dropped connection is safe.
      await ref.read(examRepositoryProvider).submitExam(widget.submissionId);
      if (!mounted) return;
      _countdown?.cancel();
      _countdown = null;
      Navigator.of(context).pop();
    } catch (error) {
      debugPrint('ProctorGuard: submit failed: $error');
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _timeUpPending = timeUp;
      });
      if (!timeUp) {
        _showMessage(
          'Could not submit your exam. Check your connection and try again.',
        );
      }
    }
  }

  Future<bool?> _confirmSubmit() => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Submit your exam?'),
          content: Text(
            'You have answered ${_answers.length} of ${_questions.length} '
            'questions. Submitting closes the attempt for good.',
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

    // A disqualification ends the session server-side; the overlay explains it
    // and its Exit button pops the route. All this listener has to do is stop
    // the clock and clear the signal, so it cannot leak into a later exam.
    ref.listen<String?>(forceExitSignalProvider, (prev, next) {
      if (next != widget.submissionId) return;
      _countdown?.cancel();
      _countdown = null;
      ref.read(forceExitSignalProvider.notifier).state = null;
    });

    // --- Blocking states (each one offers a way out) --------------------
    final blockingError = _blockingError;
    if (blockingError != null) {
      return _BlockingState(
        message: blockingError,
        onRetry: _retryBootstrap,
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
    final selectedOption = _answers[question.id];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Question ${_currentIndex + 1} / ${_questions.length}'
          '${_answers.isEmpty ? '' : '  •  ${_answers.length} answered'}',
        ),
        automaticallyImplyLeading: false, // no manual exit mid-exam
        actions: [
          if (_remaining != null) _RemainingChip(remaining: _remaining!),
          if (_kioskStatus != null) _KioskBadge(status: _kioskStatus!),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(question.questionText, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                ...List.generate(question.options.length, (i) {
                  final isSelected = selectedOption == i;
                  return Card(
                    color: isSelected
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    child: ListTile(
                      key: Key('option-$i'),
                      title: Text(question.options[i]),
                      // Mirrors the local map, so a tap paints immediately even
                      // while its autosave RPC is still in flight.
                      selected: isSelected,
                      trailing: isSelected
                          ? const Icon(Icons.radio_button_checked)
                          : null,
                      onTap:
                          _submitting ? null : () => _selectAnswer(i),
                    ),
                  );
                }),
                const Spacer(),
                Row(
                  children: [
                    if (_currentIndex > 0)
                      TextButton.icon(
                        key: const Key('exam-previous'),
                        onPressed: _submitting
                            ? null
                            : () => setState(() => _currentIndex--),
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Previous'),
                      ),
                    const Spacer(),
                    if (_currentIndex == _questions.length - 1)
                      FilledButton(
                        key: const Key('exam-submit'),
                        onPressed:
                            _submitting ? null : () => _finalSubmit(),
                        child: Text(
                          _submitting ? 'Submitting…' : 'Submit exam',
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Small self-view so the student can confirm framing — also doubles
          // as a visible reminder that the camera is active. With no camera
          // (mock mode) an explicit placeholder goes here instead, so a
          // simulated session can never be mistaken for real proctoring.
          Positioned(
            top: 8,
            right: 8,
            width: 90,
            height: 120,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _cameraController == null
                  ? const _MockCameraTile()
                  : CameraPreview(_cameraController!),
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
        ],
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

/// Sits where the camera self-view would be when there is no feed at all —
/// i.e. `flutter run --dart-define=MOCK_CAMERA=true`. Deliberately loud: a
/// tester should never mistake simulated violations for real detection.
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
    this.allowExit = false,
  });

  final String title;
  final String message;
  final IconData icon;

  /// Retry action, or null when retrying cannot help (e.g. an exam with no
  /// questions — only a supervisor can fix that).
  final VoidCallback? onRetry;
  final String retryLabel;

  /// Shows the "Leave" button.
  final bool allowExit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final retry = onRetry;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(title),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                if (allowExit) ...[
                  if (retry != null) const SizedBox(height: 8),
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
