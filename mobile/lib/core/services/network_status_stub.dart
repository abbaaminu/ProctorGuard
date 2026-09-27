import 'dart:async';

import 'network_status.dart';

/// Creates the probe for platforms that have no `window.navigator`.
NetworkStatus createNetworkStatus() => const NoNetworkStatus();

/// No-op probe for Android, iOS, desktop - and for the Dart VM, which is what
/// `flutter test` runs on.
///
/// Reports "online" and never emits, which is the honest answer: nothing here can
/// tell, so the queue's own retry loop is the only arbiter. Android/iOS also have
/// no `online`/`offline` browser event to listen to; the exam page's resume hook
/// is what wakes the queue up there.
class NoNetworkStatus implements NetworkStatus {
  const NoNetworkStatus();

  @override
  bool get isSupported => false;

  @override
  bool get isOnline => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();

  @override
  void dispose() {}
}
