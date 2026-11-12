import 'dart:async';

import 'web_guards.dart';

/// Turns browser guard events into exam violations for one session.
///
/// Kept out of the exam page (and out of the DOM) so the rules that matter are
/// unit-testable on the VM, the same way `ExamLifecycleObserver` is: one
/// subscription per session, a startup grace, and stop() releasing everything.
/// The platform implementation owns the one DOM-shaped rule — a fullscreen exit
/// only counts after a confirmed entry.
///
/// One act costs one strike. A minimise reaches this class as a blur or a hidden
/// tab *and*, a moment later, as a fullscreen exit; the first is a strike on the
/// spot, the second only opens a countdown, and if that countdown belongs to the
/// same departure it closes without charging again (see [_sameDeparture]).
///
/// Beyond focus and fullscreen it also drives the *lockdown* (see
/// [WebGuards.startExamLockdown]): copy/cut/paste, the context menu and a
/// developer-tools panel are reported through the same [onViolation] callback,
/// and [stop] releases them so a finished exam leaves the browser unlocked.
class WebExamGuard {
  WebExamGuard({
    required this.guards,
    required this.onViolation,
    this.onFullscreenExitPending,
    this.onFullscreenRestored,
    this.startupGrace = const Duration(seconds: 5),
    this.fullscreenGrace = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final WebGuards guards;

  /// Called for every browser event that should become a strike. The page maps
  /// the event to the violation it is evidence of: leaving the surface
  /// (`tabHidden`, `windowBlurred`, an expired fullscreen exit) is
  /// `app_minimized`, while the lockdown events are copy/paste, right-click and
  /// developer-tools evidence.
  final void Function(WebGuardEvent event) onViolation;

  /// Called the moment the student leaves fullscreen: the cue for the page to show
  /// its blocking overlay with the countdown. No violation has been logged yet.
  final void Function()? onFullscreenExitPending;

  /// Called when fullscreen came back inside the grace window: hide that overlay,
  /// nothing was logged.
  final void Function()? onFullscreenRestored;

  /// How long the student has to return to fullscreen before the exit is logged
  /// as a violation.
  ///
  /// Fullscreen is the only signal that is *recoverable* in a few seconds, so it
  /// gets a window instead of an instant strike: the overlay counts down (see
  /// [fullscreenExitDeadline]) and the page's "return" button supplies the user
  /// gesture Chromium needs. Leaving and staying out still costs a strike.
  final Duration fullscreenGrace;

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

  Timer? _graceTimer;
  bool _gracePending = false;
  DateTime? _graceDeadline;

  /// True when the countdown now open belongs to a departure that has already
  /// been struck for, so that it must not be struck again — see [_sameDeparture].
  bool _graceSameAct = false;

  /// When the student was last struck for leaving the exam surface
  /// ([WebGuardEvent.tabHidden] or [WebGuardEvent.windowBlurred]).
  ///
  /// One minimise can speak twice: the window loses focus, and the browser drops
  /// out of fullscreen a moment later. The exit is then the trailing half of an
  /// act that has already cost an `app_minimized`, not a second act.
  DateTime? _departureStruckAt;

  /// True once a fullscreen exit has cost a strike since fullscreen was last
  /// entered, so that staying out of it cannot be charged twice however often
  /// the page re-asserts the requirement ([reassertFullscreen]).
  bool _exitCharged = false;

  /// True while the document is in fullscreen right now.
  bool get isFullscreen => guards.isFullscreen;

  /// True once fullscreen engaged at least once this session.
  bool get fullscreenEnteredThisSession => _fullscreenEntered;

  /// Requests fullscreen and starts listening. Returns whether the browser
  /// engaged fullscreen — Chromium requires a user gesture, so an exam opened by
  /// navigation often gets `false` and the page then offers a tap.
  Future<bool> start() async {
    _startedAt = _now();
    _departureStruckAt = null;
    _exitCharged = false;
    _subscription ??= guards.events.listen(_handle);
    // The lockdown goes on before the fullscreen transition, and after the
    // subscription above, for two reasons: the transition's own blur/fullscreen
    // events are then already being filtered, and [WebGuards.startExamLockdown]
    // replays whatever the pre-boot bootstrap script blocked while the app was
    // still loading — events that have to land somewhere. It is a no-op where the
    // platform has no DOM (`UnsupportedWebGuards`).
    guards.startExamLockdown();
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

    // Fullscreen bookkeeping runs even inside the start-up grace: it only opens or
    // closes the countdown below, and never logs anything by itself.
    if (event == WebGuardEvent.fullscreenEntered) {
      // Back on the exam surface: the departure is over, and the next exit is a
      // new act that may cost a strike again.
      _departureStruckAt = null;
      _exitCharged = false;
      if (_finishFullscreenGrace()) onFullscreenRestored?.call();
      return;
    }

    if (_now().difference(startedAt) < startupGrace &&
        !_isLockdownEvent(event)) {
      return;
    }

    if (event == WebGuardEvent.fullscreenExited) {
      _beginFullscreenGrace(sameAct: _sameDeparture());
      return;
    }

    // A blur or a hidden tab is a strike on the spot, and it is also the first
    // half of the departure whose second half may be a fullscreen exit.
    if (event == WebGuardEvent.tabHidden ||
        event == WebGuardEvent.windowBlurred) {
      _departureStruckAt = _now();
    }
    onViolation(event);
  }

  /// True when this fullscreen exit is the trailing half of a departure that has
  /// already been struck for.
  ///
  /// Minimising a window is one act that Chromium can report twice: the window
  /// loses focus immediately, and fullscreen follows. Charging both would take
  /// two of the three strikes that close an attempt from a single careless
  /// moment. The window here is [fullscreenGrace] because that is exactly the
  /// period in which an exit is *not* a strike yet — a departure inside it is the
  /// same act, while an ESC pressed from inside fullscreen, later, is a new one.
  bool _sameDeparture() {
    final struckAt = _departureStruckAt;
    return struckAt != null && _now().difference(struckAt) < fullscreenGrace;
  }

  /// True for the events the lockdown produces — something the student *did*
  /// rather than a way the exam lost focus.
  ///
  /// They are the one family that is exempt from [startupGrace]: a copy attempt
  /// cannot be caused by the camera permission dialog or the fullscreen
  /// transition, and the attempts the bootstrap script blocked *before* the app
  /// booted are replayed here at `start()` — which is, by definition, inside the
  /// grace window. Filtering them would silently discard exactly the evidence
  /// that window exists to catch.
  static bool _isLockdownEvent(WebGuardEvent event) => switch (event) {
        WebGuardEvent.copyBlocked ||
        WebGuardEvent.cutBlocked ||
        WebGuardEvent.pasteBlocked ||
        WebGuardEvent.contextMenuBlocked ||
        WebGuardEvent.devtoolsDetected =>
          true,
        WebGuardEvent.tabHidden ||
        WebGuardEvent.windowBlurred ||
        WebGuardEvent.fullscreenExited ||
        WebGuardEvent.fullscreenEntered =>
          false,
      };

  /// True while a fullscreen exit is inside its grace window (the overlay is up).
  bool get fullscreenExitPending => _gracePending;

  /// When the pending window closes, or null when nothing is pending. The page
  /// renders its countdown from this, so the number on screen and the number the
  /// guard acts on are the same deadline.
  DateTime? get fullscreenExitDeadline => _graceDeadline;

  /// Turns a pending fullscreen exit into a strike **now**.
  ///
  /// The exam page calls this when its visible countdown reaches zero, so the
  /// strike lands exactly when the student stops seeing the counter. The timer
  /// started in [_beginFullscreenGrace] is the safety net for a page that never
  /// calls it. Idempotent, so the two racing is harmless.
  ///
  /// A countdown that belongs to an already-struck departure, or to an exit that
  /// has already been charged, closes without a violation: the student was still
  /// asked back, and the attempt pays once for the one act.
  void expireFullscreenGrace() {
    if (!_gracePending) return;
    final charges = !_graceSameAct && !_exitCharged;
    _finishFullscreenGrace();
    if (!charges) return;
    _exitCharged = true;
    onViolation(WebGuardEvent.fullscreenExited);
  }

  /// Re-asserts the requirement after the page comes back to the foreground: if
  /// fullscreen was entered this session and is not active now, the countdown
  /// starts under exactly the same rule as a `fullscreenchange` would.
  void reassertFullscreen() {
    if (_stopped || !_fullscreenEntered || guards.isFullscreen) return;
    _beginFullscreenGrace(sameAct: _sameDeparture());
  }

  void _beginFullscreenGrace({bool sameAct = false}) {
    if (_stopped || _gracePending) return; // one countdown per exit
    _gracePending = true;
    _graceSameAct = sameAct;
    _graceDeadline = _now().add(fullscreenGrace);
    _graceTimer = Timer(fullscreenGrace, expireFullscreenGrace);
    onFullscreenExitPending?.call();
  }

  /// Returns whether a countdown was actually open, so callers only announce a
  /// restore when there was something to restore.
  bool _finishFullscreenGrace() {
    final pending = _gracePending;
    _gracePending = false;
    _graceSameAct = false;
    _graceDeadline = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    return pending;
  }

  /// Stops listening, leaves fullscreen and releases the DOM listeners: a
  /// finished exam must neither trap the student in fullscreen nor keep counting
  /// strikes. Safe to call twice.
  ///
  /// The subscription cancellation is fire-and-forget — the guard ignores every
  /// later event anyway (`_startedAt == null`) — so a stalled platform stream
  /// cannot hold up the caller (bootstrap, retry or dispose).
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _startedAt = null;
    // A session that ends mid-countdown must not log the strike it was holding:
    // leaving fullscreen on the way out is not cheating, it is closing the exam.
    _finishFullscreenGrace();
    unawaited(_subscription?.cancel());
    _subscription = null;
    // Release the clipboard, the context menu and the geometry probe before
    // leaving fullscreen: a finished exam must not keep the student's browser
    // locked (and the DOM is unblocked as early as possible on the way out).
    guards.stopExamLockdown();
    await guards.exitFullscreen();
    guards.dispose();
  }
}
