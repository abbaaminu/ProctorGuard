import 'dart:async';

import 'web_guards_stub.dart'
    if (dart.library.js_interop) 'web_guards_web.dart' as impl;

/// Something the browser did that an exam session has to know about.
///
/// All of them mean the same thing for the student: they are no longer looking
/// at the exam, which is the `app_minimized` violation.
enum WebGuardEvent {
  /// `document.hidden` became true — another tab, a minimised browser, or the
  /// page was moved to the back/forward cache.
  tabHidden,

  /// The window lost keyboard focus (Alt+Tab, a second monitor, another app on
  /// top). `visibilityState` stays `visible` in that case, which is why the
  /// window's `blur` event needs its own listener.
  windowBlurred,

  /// HTML5 fullscreen ended after it had been entered — ESC, F11, or the
  /// browser's own escape affordance.
  fullscreenExited,
}

/// Browser-level exam guards for Chrome/Edge (and anything else Chromium-based):
/// tab-switch and blur detection plus HTML5 fullscreen enforcement.
///
/// Platform split: [WebGuards] is created through a conditional import, so the
/// DOM code (`web_guards_web.dart`, `package:web` + `dart:js_interop`) only ever
/// exists in a web build. Android/iOS/desktop and the Dart VM that runs
/// `flutter test` get [UnsupportedWebGuards], which reports
/// `isSupported == false` and stays silent — Android has lock task instead.
abstract class WebGuards {
  /// Picks the implementation for the platform this code was compiled for.
  factory WebGuards() => impl.createWebGuards();

  /// False on every non-web platform (and in VM widget tests).
  bool get isSupported;

  /// True while the document is in HTML5 fullscreen.
  bool get isFullscreen;

  /// Browser events; see [WebGuardEvent]. Never carries errors.
  Stream<WebGuardEvent> get events;

  /// Requests HTML5 fullscreen for the document element and reports whether it
  /// engaged.
  ///
  /// Chromium only honours this from a **user gesture**, so an automatic call at
  /// session start can legitimately fail ("API can only be initiated by a user
  /// gesture"). Callers should then offer a tap-to-enter prompt — the tap is the
  /// gesture. Never throws.
  Future<bool> enterFullscreen();

  /// Leaves fullscreen (a no-op when not in it). An exit the app asked for is
  /// **not** reported as `fullscreenExited`. Never throws.
  Future<void> exitFullscreen();

  /// Removes every DOM listener and closes [events]. Safe to call twice.
  void dispose();
}
