import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../constants/app_links.dart';
import '../services/external_link.dart';

/// The one place the web build says where the Android app is.
///
/// Three surfaces need it and they must not drift: the sign-in page (where a
/// student on a phone lands first), the phone-browser notice
/// (`DesktopOnlyBrowserNotice`, which replaces the whole web console on a touch
/// device), and the exam refusal (`MobileExamOnlyPage` and its dialog, shown
/// when a phone browser asks to sit a paper). All three render this widget; the
/// addresses and the wording are in `core/constants/app_links.dart`.
///
/// It is deliberately not a link to a landing page: the primary action is the
/// APK, and the secondary one is the release repository for anyone who needs a
/// different ABI. Both open in a new tab with `noopener,noreferrer`
/// ([openExternalLink]), and neither is a form control, so tapping one cannot
/// submit the sign-in form it sits under.
///
/// [isWeb] is the platform seam, the same one `blocksWebVisit` and
/// `examRunsOnPlatform` use: a browser-only surface passes `true` (it is a fact
/// about that page, and it keeps the block testable in the Dart VM), while a
/// shared surface like `LoginPage` leaves it null and gets [kIsWeb]. Nothing is
/// rendered where that is false, which is what keeps the block out of the
/// Android app - the app is the destination, so a button that downloads it
/// would be a button that downloads itself.
///
/// The block stretches to the width it is given (all three call sites are a
/// bounded column), so the caption wraps instead of overflowing on a 320 px
/// phone browser.
class AndroidAppDownloadBlock extends StatelessWidget {
  const AndroidAppDownloadBlock({super.key, this.isWeb, this.openLink});

  /// Whether this surface is a browser page; null asks [kIsWeb].
  final bool? isWeb;

  /// How a URL is opened, defaulting to [openExternalLink]. A test passes a
  /// recorder here: the Dart VM has no browser to open a tab in, and the
  /// addresses are what the test is about.
  final bool Function(String url)? openLink;

  @override
  Widget build(BuildContext context) {
    if (!(isWeb ?? kIsWeb)) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final open = openLink ?? openExternalLink;

    return Column(
      key: const Key('android-app-download-block'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Carried here rather than by the callers: the space has to disappear
        // with the block, and a caller-side `SizedBox` would leave a gap on the
        // login screen inside the Android app, where nothing is rendered.
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('android-app-download'),
          onPressed: () => open(kAndroidAppDownloadUrl),
          child: const Text(
            kAndroidAppDownloadLabel,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          kAndroidAppInstallCaption,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        TextButton(
          key: const Key('android-app-releases'),
          onPressed: () => open(kAndroidAppReleasesUrl),
          child: const Text(
            kAndroidAppReleasesLabel,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}
