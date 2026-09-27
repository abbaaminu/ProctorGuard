import 'dart:async';

import 'web_guards.dart';

/// Creates the guards for platforms that have no DOM.
WebGuards createWebGuards() => const UnsupportedWebGuards();

/// No-op guards for Android, iOS, desktop — and for the Dart VM, which is what
/// `flutter test` runs on.
///
/// Android already has something stronger than a tab check: lock task mode (see
/// `KioskService`). Reporting "not supported" here keeps one interface for the
/// exam page without pretending a browser guarantee exists where there is no
/// browser.
class UnsupportedWebGuards implements WebGuards {
  const UnsupportedWebGuards();

  @override
  bool get isSupported => false;

  @override
  bool get isFullscreen => false;

  /// Empty, and never closes on its own — listeners in the exam page stay
  /// subscribed for the session without any platform work behind them.
  @override
  Stream<WebGuardEvent> get events => const Stream<WebGuardEvent>.empty();

  /// No DOM to block events on, so there is no lockdown to enforce. Android has
  /// lock task (see [KioskService]) and a copy/paste block of its own; iOS and
  /// desktop have neither, and reporting "supported" would promise a guarantee
  /// this platform cannot keep.
  @override
  bool get supportsExamLockdown => false;

  @override
  void startExamLockdown() {}

  @override
  void stopExamLockdown() {}

  @override
  Future<bool> enterFullscreen() async => false;

  @override
  Future<void> exitFullscreen() async {}

  @override
  void dispose() {}
}
