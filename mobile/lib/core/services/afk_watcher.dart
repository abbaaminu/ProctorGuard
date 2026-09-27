import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;

/// Turns "nothing has happened on this device for a while" into a proctoring
/// signal for one attempt: the `idle_afk` violation.
///
/// It is the weakest signal in the proctoring set, so it is tuned to stay quiet.
/// The threshold is [defaultIdleThreshold] — three minutes, long enough that
/// reading a question, thinking about an answer or sitting through a long
/// scenario is never mistaken for a student who walked away — and an idle episode
/// is reported **once**, at the moment it starts, never again while it lasts.
/// Coming back re-arms it, so a second episode in the same attempt is a second
/// violation rather than a silent gap.
///
/// Activity is keyboard and pointer input: the exam screen calls [noteActivity]
/// for its own pointer events, and this class also listens to [HardwareKeyboard]
/// for keys (Flutter routes key events to whoever holds focus, which is not
/// necessarily a text field). Camera and microphone signals are deliberately
/// *not* activity — a student who left the room with the webcam running must
/// still be reported.
class AfkWatcher {
  AfkWatcher({
    required this.onIdle,
    this.idleThreshold = defaultIdleThreshold,
    this.checkInterval = defaultCheckInterval,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  /// Called once per idle episode, at the moment the threshold is crossed.
  final void Function() onIdle;

  /// How long the device may stay untouched before [onIdle] fires.
  final Duration idleThreshold;

  /// How often the elapsed time is compared against [idleThreshold].
  ///
  /// Coarse on purpose: the report is only ever this late, and a timer that
  /// wakes a phone once every 10 s for a 3-minute threshold is a battery price
  /// with nothing bought by it.
  final Duration checkInterval;

  /// Three minutes without a touch or a keystroke.
  static const Duration defaultIdleThreshold = Duration(minutes: 3);

  static const Duration defaultCheckInterval = Duration(seconds: 10);

  final DateTime Function() _now;

  Timer? _timer;
  DateTime? _lastActivityAt;
  bool _idleReported = false;
  bool _keyboardWatched = false;

  /// True between [start] and [stop].
  bool get isWatching => _timer != null;

  /// How long nothing has happened, or [Duration.zero] before [start].
  Duration get idleFor {
    final last = _lastActivityAt;
    if (last == null) return Duration.zero;
    return _now().difference(last);
  }

  /// Begins watching. Idempotent: a retry of the exam bootstrap cannot stack a
  /// second timer, and calling it again does not report an idle episode that is
  /// already in progress.
  void start() {
    if (_timer != null) return;
    _lastActivityAt = _now();
    _idleReported = false;
    _timer = Timer.periodic(checkInterval, (_) => _check());
    _watchKeyboard();
  }

  /// Records input: the exam screen calls this for every pointer event it sees.
  void noteActivity() {
    if (_lastActivityAt == null) return; // not watching
    _lastActivityAt = _now();
    _idleReported = false;
  }

  /// Stops watching and releases the key handler. Safe to call twice, and
  /// safe to follow with another [start].
  void stop() {
    _timer?.cancel();
    _timer = null;
    _unwatchKeyboard();
    _lastActivityAt = null;
    _idleReported = false;
  }

  void _check() {
    final last = _lastActivityAt;
    if (last == null || _idleReported) return;
    if (_now().difference(last) < idleThreshold) return;

    // Flagged before the callback runs: [onIdle] may take arbitrarily long (it
    // logs a violation, which can wait on the network), and the next tick must
    // not report the same episode again.
    _idleReported = true;
    onIdle();
  }

  void _watchKeyboard() {
    try {
      HardwareKeyboard.instance.addHandler(_onKeyEvent);
      _keyboardWatched = true;
    } catch (error) {
      // No binding (a pure Dart test, a background isolate): pointer activity
      // still counts, so the watch is merely less sensitive.
      debugPrint('ProctorGuard AFK: keyboard activity is not available: $error');
    }
  }

  void _unwatchKeyboard() {
    if (!_keyboardWatched) return;
    _keyboardWatched = false;
    try {
      HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    } catch (error) {
      debugPrint('ProctorGuard AFK: releasing the key handler failed: $error');
    }
  }

  /// Returns false so the key still reaches the widget tree — this is an
  /// observer, not a filter.
  bool _onKeyEvent(KeyEvent event) {
    noteActivity();
    return false;
  }
}
