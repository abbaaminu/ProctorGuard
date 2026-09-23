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

  @override
  Future<bool> enterFullscreen() async => false;

  @override
  Future<void> exitFullscreen() async {}

  @override
  void dispose() {}
}
