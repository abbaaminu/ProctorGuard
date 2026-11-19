/// The non-browser half of `external_link.dart` - compiled into Android, iOS,
/// desktop and the Dart VM (`flutter test`).
///
/// Every surface that offers a link is web-only or hidden behind
/// `canOpenExternalLinks`, so this is never the code a student taps. It exists
/// so the import resolves, and it says "no" rather than pretending to have
/// opened something.
library;

/// False: there is no tab to open.
bool get canOpenExternalLinks => false;

/// Does nothing and reports that nothing happened. Opening the Android app's
/// own release page inside the Android app would be a browser trip for a link
/// the user already has the app for.
bool openExternalLink(String url) => false;
