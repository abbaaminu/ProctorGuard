import 'package:flutter/material.dart';

import '../../../../core/services/audio_monitor.dart';
import '../providers/audio_monitoring_provider.dart';

/// The live microphone badge for an exam attempt (see [AudioMonitor]).
///
/// Sits in the question pane's chip row next to the kiosk badge, in the same
/// tooltip + icon + label shape, because the two things it has to communicate are
/// exactly the ones that must never be invisible:
///
///  * **audio proctoring is running** - a green mic, with the room level bar and
///    the line the level has to cross before it is a strike;
///  * **it is not running, and here is why** - a distinct label per
///    [AudioMonitorState], in the student's words (see [AudioMonitorStateX.label]).
///
/// | what happened | what the student sees |
/// | --- | --- |
/// | levels are flowing | green `Mic live` + the live meter |
/// | over the threshold, sustain window still open | the same mic, amber |
/// | inside the post-strike cooldown | `Mic live`, meter greyed |
/// | access refused | red `Mic blocked` + the settings action |
/// | device unplugged / permission revoked mid-session | red `Mic lost` |
/// | platform has no capture path | `Mic unavailable` |
/// | `--dart-define=AUDIO_MONITORING=false` | grey `Audio off` |
///
/// Tapping is the recovery path ([onRetry] -> `AudioMonitoringNotifier.retry`),
/// and [onOpenSettings] is passed only for a refusal - the one case where asking
/// again cannot help, because Android and iOS stop prompting after two "don't
/// allow"s. That mirrors how the blocking screen handles a refused camera.
class AudioMonitorIndicator extends StatelessWidget {
  const AudioMonitorIndicator({
    super.key,
    required this.state,
    required this.onRetry,
    this.onOpenSettings,
    this.showMeter = true,
  });

  /// The attempt's microphone state, straight from `audioMonitoringProvider`.
  final AudioMonitoringState state;

  /// Re-opens the microphone after access was refused or the device went away.
  final VoidCallback onRetry;

  /// Opens the OS app-settings page. Non-null only for a refusal.
  final VoidCallback? onOpenSettings;

  /// Draws the level/threshold meter. Off for a very narrow chip row.
  final bool showMeter;

  /// True when tapping the chip does something: a state the student can fix, or a
  /// microphone that was never opened. While levels are flowing there is nothing to
  /// re-open, and a stray tap would only throw the calibration away.
  bool get _canRetry =>
      state.needsAttention || state.monitor == AudioMonitorState.idle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_icon, size: 18, color: _colour),
        const SizedBox(width: 4),
        Text(state.monitor.label, style: theme.textTheme.labelMedium),
        if (showMeter && state.isActive) ...[
          const SizedBox(width: 6),
          _LevelMeter(state: state),
        ],
      ],
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: _explanation(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Semantics(
              // The icon is decorative; the label and the tooltip carry the
              // meaning, so a screen reader reads "Microphone: Mic live".
              label: 'Microphone: ${state.monitor.label}',
              child: _canRetry
                  ? InkWell(
                      key: const Key('audio-indicator-retry'),
                      onTap: onRetry,
                      borderRadius: BorderRadius.circular(6),
                      child: chip,
                    )
                  : chip,
            ),
          ),
        ),
        if (onOpenSettings != null)
          IconButton(
            key: const Key('audio-indicator-settings'),
            tooltip: 'Open microphone settings',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
      ],
    );
  }

  /// Icon per state. The mic turns amber while the level is over the threshold but
  /// has not stayed there long enough to be a strike: that is the one state that
  /// means "something is building", and the reason the badge is a live meter rather
  /// than a static "recording" dot.
  IconData get _icon {
    if (state.isActive) return Icons.mic;
    return switch (state.monitor) {
      AudioMonitorState.idle => Icons.mic_none,
      AudioMonitorState.starting => Icons.mic_none,
      AudioMonitorState.monitoring => Icons.mic,
      AudioMonitorState.permissionDenied => Icons.mic_off,
      AudioMonitorState.unavailable => Icons.mic_off,
      AudioMonitorState.interrupted => Icons.mic_off,
      AudioMonitorState.disabled => Icons.mic_off,
    };
  }

  /// Red is "the student has to do something", amber "something is building",
  /// orange "this device cannot do it" (not the student's fault, so not red), grey
  /// "deliberately off", green "all good".
  Color get _colour {
    if (state.isActive) return state.noisy ? Colors.amber : Colors.green;
    return switch (state.monitor) {
      AudioMonitorState.idle => Colors.grey,
      AudioMonitorState.starting => Colors.blueGrey,
      AudioMonitorState.monitoring => Colors.green,
      AudioMonitorState.permissionDenied => Colors.redAccent,
      AudioMonitorState.interrupted => Colors.redAccent,
      AudioMonitorState.unavailable => Colors.orange,
      AudioMonitorState.disabled => Colors.grey,
    };
  }

  /// The long form: state, the live numbers behind it, the strike count, and the
  /// student-facing explanation when the monitor has one.
  ///
  /// The numbers live here rather than in the chip because they are what a
  /// supervisor asks about after the fact - "why did I get an audio warning?" is
  /// answered by "the room was at -18 dBFS, and anything over -30 counted".
  String _explanation() {
    final parts = <String>[
      if (state.monitor == AudioMonitorState.monitoring && !state.calibrated)
        'Audio proctoring: measuring the room'
      else
        'Audio proctoring: ${state.monitor.label}',
    ];

    final level = state.levelDb;
    if (level != null) parts.add('room ${level.toStringAsFixed(0)} dBFS');

    final threshold = state.thresholdDb;
    if (threshold != null && state.calibrated) {
      parts.add('counts above ${threshold.toStringAsFixed(0)} dBFS');
    }

    final peak = state.peakDb;
    if (peak != null && threshold != null && peak > threshold) {
      parts.add('loudest ${peak.toStringAsFixed(0)} dBFS');
    }

    if (state.violations > 0) {
      parts.add(
        '${state.violations} audio alert'
        '${state.violations == 1 ? '' : 's'} logged',
      );
    }

    final message = state.message;
    if (message != null) parts.add(message);

    return parts.join(' · ');
  }
}

/// The live room level as a bar, with the calibrated strike threshold drawn across
/// it, so "how close was that to a warning?" is visible without reading numbers.
///
/// Both the level and the threshold are fractions of a -60..0 dBFS window (see
/// [AudioMonitoringState.levelFraction]), which is the range a normal exam room
/// actually moves in: the full -90..0 dBFS span would leave the bar permanently
/// empty.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.state});

  final AudioMonitoringState state;

  static const double _width = 36;
  static const double _height = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = state.levelFraction;
    final threshold = state.thresholdFraction;

    // Grey inside the cooldown: the detector is deliberately ignoring the level,
    // and a bar that kept painting red would look like it had stopped working.
    final barColour = state.coolingDown
        ? theme.colorScheme.outline
        : state.isAboveThreshold
            ? Colors.redAccent
            : Colors.green;

    return SizedBox(
      key: const Key('audio-indicator-meter'),
      width: _width,
      height: _height,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(3),
            ),
            child: const SizedBox(width: _width, height: _height),
          ),
          FractionallySizedBox(
            widthFactor: level,
            child: Container(
              height: _height,
              decoration: BoxDecoration(
                color: barColour,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          if (state.calibrated)
            Positioned(
              left: (threshold * _width).clamp(0, _width - 1).toDouble(),
              top: 0,
              child: Container(
                width: 1,
                height: _height,
                color: theme.colorScheme.onSurface,
              ),
            ),
        ],
      ),
    );
  }
}
