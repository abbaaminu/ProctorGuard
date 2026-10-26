/// The non-web half of [DesktopOnlyWebGuard]'s user-agent probe.
///
/// `package:web` — and `dart:js_interop` underneath it — only exist in a web
/// build: compiling a file that imports them for the VM (the `flutter test`
/// host) or for Android/iOS fails outright with `Type 'JSObject' not found`.
/// `desktop_only_web_guard.dart` therefore imports this file everywhere and
/// [`desktop_only_web_guard_user_agent_web.dart`] on the web, which is the same
/// conditional-import split `web_guards.dart` uses for its DOM code.
library;

/// There is no browser here, so there is no user agent to report.
///
/// Empty rather than null so callers have one shape to handle; the guard reads
/// an empty agent as "nothing says this is a phone".
String browserUserAgent() => '';

/// There is no browser platform in a native build.
String browserPlatform() => '';

/// There is no browser touch capability in a native build.
int browserMaxTouchPoints() => 0;
