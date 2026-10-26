import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'desktop_only_web_guard_user_agent_stub.dart'
    if (dart.library.js_interop) 'desktop_only_web_guard_user_agent_web.dart'
    as user_agent;
import 'responsive_layout.dart';

/// Narrowest window the web build is laid out for.
///
/// Sits between [Breakpoints.medium] (600 dp) and [Breakpoints.expanded]
/// (900 dp): below it a browser is treated like a phone even when its user agent
/// does not say so, because 768 px is the usual tablet-portrait boundary and a
/// desktop window can simply be dragged narrow.
const double kDesktopWebMinimumWidth = 768;

/// User-agent fragments that mean "this page is open on a phone or a small
/// tablet".
///
/// Lower-case; [looksLikeMobileBrowser] lower-cases before comparing. `ipad`
/// and `android` are deliberately included: an iPad or an Android tablet is not
/// a desktop browser either, and the administrative console is not a touch
/// layout.
const List<String> kMobileUserAgentMarkers = <String>[
  'iphone',
  'ipad',
  'android',
  'mobile',
];

/// Whether a browser visit must be blocked from the app.
///
/// Two independent signals, because either alone misses a real case:
///
/// * the **user agent** says phone/tablet — an iPhone is never going to get a
///   usable console out of a 390 px column, whatever its window reports;
/// * the **viewport** is narrower than [kDesktopWebMinimumWidth] — this is what
///   catches the cases the agent hides, chiefly an iPad in "desktop" mode
///   (which reports a Macintosh UA) and a desktop browser window resized to
///   phone width.
///
/// [isWeb] is a parameter rather than a direct `kIsWeb` read so a Dart VM test
/// can ask about the browser — the same seam, and for the same reason, as
/// `platformHasCamera(isWeb:)` in `core/services/platform_capabilities.dart`.
bool blocksWebVisit({
  required bool isWeb,
  required String? userAgent,
  required double viewportWidth,
}) {
  // Android and iOS are the product: no notice, and not even a viewport read.
  if (!isWeb) return false;
  if (viewportWidth < kDesktopWebMinimumWidth) return true;
  return looksLikeMobileBrowser(userAgent);
}

/// Whether [userAgent] names a phone or a tablet.
///
/// Null-safe and case-insensitive: a browser always has an agent, but an empty
/// or absent one is not worth an exception — it simply means "nothing here says
/// phone", and the viewport check still applies.
bool looksLikeMobileBrowser(String? userAgent) {
  if (userAgent == null || userAgent.isEmpty) return false;

  final agent = userAgent.toLowerCase();
  for (final marker in kMobileUserAgentMarkers) {
    if (agent.contains(marker)) return true;
  }
  return false;
}

/// Blocks the web build on phones and narrow windows, and leaves every other
/// target exactly as it was.
///
/// The web build is the administrative console — the screens a lecturer or an
/// administrator uses on a laptop — so a phone browser gets
/// [DesktopOnlyBrowserNotice] instead of a layout it cannot use. Native builds
/// (Android, iOS) pass [child] straight through: they *are* the student app, and
/// this restriction has nothing to say about them.
///
/// Wrap the root application with it, above the app's own `MaterialApp` (see
/// `main.dart`). Placement above the app is why the notice brings its own
/// `MaterialApp`: at that point there is no theme, no `Directionality` and no
/// `MediaQuery` to inherit.
///
/// The user agent is read through a **conditional import**
/// (`desktop_only_web_guard_user_agent_stub.dart` /
/// `desktop_only_web_guard_user_agent_web.dart`): `package:web` and
/// `dart:js_interop` do not exist off the web, and a plain import here would
/// break the Android and iOS builds this widget is required not to disturb.
class DesktopOnlyWebGuard extends StatelessWidget {
  const DesktopOnlyWebGuard({
    super.key,
    required this.child,
    this.userAgent,
    this.isWeb,
  });

  /// The app, shown unchanged unless this is a blocked browser visit.
  final Widget child;

  /// The browser's user agent.
  ///
  /// Injected so a test can stand in for a phone, and for a caller that already
  /// has the string; defaults to the platform's real one.
  final String? userAgent;

  /// Overrides [kIsWeb], for tests only — on a Dart VM the browser half of this
  /// widget is otherwise unreachable.
  final bool? isWeb;

  @override
  Widget build(BuildContext context) {
    if (!(isWeb ?? kIsWeb)) return child;

    // The guard is above the app's `MaterialApp`, so the `MediaQuery` that app
    // would install does not exist yet. `MediaQuery.fromView` provides the one
    // this widget needs *and* follows the view's metrics, which is what makes
    // the notice appear and disappear as the browser window is resized.
    return MediaQuery.fromView(
      view: View.of(context),
      child: Builder(
        builder: (context) {
          final blocked = blocksWebVisit(
            isWeb: true,
            userAgent: userAgent ?? user_agent.browserUserAgent(),
            viewportWidth: MediaQuery.sizeOf(context).width,
          );

          return blocked ? const DesktopOnlyBrowserNotice() : child;
        },
      ),
    );
  }
}

/// What a phone browser gets instead of the app.
///
/// Self-contained on purpose (see [DesktopOnlyWebGuard]): it is rendered where
/// the root `MaterialApp` would have been, so it is its own app.
class DesktopOnlyBrowserNotice extends StatelessWidget {
  const DesktopOnlyBrowserNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Same identity as the app it replaces: this is the page the tab and the
      // task switcher show while the visitor reads it.
      title: 'ProctorGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const _NoticePage(),
    );
  }
}

/// The notice itself: one sentence about the requirement, one way forward.
class _NoticePage extends StatelessWidget {
  const _NoticePage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: ResponsiveScrollView(
          maxWidth: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.desktop_windows_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                'Desktop browser required',
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 12),
              Text(
                'ProctorGuard web administrative tools require a desktop '
                'browser. Open this page on a computer, in Chrome or Edge, in a '
                'window at least ${kDesktopWebMinimumWidth.toInt()} px wide.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 20),
              Text(
                'Sitting an exam? Use the ProctorGuard app on your phone or '
                'tablet.',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
