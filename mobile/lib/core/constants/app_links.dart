/// Where the Android build lives, in one place.
///
/// The web tools are not the app. A student who opens the site on a phone, or
/// who is told by [DesktopOnlyBrowserNotice] that an exam cannot be sat in a
/// browser, has no way to reach the app from here unless the page says where it
/// is - so the address is a constant, shared by every surface that offers it.
///
/// The primary address is the **APK itself**, not a landing page: it is what the
/// browser downloads when the button is tapped, and a page in between would only
/// add a second tap and a second place to be wrong. It is the arm64-v8a build,
/// which is what an Android phone from the last several years runs; anything
/// else is one tap further on, at [kAndroidAppReleasesUrl].
///
/// Neither is a `releases/latest` URL. The download link is pinned to a file on
/// the release branch, so it keeps working without a release being published
/// under that tag and without a redirect the browser has to follow.
library;

/// The APK the download button fetches.
const String kAndroidAppDownloadUrl =
    'https://github.com/abbaaminu/proctorguard-release/raw/main/apk/'
    'app-arm64-v8a-release.apk';

/// The repository the APK is published from, for anyone who needs another ABI
/// (an older 32-bit phone) or wants to check what they are installing.
const String kAndroidAppReleasesUrl =
    'https://github.com/abbaaminu/proctorguard-release';

/// The button's label.
const String kAndroidAppDownloadLabel = 'Download the Android app';

/// The secondary link's label, kept short so it fits beside the button on a
/// 320 px browser.
const String kAndroidAppReleasesLabel = 'Other Android builds';

/// What the browser will do with the download, said before it happens.
///
/// "Allow installs from this source" is the setting an Android browser's
/// download of a non-Play-Store APK leads to. Naming it here means the dialog
/// the student meets is one they were warned about rather than one that looks
/// like malware.
const String kAndroidAppInstallCaption =
    'Android only. Allow installs from this source when asked.';
