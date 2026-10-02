import 'package:flutter/material.dart';

import '../../../../core/services/hardware_verification_service.dart';
import '../../../../core/widgets/responsive_layout.dart';
import '../../domain/entities/exam.dart';

/// The mandatory pre-exam hardware check.
///
/// The student reaches this screen from the portal **before** a submission is
/// created, and cannot get past it until a real camera *and* a real microphone
/// have been verified: "Start Exam" stays disabled while the checklist is
/// incomplete, and a refusal is explained rather than worked around.
///
/// Pops `true` when the student may start (the caller then creates the
/// submission and pushes the session screen) and `false`/null when they back
/// out — backing out must always be possible, since blocking entry is the point
/// and there is nothing to lose by returning to the list.
class ExamHardwareGatePage extends StatefulWidget {
  const ExamHardwareGatePage({super.key, required this.exam, this.verifier});

  final Exam exam;

  /// Injected in tests (and by the portal's own tests); defaults to the real
  /// device probe.
  final HardwareVerifier? verifier;

  @override
  State<ExamHardwareGatePage> createState() => _ExamHardwareGatePageState();
}

class _ExamHardwareGatePageState extends State<ExamHardwareGatePage> {
  late final HardwareVerifier _verifier = widget.verifier ?? HardwareVerifier();

  HardwareReport _report = HardwareReport.checking();

  /// Guards against a second check running on top of the first (a double tap on
  /// "Check again", or a retry while the camera is still opening).
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _runCheck();
  }

  Future<void> _runCheck() async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      _report = HardwareReport.checking();
    });

    final report = await _verifier.verify();
    if (!mounted) return;

    setState(() {
      _checking = false;
      _report = report;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = _report;
    final verified = report.isVerified;

    return Scaffold(
      appBar: AppBar(
        // A way back to the exam list: nothing has been started yet, so leaving
        // must stay possible even though the exam itself blocks entry.
        leading: IconButton(
          key: const Key('gate-back'),
          tooltip: 'Back to exams',
          onPressed: () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Device check'),
      ),
      body: SafeArea(
        child: ResponsiveScrollView(
          maxWidth: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.exam.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'This exam is proctored. Both your camera and your microphone '
                'must be switched on and working before you start.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              if (report.mock) const _MockHardwareBanner(),
              if (report.mock) const SizedBox(height: 12),
              // Web only, and never together with the mock banner (the verifier
              // suppresses it on that path): a browser camera is a real camera,
              // so the checks above are unchanged — but the on-device face
              // detector they are usually followed by does not exist here, and
              // the student is told before the attempt instead of after it.
              if (report.faceDetectionInactive) ...[
                const _FaceDetectionInactiveBanner(),
                const SizedBox(height: 12),
              ],
              _ProbeRow(probe: report.camera),
              const SizedBox(height: 8),
              _ProbeRow(probe: report.microphone),
              if (report.hasFailed) ...[
                const SizedBox(height: 16),
                _BlockingWarning(message: report.blockingMessage),
              ],
              const SizedBox(height: 24),
              _GateActions(
                checking: _checking,
                verified: verified,
                settingsHint: report.settingsHint,
                onCheckAgain: _runCheck,
                onOpenSettings: _verifier.openSettings,
                onStart: () => Navigator.of(context).pop(true),
                onCancel: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One device on the checklist: icon, label, and the detail line the probe
/// returned.
class _ProbeRow extends StatelessWidget {
  const _ProbeRow({required this.probe});

  final DeviceProbe probe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Widget leading, Color tint) = switch (probe.outcome) {
      ProbeOutcome.verified => (
          Icon(Icons.check_circle, color: Colors.green.shade400),
          Colors.green.shade400,
        ),
      ProbeOutcome.failed => (
          Icon(Icons.error_outline, color: scheme.error),
          scheme.error,
        ),
      ProbeOutcome.running => (
          const SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          scheme.onSurfaceVariant,
        ),
      ProbeOutcome.pending => (
          Icon(Icons.circle_outlined, color: scheme.onSurfaceVariant),
          scheme.onSurfaceVariant,
        ),
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fixed 24dp slot keeps the two rows aligned while one of them spins.
            SizedBox(
              height: 24,
              width: 24,
              child: Center(child: leading),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    probe.label,
                    style: theme.textTheme.titleSmall?.copyWith(color: tint),
                  ),
                  if (probe.message != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      probe.message!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown on the `--dart-define=MOCK_CAMERA=true` path. Loud on purpose: a
/// simulated session must never pass for a proctored one.
class _MockHardwareBanner extends StatelessWidget {
  const _MockHardwareBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: Colors.amber.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.videocam_off_outlined, color: Colors.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'MOCK HARDWARE — this build was compiled with '
                'MOCK_CAMERA=true, so no real camera or microphone is opened '
                'and nothing here is proctored.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when the platform has no on-device face detector (the web: Google ML
/// Kit has no browser build).
///
/// Not a refusal and not a mock — the attempt is a real one, with a real camera
/// and a real microphone, and it starts either way. What changes is how the
/// evidence can be used afterwards: every frame is still captured and reviewed,
/// but nothing flags a missing or second face automatically, so the student
/// should not expect the strike rules they were told about to fire in a browser.
class _FaceDetectionInactiveBanner extends StatelessWidget {
  const _FaceDetectionInactiveBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('gate-face-detection-note'),
      margin: EdgeInsets.zero,
      color: Colors.amber.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.face_retouching_off_outlined, color: Colors.amber),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'This exam is running in a browser, where on-device face '
                'detection is not available. Your camera and microphone are '
                'still checked and the attempt is still recorded for review — '
                'but faces are not flagged automatically, so a second person on '
                'screen or a covered camera will be caught by the recording, '
                'not as it happens.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The blocking explanation: which device failed, and the fact that both are
/// mandatory.
class _BlockingWarning extends StatelessWidget {
  const _BlockingWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      key: const Key('gate-warning'),
      margin: EdgeInsets.zero,
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The gate's actions. Stacks full-width on a phone and pairs up once there is
/// room, so the buttons never shrink to an unreadable size or overflow.
class _GateActions extends StatelessWidget {
  const _GateActions({
    required this.checking,
    required this.verified,
    required this.settingsHint,
    required this.onCheckAgain,
    required this.onOpenSettings,
    required this.onStart,
    required this.onCancel,
  });

  final bool checking;
  final bool verified;
  final bool settingsHint;
  final VoidCallback onCheckAgain;
  final Future<void> Function() onOpenSettings;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final start = FilledButton.icon(
      key: const Key('gate-start-exam'),
      // Disabled until *both* devices are verified — the hard gate.
      onPressed: verified ? onStart : null,
      icon: const Icon(Icons.play_arrow),
      label: const Text('Start Exam'),
    );

    final checkAgain = OutlinedButton.icon(
      key: const Key('gate-check-again'),
      onPressed: checking ? null : onCheckAgain,
      icon: const Icon(Icons.refresh),
      label: Text(checking ? 'Checking…' : 'Check again'),
    );

    final openSettings = OutlinedButton.icon(
      key: const Key('gate-open-settings'),
      onPressed: settingsHint ? () => onOpenSettings() : null,
      icon: const Icon(Icons.settings_outlined),
      label: const Text('Open settings'),
    );

    final cancel = TextButton(
      key: const Key('gate-cancel'),
      onPressed: onCancel,
      child: const Text('Back to exams'),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 420;
        final secondary = <Widget>[
          if (wide) Expanded(child: checkAgain) else checkAgain,
          if (settingsHint) ...[
            SizedBox(width: wide ? 12 : 0, height: wide ? 0 : 8),
            if (wide) Expanded(child: openSettings) else openSettings,
          ],
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            wide
                ? Row(children: secondary)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: secondary,
                  ),
            const SizedBox(height: 12),
            start,
            const SizedBox(height: 4),
            cancel,
          ],
        );
      },
    );
  }
}
