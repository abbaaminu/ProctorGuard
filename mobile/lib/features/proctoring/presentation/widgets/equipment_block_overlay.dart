import 'package:flutter/material.dart';

/// The barrier a proctored attempt cannot be continued past: the camera is not
/// feeding, the microphone is gone, or there is no face in frame.
///
/// Deliberately **not** a warning. A warning is a strike — it is counted, it
/// says "warning 2 / 3", and it has a button that dismisses it, because the
/// three-strike ladder is what ends an attempt. This is the equipment the
/// proctoring is *made of*: with the camera down nothing is watching, with the
/// microphone gone nothing is listening, and with nobody in frame there is
/// nothing to watch. So there is no "continue anyway" — the paper is covered
/// until the thing that broke works again, and the only buttons offered are the
/// ones that fix it (or leave the attempt).
///
/// It paints above [ViolationOverlay] for the same reason: dismissing a warning
/// is not a decision a student gets to make while unproctored, and the dismissal
/// button underneath is unreachable rather than merely discouraged.
///
/// It is opaque on purpose. A semi-transparent blocker would leave the question
/// text readable, which is the one thing an unproctored attempt must not be.
class EquipmentBlockOverlay extends StatelessWidget {
  const EquipmentBlockOverlay({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.settingsLabel,
    this.onSettings,
    this.onLeave,
  });

  final IconData icon;
  final String title;
  final String message;

  /// The fix: restart the camera, reconnect the microphone, retry access.
  final String? actionLabel;
  final VoidCallback? onAction;

  /// The other fix, for a permission the OS will not prompt for again.
  final String? settingsLabel;
  final VoidCallback? onSettings;

  /// Whether the student may walk away from the attempt. Always offered in
  /// practice: a block holds the *paper* shut, never the student hostage.
  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    final action = onAction;
    final settings = onSettings;

    return Material(
      // Fully opaque: see the class doc.
      color: Colors.black,
      child: SafeArea(
        // Scrollable by construction, like the warning overlay: a phone in
        // landscape or a large accessibility text scale must still reach the
        // buttons, and this screen has no other way out of it.
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
                    Icon(icon, color: Colors.redAccent, size: 72),
                    const SizedBox(height: 24),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    if (action != null && actionLabel != null)
                      ElevatedButton.icon(
                        key: const Key('equipment-block-action'),
                        onPressed: action,
                        icon: const Icon(Icons.refresh),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Text(actionLabel!),
                        ),
                      ),
                    if (settings != null && settingsLabel != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        key: const Key('equipment-block-settings'),
                        onPressed: settings,
                        icon: const Icon(Icons.settings_outlined),
                        label: Text(settingsLabel!),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                        ),
                      ),
                    ],
                    if (onLeave != null) ...[
                      const SizedBox(height: 8),
                      TextButton(
                        key: const Key('equipment-block-leave'),
                        onPressed: onLeave,
                        child: const Text(
                          'Leave',
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ],
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
