/// Handing a URL to the browser.
///
/// Why this is a service and not a `package:url_launcher` call: the only thing
/// the app needs to do with a URL is open one *tab*, on the web, from a tap.
/// `url_launcher` on web is a thin `window.open` wrapper plus an intent
/// protocol for every other platform, and on Android it would be a new plugin,
/// a new manifest authority and a new way for a stray tap to leave the app -
/// for a link no Android screen shows. A conditional import costs nothing on
/// the platforms that never call it.
library;

import 'external_link_stub.dart'
    if (dart.library.js_interop) 'external_link_web.dart'
    as impl;

/// Whether this build can open a URL at all.
///
/// True only in a browser build. A surface that offers a link should not be
/// shown where this is false - see `AndroidAppDownloadBlock`, which renders
/// nothing in the Android app rather than a button that does nothing.
bool get canOpenExternalLinks => impl.canOpenExternalLinks;

/// Opens [url] in a new tab and returns whether a browser was there to take it.
///
/// The implementation is chosen at compile time, the way
/// `web_camera_permission.dart` and `web_guards.dart` do it: a web build gets
/// `window.open`, everything else gets a no-op.
///
/// `noopener,noreferrer` matters for the one use this has: the target is a
/// GitHub-hosted APK on a different origin, and the tab that opens must not get
/// a handle on this page (`noopener`) or its address in `Referer` (`noreferrer`).
/// It also means `window.open` returns null even on success, which is why the
/// answer is the build's capability and not the window handle.
bool openExternalLink(String url) => impl.openExternalLink(url);
