import 'package:flutter/material.dart';

import '../../domain/entities/violation.dart';

class ViolationOverlay extends StatelessWidget {
  final ViolationType? type;
  final int warningCount;
  final bool isFinal; // warningCount >= 3 -> disqualified, no dismiss
  final VoidCallback onDismiss;

  const ViolationOverlay({
    super.key,
    required this.type,
    required this.warningCount,
    required this.isFinal,
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
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
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
                const SizedBox(height: 32),
                if (!isFinal)
                  ElevatedButton(
                    onPressed: onDismiss,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      child: Text('I understand, continue'),
                    ),
                  )
                else
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                    onPressed: onDismiss, // routes back to login/home
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      child: Text('Exit'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
