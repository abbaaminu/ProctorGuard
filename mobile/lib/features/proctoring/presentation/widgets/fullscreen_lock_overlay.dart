import 'package:flutter/material.dart';

/// Blocking overlay for a student who left HTML5 fullscreen mid-exam.
///
/// Deliberately not a warning snack bar: the exam surface is locked, so the
/// countdown has to be *in front of* it, and the only action on screen has to be
/// the one that fixes the problem. The button is also what makes Chromium accept
/// the re-entry - `requestFullscreen()` is only honoured from a user gesture.
///
/// Leaving fullscreen is not a violation until [remaining] runs out, so this is a
/// chance to come back rather than a strike (see `WebExamGuard.fullscreenGrace`).
class FullscreenLockOverlay extends StatelessWidget {
  const FullscreenLockOverlay({
    super.key,
    required this.remaining,
    required this.onReturnToFullscreen,
  });

  /// Time left before the exit is logged as a violation.
  final Duration remaining;

  final VoidCallback onReturnToFullscreen;

  /// Whole seconds left, rounded up, never negative: at 4.2 s the student sees
  /// "5", which matches the "within 5 seconds" the text promises.
  int get secondsLeft {
    final milliseconds = remaining.inMilliseconds;
    if (milliseconds <= 0) return 0;
    return (milliseconds / 1000).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = secondsLeft;

    return Material(
      color: Colors.black.withValues(alpha: 0.94),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.fullscreen_exit, color: Colors.amber, size: 72),
                const SizedBox(height: 24),
                const Text(
                  'Fullscreen required',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  key: const Key('fullscreen-countdown'),
                  seconds == 0
                      ? 'Logging this as a proctoring violation...'
                      : 'Return to fullscreen within $seconds '
                          '${seconds == 1 ? 'second' : 'seconds'} or this is '
                          'logged as a violation.',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  key: const Key('fullscreen-return'),
                  onPressed: onReturnToFullscreen,
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Return to fullscreen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
