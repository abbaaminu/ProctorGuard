import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/kiosk_service.dart';
import '../../../../core/services/mediapipe_proctoring_service.dart';
import '../../../../core/services/web_exam_guard.dart';
import '../../../../core/services/web_guards.dart';
import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../../proctoring/presentation/widgets/violation_overlay.dart';
import '../../domain/entities/question.dart';

/// Route arguments: examId + submissionId (submission is created/resumed
/// by ExamRepository *before* navigating here — see exam list page).
class ExamTakingPage extends ConsumerStatefulWidget {
  final String examId;
  final String submissionId;

  /// Browser guards for this session; injectable so tests can drive tab-switch
  /// and fullscreen behaviour on the VM, where the real implementation (and its
  /// DOM) does not exist.
  final WebGuards? webGuards;

  const ExamTakingPage({
    super.key,
    required this.examId,
    required this.submissionId,
    this.webGuards,
  });

  @override
  ConsumerState<ExamTakingPage> createState() => _ExamTakingPageState();
}

class _ExamTakingPageState extends ConsumerState<ExamTakingPage> {
  CameraController? _cameraController;
  List<Question> _questions = [];
  int _currentIndex = 0;
  bool _loading = true;

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
      return;
    }

    // Front camera, low resolution is enough for face detection and keeps the
    // CameraImage stream cheap at 5–8 FPS inference.
    final cameras = await availableCameras();
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

    await _loadQuestions();
  }

  Future<void> _loadQuestions() async {
    final questions =
        await ref.read(examRepositoryProvider).getQuestions(widget.examId);
    if (!mounted) return;
    setState(() {
      _questions = questions;
      _loading = false;
    });
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
    _cameraController?.stopImageStream();
    _cameraController?.dispose();

    // Unpin before releasing the bridge: `stopLock` tells the platform the exit
    // is intentional, so finishing the exam is not logged as an escape.
    _kioskEscapes?.cancel();
    final kiosk = _kiosk;
    if (kiosk != null) {
      unawaited(kiosk.stopLock());
      kiosk.dispose();
    }

    // Same idea in the browser: leave fullscreen and drop the DOM listeners, so
    // a finished exam neither traps the student nor keeps counting strikes.
    final webGuard = _webGuard;
    if (webGuard != null) unawaited(webGuard.stop());

    super.dispose();
  }

  Future<void> _selectAnswer(int optionIndex) async {
    final question = _questions[_currentIndex];
    await ref.read(examRepositoryProvider).saveAnswer(
          submissionId: widget.submissionId,
          questionId: question.id,
          selectedOption: optionIndex,
        );
    if (_currentIndex < _questions.length - 1) {
      setState(() => _currentIndex++);
    }
  }

  Future<void> _finalSubmit() async {
    await ref.read(examRepositoryProvider).submitExam(widget.submissionId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final proctoringState = ref.watch(proctoringProvider(widget.submissionId));

    // A disqualification navigates the student out entirely, once.
    ref.listen<String?>(forceExitSignalProvider, (prev, next) {
      if (next == widget.submissionId) {
        // Overlay's "Exit" button handles the actual pop; here we could
        // also trigger forced-logout / clear auth session per section 4.
      }
    });

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final question = _questions[_currentIndex];

    return Scaffold(
      appBar: AppBar(
        title: Text('Question ${_currentIndex + 1} / ${_questions.length}'),
        automaticallyImplyLeading: false, // no manual exit mid-exam
        actions: [
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
                  return Card(
                    child: ListTile(
                      title: Text(question.options[i]),
                      onTap: () => _selectAnswer(i),
                    ),
                  );
                }),
                const Spacer(),
                if (_currentIndex == _questions.length - 1)
                  ElevatedButton(
                    onPressed: _finalSubmit,
                    child: const Text('Submit Exam'),
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
