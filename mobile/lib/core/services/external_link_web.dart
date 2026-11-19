/// The browser half of `external_link.dart` - only ever compiled into a web
/// build, which the conditional import there decides.
library;

import 'package:web/web.dart' as web;

/// True: this build is running in a tab.
bool get canOpenExternalLinks => true;

/// `window.open(url, '_blank', 'noopener,noreferrer')`.
///
/// Called from a tap handler, so the browser treats it as a user gesture and
/// the tab is not blocked. `noopener,noreferrer` are the reason a new tab is
/// safe to open at all: GitHub's download page must not receive this page's
/// address, and the opened tab must not be able to reach `window.opener` and
/// navigate the app underneath it.
///
/// A browser that refuses anyway (a popup blocker acting on a programmatic
/// call) leaves the return value null; a blocked tab is not a failure the app
/// can fix, and there is nothing to report that the student cannot see.
bool openExternalLink(String url) {
  web.window.open(url, '_blank', 'noopener,noreferrer');
  return true;
}
