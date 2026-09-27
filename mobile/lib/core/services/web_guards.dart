import 'dart:async';

import 'web_guards_stub.dart'
    if (dart.library.js_interop) 'web_guards_web.dart' as impl;

/// Something the browser did that an exam session has to know about.
///
/// [tabHidden] and [windowBlurred] both mean the same thing for the student: they
/// are no longer looking at the exam, which is the `app_minimized` violation.
/// The two fullscreen events are bookkeeping around the **locked** exam surface:
/// leaving it opens a countdown (see `WebExamGuard.fullscreenGrace`) rather than
/// an immediate strike, and coming back inside that window closes it.
enum WebGuardEvent {
  /// `document.hidden` became true — another tab, a minimised browser, or the
  /// page was moved to the back/forward cache.
  tabHidden,

  /// The window lost keyboard focus (Alt+Tab, a second monitor, another app on
  /// top). `visibilityState` stays `visible` in that case, which is why the
  /// window's `blur` event needs its own listener.
  windowBlurred,

  /// HTML5 fullscreen ended after it had been entered — ESC, F11, or the
  /// browser's own escape affordance. The student gets
  /// `WebExamGuard.fullscreenGrace` (5 s) to come back before this becomes an
  /// `app_minimized` strike.
  fullscreenExited,

  /// HTML5 fullscreen engaged again, i.e. the student took the "return to
  /// fullscreen" offer. Never a violation: it cancels a pending
  /// [fullscreenExited].
  fullscreenEntered,

  /// A copy was attempted while the exam held the lockdown
  /// ([WebGuards.startExamLockdown]): the browser's copy was refused, and the
  /// attempt itself is evidence (`copy_paste_attempt`).
  copyBlocked,

  /// A cut was attempted under the lockdown — the same evidence as
  /// [copyBlocked]; cut is a separate DOM event, not a separate violation.
  cutBlocked,

  /// A paste was attempted under the lockdown: the clipboard was refused, and
  /// the attempt is `copy_paste_attempt` evidence.
  pasteBlocked,

  /// The context menu was requested (right-click, long-press) and suppressed —
  /// `right_click_blocked`. It is the browser's route to "view source",
  /// "inspect" and its own paste.
  contextMenuBlocked,

  /// The viewport geometry says a docked developer-tools panel (or an equivalent
  /// frame around the page) is open — `devtools_detected`. Reported once per
  /// episode, and only by [WebGuards.startExamLockdown]'s geometry probe.
  devtoolsDetected,
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

  /// True when this platform can enforce the exam lockdown — i.e. it has a DOM
  /// to block events on. Web only, like [isSupported].
  bool get supportsExamLockdown;

  /// Blocks the ways out of the exam surface that do not involve leaving it:
  /// `copy`, `cut` and `paste` are refused (and reported through [events]), the
  /// browser's context menu is suppressed, and the viewport geometry is watched
  /// for a docked developer-tools panel.
  ///
  /// Called by `WebExamGuard.start()` for the length of one attempt, so the
  /// student's own login screen keeps its clipboard and its right-click. The
  /// window in which the page has not booted yet is covered by the same
  /// lockdown's bootstrap script in `web/index.html`.
  ///
  /// Idempotent, and a no-op where [supportsExamLockdown] is false.
  void startExamLockdown();

  /// Stops blocking and reporting: clipboard events, the context menu and the
  /// geometry probe are released, so a finished exam does not keep the student's
  /// browser locked. Idempotent.
  void stopExamLockdown();

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
