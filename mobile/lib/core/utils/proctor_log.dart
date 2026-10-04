import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// Debug-only diagnostic logging for ProctorGuard.
///
/// `debugPrint` is deliberately **not** a no-op in a release build — it is only
/// throttled — so a shipped binary would still pay for every String
/// interpolation and could still write diagnostics to the platform log (an
/// information leak on a proctoring client, and noise in a support bundle).
///
/// Every diagnostic in the app goes through here instead: the `kDebugMode`
/// guard removes the call (and, because the message is built at the call site
/// into an argument, the whole thing is one cheap boolean check in release)
/// while keeping it visible exactly where a developer relies on it — `flutter
/// run` in debug and `flutter test`, both of which report as debug mode.
void proctorLog(String message) {
  if (kDebugMode) debugPrint(message);
}
