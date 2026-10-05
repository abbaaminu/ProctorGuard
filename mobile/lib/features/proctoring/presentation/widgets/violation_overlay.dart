import 'package:flutter/material.dart';

import '../../domain/entities/proctoring_risk.dart';
import '../../domain/entities/violation.dart';
import 'risk_index_chip.dart';

/// The full-screen proctoring warning: what was detected, which strike this is,
/// and how this attempt now reads on the risk index.
///
/// The risk index is here, on the student's own screen, for the same reason it
/// is in the supervisor's grid: it is the one number both sides can quote at each
/// other afterwards. A student on strike two sees what a supervisor sees, so
/// "why was I disqualified?" is answered by the screen that was in front of them
/// at the time — and the caption under the chip spells the score out, because a
/// phone has no hover for the chip's tooltip.
class ViolationOverlay extends StatelessWidget {
  final ViolationType? type;
  final int warningCount;
  final bool isFinal; // warningCount >= 3 -> disqualified, no dismiss

  /// The attempt's index so far, recomputed from the session's own violation
  /// list (`ProctoringState.risk`) — never a number passed alongside it.
  final ProctoringRisk risk;
  final VoidCallback onDismiss;

  const ViolationOverlay({
    super.key,
    required this.type,
    required this.warningCount,
    required this.isFinal,
    required this.risk,
    required this.onDismiss,
  });

  String _message(ViolationType? t) => switch (t) {
        ViolationType.lookingAway => 'Please keep your eyes on the screen.',
        ViolationType.multipleFaces => 'Only one person is allowed in frame.',
        ViolationType.noFace => 'Your face is not visible to the camera.',
        ViolationType.appMinimized => 'Switching apps during the exam is not allowed.',
        ViolationType.audioNoise => 'Unusual background noise detected.',
        ViolationType.copyPasteAttempt =>
          'Copying from, or pasting into, the exam is not allowed.',
        ViolationType.rightClickBlocked =>
          'The right-click menu is disabled during the exam.',
        ViolationType.devtoolsDetected =>
          'Browser developer tools are not allowed during the exam.',
        ViolationType.secondaryDisplayDetected =>
          'A second screen is connected. Disconnect it to continue.',
        ViolationType.virtualCameraDetected =>
          'The camera in use is not this device\'s own lens.',
        ViolationType.idleAfk =>
          'You have been away from the exam. Keep interacting with the screen.',
        null => 'Proctoring violation detected.',
      };

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        // Scrollable by construction: the warning, the chip and the one button
        // that gets the student back to work all belong to the same message, and
        // a phone in landscape (or a large accessibility text scale) has to be
        // able to reach that button instead of being handed a striped overflow.
        // The ConstrainedBox keeps the block centred while it still fits.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 64).clamp(0, double.infinity),
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isFinal ? Icons.block : Icons.warning_amber_rounded,
                      color: isFinal ? Colors.redAccent : Colors.amber,
                      size: 72,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      isFinal ? 'Exam Terminated' : 'Warning $warningCount / 3',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isFinal
                          ? 'You have exceeded the allowed number of proctoring '
                            'violations. Your exam has been automatically submitted '
                            'and marked as disqualified.'
                          : _message(type),
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    RiskIndexChip(
                      key: const Key('violation-risk'),
                      risk: risk,
                      onDark: true,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      risk.explanation,
                      key: const Key('violation-risk-explanation'),
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 32),
                    if (!isFinal)
                      ElevatedButton(
                        onPressed: onDismiss,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          child: Text('I understand, continue'),
                        ),
                      )
                    else
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                        onPressed: onDismiss, // routes back to login/home
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          child: Text('Exit'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
