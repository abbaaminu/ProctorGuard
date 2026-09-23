import 'dart:async';

import 'web_guards.dart';

/// Turns browser guard events into exam violations for one session.
///
/// Kept out of the exam page (and out of the DOM) so the rules that matter are
/// unit-testable on the VM, the same way `ExamLifecycleObserver` is: one
/// subscription per session, a startup grace, and stop() releasing everything.
/// The platform implementation owns the one DOM-shaped rule — a fullscreen exit
/// only counts after a confirmed entry.
class WebExamGuard {
  WebExamGuard({
    required this.guards,
    required this.onViolation,
    this.startupGrace = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final WebGuards guards;

  /// Called for every browser event that should become an `app_minimized`
  /// strike. The notifier's own 2s debounce still collapses bursts.
  final void Function(WebGuardEvent event) onViolation;

  /// How long after [start] browser events are ignored.
  ///
  /// Starting an exam legitimately disturbs focus — the camera permission
  /// prompt, the fullscreen transition, the browser's own media indicator — and
  /// none of that is cheating. A few seconds is enough for those to settle while
  /// still catching a student who switches away after reading question 1.
  final Duration startupGrace;

  final DateTime Function() _now;

  StreamSubscription<WebGuardEvent>? _subscription;
  DateTime? _startedAt;
  bool _fullscreenEntered = false;
  bool _stopped = false;

  /// True while the document is in fullscreen right now.
  bool get isFullscreen => guards.isFullscreen;

  /// True once fullscreen engaged at least once this session.
  bool get fullscreenEnteredThisSession => _fullscreenEntered;

  /// Requests fullscreen and starts listening. Returns whether the browser
  /// engaged fullscreen — Chromium requires a user gesture, so an exam opened by
  /// navigation often gets `false` and the page then offers a tap.
  Future<bool> start() async {
    _startedAt = _now();
    _subscription ??= guards.events.listen(_handle);
    if (!guards.isSupported) return false;
    _fullscreenEntered = await guards.enterFullscreen();
    return _fullscreenEntered;
  }

  /// A second attempt from a user gesture (the "Enter" prompt button).
  Future<bool> requestFullscreen() async {
    final entered = await guards.enterFullscreen();
    _fullscreenEntered = _fullscreenEntered || entered;
    return entered;
  }

  void _handle(WebGuardEvent event) {
    final startedAt = _startedAt;
    if (startedAt == null) return; // stopped: the session is over
    if (_now().difference(startedAt) < startupGrace) return;
    onViolation(event);
  }

  /// Stops listening, leaves fullscreen and releases the DOM listeners: a
  /// finished exam must neither trap the student in fullscreen nor keep counting
  /// strikes. Safe to call twice.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _startedAt = null;
    await _subscription?.cancel();
    _subscription = null;
    await guards.exitFullscreen();
    guards.dispose();
  }
}
