import 'dart:async';
import 'dart:js_interop';

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
class WebGuardsImpl implements WebGuards {
  WebGuardsImpl() {
    _fullscreenConfirmed = web.document.fullscreenElement != null;

    // The listener references are kept so dispose() can detach exactly these
    // closures (an anonymous `.toJS` would leak a listener per session).
    _visibilityListener = _handleVisibilityChange.toJS;
    _blurListener = _handleBlur.toJS;
    _fullscreenListener = _handleFullscreenChange.toJS;

    web.document.addEventListener('visibilitychange', _visibilityListener);
    web.document.addEventListener('fullscreenchange', _fullscreenListener);
    web.window.addEventListener('blur', _blurListener);
  }

  final StreamController<WebGuardEvent> _events =
      StreamController<WebGuardEvent>.broadcast();

  late final JSFunction _visibilityListener;
  late final JSFunction _blurListener;
  late final JSFunction _fullscreenListener;

  bool _fullscreenConfirmed = false;
  bool _disposed = false;

  @override
  bool get isSupported => true;

  @override
  bool get isFullscreen => web.document.fullscreenElement != null;

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
      _fullscreenConfirmed = true;
      return;
    }
    if (!_fullscreenConfirmed) return; // never entered: nothing to exit from
    _fullscreenConfirmed = false;
    _events.add(WebGuardEvent.fullscreenExited);
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
    _disposed = true;
    web.document.removeEventListener('visibilitychange', _visibilityListener);
    web.document.removeEventListener('fullscreenchange', _fullscreenListener);
    web.window.removeEventListener('blur', _blurListener);
    _events.close();
  }
}
