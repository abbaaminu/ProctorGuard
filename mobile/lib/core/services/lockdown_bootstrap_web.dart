import 'dart:js_interop';
// The lockdown globals are reached by name, which is `dart:js_interop_unsafe`'s
// `hasProperty`/`callMethod` rather than anything package:web declares.
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../utils/proctor_log.dart';

import 'lockdown_bootstrap.dart';

/// Creates the boot signal for a web build.
LockdownBootstrap createLockdownBootstrap() => const WebLockdownBootstrap();

/// `proctorGuardAppBooted()`, published by the bootstrap script in
/// `web/index.html`.
///
/// Resolved by name on `window` for the same reason [WebGuardsImpl] resolves the
/// lockdown entry points that way: the script loads before the compiled app and
/// has to stay plain JavaScript that a host can read, so there is no interface to
/// call into.
class WebLockdownBootstrap implements LockdownBootstrap {
  const WebLockdownBootstrap();

  /// The global the script defines at load (see its comment there).
  static const String _bootedFn = 'proctorGuardAppBooted';

  /// [web.window] as a plain [JSObject], which is the receiver the
  /// `dart:js_interop_unsafe` lookups are declared on.
  JSObject get _window => web.window;

  @override
  bool get isSupported => _window.hasProperty(_bootedFn.toJS).toDart;

  @override
  void markAppBooted() {
    // A host with its own `index.html`: there is nothing to tell, and the page
    // was never blocked in the first place.
    if (!isSupported) return;

    try {
      _window.callMethod(_bootedFn.toJS);
    } catch (error) {
      // Reported rather than thrown: this runs on the startup path, and a
      // half-defined host script is not a reason to lose the app. The cost is
      // that the pre-boot block stands until an exam arms the lockdown, which is
      // stricter than intended, never looser.
      proctorLog('ProctorGuard lockdown: could not announce the boot: $error');
    }
  }
}
