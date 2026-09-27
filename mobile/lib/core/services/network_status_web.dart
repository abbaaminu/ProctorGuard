import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'network_status.dart';

/// Creates the DOM-backed probe. Reached through [NetworkStatus]'s factory, so
/// this file is only compiled into a web build.
NetworkStatus createNetworkStatus() => NetworkStatusImpl();

/// `navigator.onLine` plus the window's `online`/`offline` events.
///
/// `navigator.onLine` only reports whether the browser has *a* network interface
/// with a route; it cannot see a captive portal or a dead Wi-Fi uplink. That is
/// fine here - it is used to trigger an immediate retry attempt, and the attempt
/// itself is the ground truth (a failure just re-queues).
class NetworkStatusImpl implements NetworkStatus {
  NetworkStatusImpl() {
    // Listener references are kept so dispose() can detach exactly these
    // closures (an anonymous `.toJS` would leak one per session).
    _onlineListener = _handleOnline.toJS;
    _offlineListener = _handleOffline.toJS;

    web.window.addEventListener('online', _onlineListener);
    web.window.addEventListener('offline', _offlineListener);

    _online = _read();
  }

  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  late final JSFunction _onlineListener;
  late final JSFunction _offlineListener;

  late bool _online;
  bool _disposed = false;

  static bool _read() {
    try {
      return web.window.navigator.onLine;
    } catch (_) {
      // A locked-down runtime can refuse the property; assume reachable so the
      // queue keeps trying instead of parking every answer.
      return true;
    }
  }

  @override
  bool get isSupported => true;

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes => _changes.stream;

  void _handleOnline(web.Event _) => _publish(true);

  void _handleOffline(web.Event _) => _publish(false);

  void _publish(bool online) {
    if (_disposed || online == _online) return;
    _online = online;
    _changes.add(online);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    web.window.removeEventListener('online', _onlineListener);
    web.window.removeEventListener('offline', _offlineListener);
    _changes.close();
  }
}
