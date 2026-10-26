/// The web half of [DesktopOnlyWebGuard]'s user-agent probe — see
/// `desktop_only_web_guard_user_agent_stub.dart` for why this is a separate file.
library;

import 'package:web/web.dart' as web;

/// `navigator.userAgent`, which is how the guard tells a phone browser from a
/// desktop one even when both are the same build of the app.
///
/// Only ever compiled into a web build (the conditional import in
/// `desktop_only_web_guard.dart` decides), so there is no non-web fallback to
/// keep in step here.
String browserUserAgent() => web.window.navigator.userAgent;
