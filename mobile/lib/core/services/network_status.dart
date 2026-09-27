import 'dart:async';

import 'network_status_stub.dart'
    if (dart.library.js_interop) 'network_status_web.dart' as impl;

/// Best-effort "is this device online?" signal for the offline queue.
///
/// Deliberately not a `connectivity_plus` dependency: the only thing the exam
/// flow needs it for is *reacting faster* than its own retry backoff - a browser
/// fires `offline`/`online` the moment the connection changes, and on mobile the
/// queue's backoff plus the resume hook (`OfflineSyncService.retryNow` from the
/// exam page's `AppLifecycleListener`) already covers it. What the queue must
/// never do is *trust* this: every delivery attempt is what really decides, so a
/// lying probe only costs a little latency.
///
/// Platform split is the same conditional import as [WebGuards]: the DOM version
/// (`network_status_web.dart`) only exists in a web build, everything else gets
/// [NoNetworkStatus].
abstract class NetworkStatus {
  /// Picks the implementation for the platform this code was compiled for.
  factory NetworkStatus() => impl.createNetworkStatus();

  /// False on every non-web platform (and in VM widget tests).
  bool get isSupported;

  /// Last known state. `true` when nothing can tell us otherwise - the queue
  /// must assume it can deliver rather than sit on an answer because a probe
  /// said "offline".
  bool get isOnline;

  /// Online/offline transitions; see the class docs for why this is advisory.
  /// Never carries errors.
  Stream<bool> get changes;

  /// Removes the DOM listeners and closes [changes]. Safe to call twice.
  void dispose();
}
