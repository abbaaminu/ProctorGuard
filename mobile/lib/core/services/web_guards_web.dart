import 'dart:async';
import 'dart:js_interop';
// The bootstrap entry points are resolved by name on `window`, which is
// `dart:js_interop_unsafe`'s `hasProperty`/`callMethod`/`setProperty`.
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_guards.dart';

/// Creates the DOM-backed guards. Reached through [WebGuards]'s factory, so this
/// file is only compiled into a web build (see the conditional import there).
WebGuards createWebGuards() => WebGuardsImpl();

/// Tab-switch, blur and fullscreen detection for Chrome, Edge and the rest of
/// Chromium.
///
/// `visibilitychange` is the reliable half: Chromium fires it when the tab is
/// hidden, the window is minimised, and when the page is frozen/discarded, and
/// `document.visibilityState` is authoritative when it does. The window's `blur`
/// covers what visibility cannot see — another application or window moved in
/// front of the exam, where the document stays `visible` but stops receiving
/// focus. Blur fires while hidden as well, so it is filtered out here to avoid
/// reporting one tab switch twice.
///
/// A fullscreen **exit** only counts once fullscreen has been entered at least
/// once: an exam that never got fullscreen (no user gesture yet, or an iframe
/// without `allow="fullscreen"`) must not fire violations for a state it was
/// never in.
///
/// The exam lockdown ([startExamLockdown]) is split between this class and the
/// bootstrap script in `web/index.html`. The script blocks `copy`, `cut`,
/// `paste`, the context menu and the developer-tools shortcuts from the moment
/// the page loads - before Flutter has booted, which is a window a determined
/// student can act in. It keeps what it caught in a queue and exposes three
/// globals ([_bootstrapEnableFn], [_bootstrapDisableFn], [_bootstrapDrainFn]);
/// this class installs the reporter ([_bootstrapReporterFn]), enables the
/// lockdown for the length of an attempt, and replays the queued attempts as
/// violations. One reporter, so nothing is counted twice. If a host ships its
/// own `index.html` without that script, the fallback below registers the same
/// listeners here instead, so the lockdown still works (minus the pre-boot
/// window).
///
/// The second half of the lockdown is the developer-tools *geometry* probe: no
/// page can detect the DevTools panel directly, so this watches the gap between
/// the window's outer box and the viewport, which is what a docked panel widens.
/// It is a heuristic by nature, so it is deliberately slow (one probe every
/// [devtoolsProbeInterval]), confirmed over two probes, reported once per
/// episode, and tuned to stay quiet about ordinary browser chrome.
class WebGuardsImpl implements WebGuards {
  WebGuardsImpl() {
    _fullscreenConfirmed = web.document.fullscreenElement != null;
    _bootstrapAvailable = _window.hasProperty(_bootstrapEnableFn.toJS).toDart;

    // The listener references are kept so dispose() can detach exactly these
    // closures (an anonymous `.toJS` would leak a listener per session).
    _visibilityListener = _handleVisibilityChange.toJS;
    _blurListener = _handleBlur.toJS;
    _fullscreenListener = _handleFullscreenChange.toJS;

    web.document.addEventListener('visibilitychange', _visibilityListener);
    web.document.addEventListener('fullscreenchange', _fullscreenListener);
    web.window.addEventListener('blur', _blurListener);
  }

  /// Global entry points published by the bootstrap script in `web/index.html`.
  ///
  /// Resolved by name on [web.window] rather than through a JS interface, because
  /// the script is loaded before the compiled app and has to stay plain ES5-ish
  /// JavaScript that a host can read: see the comment there.
  /// [web.window] as a plain [JSObject]: the receiver the
  /// `dart:js_interop_unsafe` name lookups are declared on, which is how the
  /// bootstrap globals are reached without a Dart-visible interface.
  JSObject get _window => web.window;

  static const String _bootstrapEnableFn = 'enableProctorGuardLockdown';
  static const String _bootstrapDisableFn = 'disableProctorGuardLockdown';
  static const String _bootstrapDrainFn = 'drainProctorGuardBlockedEvents';
  static const String _bootstrapReporterFn = 'proctorGuardReporter';

  /// How often the developer-tools geometry probe samples the window.
  ///
  /// Two seconds is slower than a student can open and close a panel on purpose,
  /// and that is the point: this signal is an accusation, so it prefers a
  /// sustained gap over catching a fast flash.
  static const Duration devtoolsProbeInterval = Duration(seconds: 2);

  /// The viewport-to-window gap (CSS pixels) that is attributed to a docked
  /// developer-tools panel instead of to browser chrome.
  ///
  /// Chrome's own toolbar, tab strip, bookmarks bar and download shelf total
  /// roughly 80-100 px vertically, while a docked DevTools panel refuses to be
  /// smaller than about 100 px in either direction (and its usual dock is
  /// 200-300 px). 160 px therefore clears every piece of ordinary chrome this
  /// app has been measured against. A false positive would tell a student they
  /// used developer tools when they did not, which is worse than missing an
  /// unusually thin panel - hence not a tighter threshold.
  static const int devtoolsGapPx = 160;

  final StreamController<WebGuardEvent> _events =
      StreamController<WebGuardEvent>.broadcast();

  late final JSFunction _visibilityListener;
  late final JSFunction _blurListener;
  late final JSFunction _fullscreenListener;

  /// True when `web/index.html` published the bootstrap, so the lockdown is
  /// enforced there instead of by [startExamLockdown]'s own listeners.
  late final bool _bootstrapAvailable;

  // The fallback listeners, created on first use (a `late final` initialiser
  // runs only in the no-bootstrap path).
  late final JSFunction _copyListener = _handleCopy.toJS;
  late final JSFunction _cutListener = _handleCut.toJS;
  late final JSFunction _pasteListener = _handlePaste.toJS;
  late final JSFunction _contextMenuListener = _handleContextMenu.toJS;

  /// The Dart callback the bootstrap calls with a blocked event's name.
  JSFunction? _reporter;

  bool _fullscreenConfirmed = false;

  /// True once an exit has been reported, so the next entry can be recognised as a
  /// *re*-entry (and reported as [WebGuardEvent.fullscreenEntered]).
  bool _exitReported = false;
  bool _disposed = false;

  /// True between [startExamLockdown] and [stopExamLockdown].
  bool _lockdownActive = false;
  Timer? _devtoolsProbe;
  bool _devtoolsSuspect = false;
  bool _devtoolsReported = false;

  @override
  bool get isSupported => true;

  @override
  bool get isFullscreen => web.document.fullscreenElement != null;

  @override
  bool get supportsExamLockdown => true;

  @override
  Stream<WebGuardEvent> get events => _events.stream;

  void _handleVisibilityChange(web.Event _) {
    if (_disposed) return;
    if (web.document.visibilityState == 'hidden') {
      _events.add(WebGuardEvent.tabHidden);
    }
  }

  void _handleBlur(web.Event _) {
    if (_disposed) return;
    if (web.document.visibilityState == 'hidden') return; // already tabHidden
    _events.add(WebGuardEvent.windowBlurred);
  }

  void _handleFullscreenChange(web.Event _) {
    if (_disposed) return;
    if (isFullscreen) {
      final reentered = _fullscreenConfirmed == false && _exitReported;
      _fullscreenConfirmed = true;
      _exitReported = false;
      // Only a *re*-entry is worth reporting: the first one is the result of
      // `enterFullscreen()`, which the caller already knows about, while this is
      // the student taking the "return to fullscreen" offer - and it is what
      // cancels the countdown before it becomes a strike.
      if (reentered) _events.add(WebGuardEvent.fullscreenEntered);
      return;
    }
    if (!_fullscreenConfirmed) return; // never entered: nothing to exit from
    _fullscreenConfirmed = false;
    _exitReported = true;
    _events.add(WebGuardEvent.fullscreenExited);
  }

  // --- Exam lockdown --------------------------------------------------

  /// Suppresses an event and reports which one it was. `stopPropagation` matters
  /// as much as `preventDefault` here: the copy/paste itself is what has to be
  /// stopped from reaching Flutter's text field, and only a capture-phase
  /// listener at the document can do that before the app's own element handles
  /// it.
  void _block(web.Event event, WebGuardEvent reported) {
    event.preventDefault();
    event.stopPropagation();
    if (_disposed || !_lockdownActive) return;
    _events.add(reported);
  }

  void _handleCopy(web.Event event) =>
      _block(event, WebGuardEvent.copyBlocked);

  void _handleCut(web.Event event) => _block(event, WebGuardEvent.cutBlocked);

  void _handlePaste(web.Event event) =>
      _block(event, WebGuardEvent.pasteBlocked);

  void _handleContextMenu(web.Event event) {
    // Only the menu is refused here, not propagation: the violation is the
    // attempt, and Flutter still gets to decide what a long-press means inside
    // its own widgets.
    event.preventDefault();
    if (_disposed || !_lockdownActive) return;
    _events.add(WebGuardEvent.contextMenuBlocked);
  }

  /// The bootstrap's callback: `proctorGuardReporter('copy')`.
  void _reportBootstrapBlock(JSString type) {
    if (_disposed || !_lockdownActive) return;
    _handleBlockedName(type.toDart);
  }

  /// Maps one blocked DOM event name to the violation it is evidence of.
  ///
  /// Cut joins copy under `copy_paste_attempt`: the browser reports them as two
  /// events but they are one behaviour, and the schema has no separate
  /// `cut_attempt` to log them under.
  void _handleBlockedName(String name) {
    switch (name) {
      case 'copy':
        _events.add(WebGuardEvent.copyBlocked);
      case 'cut':
        _events.add(WebGuardEvent.cutBlocked);
      case 'paste':
        _events.add(WebGuardEvent.pasteBlocked);
      case 'contextmenu':
        _events.add(WebGuardEvent.contextMenuBlocked);
      case 'devtools':
        // A developer-tools shortcut the bootstrap caught. Recorded here so the
        // geometry probe does not report the same open panel a second time.
        _devtoolsReported = true;
        _events.add(WebGuardEvent.devtoolsDetected);
    }
  }

  /// Replays what the bootstrap blocked while the app was still booting. An empty
  /// list both when nothing happened and when the queue is unreadable.
  List<String> _drainBootstrapBlocks() {
    try {
      final drained =
          _window.callMethod<JSArray<JSString>>(_bootstrapDrainFn.toJS);
      return [for (final entry in drained.toDart) entry.toDart];
    } catch (_) {
      return const <String>[];
    }
  }

  @override
  void startExamLockdown() {
    if (_disposed || _lockdownActive) return;
    _lockdownActive = true;

    if (_bootstrapAvailable) {
      // Reporter first, then enable, then drain: anything the student does
      // between enabling and draining lands in the queue instead of a gap.
      try {
        _reporter = _reportBootstrapBlock.toJS;
        _window.setProperty(_bootstrapReporterFn.toJS, _reporter);
        _window.callMethod(_bootstrapEnableFn.toJS);
        for (final blocked in _drainBootstrapBlocks()) {
          _handleBlockedName(blocked);
        }
      } catch (_) {
        // A host script that only half-defines the globals: the lockdown is then
        // simply not enforced in the browser, exactly as if index.html had no
        // bootstrap at all. Never fatal for the exam itself.
      }
    } else {
      // No bootstrap (a host with its own index.html): listen here instead, so
      // the lockdown still covers the page - minus the pre-boot window.
      final capture = web.AddEventListenerOptions(capture: true);
      web.document.addEventListener('copy', _copyListener, capture);
      web.document.addEventListener('cut', _cutListener, capture);
      web.document.addEventListener('paste', _pasteListener, capture);
      web.document.addEventListener(
        'contextmenu',
        _contextMenuListener,
        capture,
      );
    }

    _devtoolsProbe ??= Timer.periodic(devtoolsProbeInterval, (_) {
      _probeDevtools();
    });
    _probeDevtools();
  }

  @override
  void stopExamLockdown() {
    if (!_lockdownActive) return;
    _lockdownActive = false;

    _devtoolsProbe?.cancel();
    _devtoolsProbe = null;
    _devtoolsSuspect = false;
    _devtoolsReported = false;

    if (_bootstrapAvailable) {
      try {
        _window.callMethod(_bootstrapDisableFn.toJS);
        // Drop the reporter too: a page that is no longer examining must not
        // hold a Dart closure on to app state from JavaScript.
        _window.setProperty(_bootstrapReporterFn.toJS, null);
      } catch (_) {
        // Same as start(): the host script is not ours to rely on.
      }
    } else {
      web.document.removeEventListener('copy', _copyListener);
      web.document.removeEventListener('cut', _cutListener);
      web.document.removeEventListener('paste', _pasteListener);
      web.document.removeEventListener('contextmenu', _contextMenuListener);
    }
    _reporter = null;
  }

  /// One sample of the window-vs-viewport geometry.
  ///
  /// Nothing is reported inside a hidden tab or without a usable outer box (an
  /// embedded webview, and some mobile browsers, report 0): those are exactly the
  /// cases where a huge negative gap would otherwise look like a wide-open panel.
  /// A *positive* gap only, because zooming the page out makes the viewport
  /// larger than the window and that is not a developer-tools panel either.
  void _probeDevtools() {
    if (_disposed || !_lockdownActive) return;
    if (web.document.visibilityState == 'hidden') return;

    final outerWidth = web.window.outerWidth;
    final outerHeight = web.window.outerHeight;
    if (outerWidth <= 0 || outerHeight <= 0) return;

    final horizontal = outerWidth - web.window.innerWidth;
    final vertical = outerHeight - web.window.innerHeight;
    final suspect = horizontal >= devtoolsGapPx || vertical >= devtoolsGapPx;

    if (!suspect) {
      // Nothing is docked, or the panel just closed: the episode is over, so a
      // later re-open is reported again.
      _devtoolsSuspect = false;
      _devtoolsReported = false;
      return;
    }
    if (_devtoolsReported) return;
    if (!_devtoolsSuspect) {
      // First sighting. A window being resized produces the same gap once, so
      // require it to survive a second probe before accusing anyone.
      _devtoolsSuspect = true;
      return;
    }
    _devtoolsReported = true;
    _events.add(WebGuardEvent.devtoolsDetected);
  }

  @override
  Future<bool> enterFullscreen() async {
    if (_disposed) return false;
    if (isFullscreen) return true;

    final element = web.document.documentElement;
    if (element == null) return false;

    try {
      await element.requestFullscreen().toDart;
    } catch (_) {
      // No user gesture, a permission policy, or an iframe without
      // allow="fullscreen". The caller offers a tap-to-enter prompt instead.
      return false;
    }
    return isFullscreen;
  }

  @override
  Future<void> exitFullscreen() async {
    if (!isFullscreen) return;
    // Mark it before asking, so the app's own exit is not reported as a
    // violation (same rule as the Android kiosk escape).
    _fullscreenConfirmed = false;
    try {
      await web.document.exitFullscreen().toDart;
    } catch (_) {
      // Already out, or the browser refused: nothing left to restore.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    // Release the lockdown before closing the stream: it detaches the DOM
    // listeners (or the bootstrap) as well, so a disposed guard leaves no page
    // blocked and no timer running.
    stopExamLockdown();
    _disposed = true;
    web.document.removeEventListener('visibilitychange', _visibilityListener);
    web.document.removeEventListener('fullscreenchange', _fullscreenListener);
    web.window.removeEventListener('blur', _blurListener);
    _events.close();
  }
}
