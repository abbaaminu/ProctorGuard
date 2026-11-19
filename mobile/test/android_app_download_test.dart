import 'dart:io';

import 'package:proctorguard/core/constants/app_links.dart';
import 'package:proctorguard/core/widgets/android_app_download_block.dart';
import 'package:proctorguard/core/widgets/desktop_only_web_guard.dart';
import 'package:proctorguard/features/exam/presentation/widgets/mobile_exam_only.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "get the Android app" block: what it opens, where it appears, and where
/// it must not.
///
/// The addresses are pinned as strings because they are the whole feature: a
/// wrong one downloads nothing, and a `releases/latest` URL would point at a
/// page instead of the APK. The taps are driven through the block's `openLink`
/// seam, since the Dart VM has no browser and `window.open` is only compiled
/// into a web build.
void main() {
  const androidChrome =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36';

  /// The block on a plain surface, sized like a phone browser.
  Widget blockUnderTest({
    required List<String> opened,
    bool? isWeb = true,
    Size size = const Size(400, 800),
    double padding = 32,
  }) => MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: EdgeInsets.all(padding),
          child: AndroidAppDownloadBlock(
            isWeb: isWeb,
            openLink: (url) {
              opened.add(url);
              return true;
            },
          ),
        ),
      ),
    ),
  );

  group('the links', () {
    test('the APK is a file, not a release page', () {
      expect(kAndroidAppDownloadUrl, startsWith('https://'));
      expect(kAndroidAppDownloadUrl, endsWith('.apk'));
      expect(
        kAndroidAppDownloadUrl,
        isNot(contains('/releases')),
        reason: 'a release page costs a second tap and can 404 on the tag',
      );
      expect(kAndroidAppDownloadUrl, contains('app-arm64-v8a-release.apk'));
    });

    test('the secondary link is the repository the APK comes from', () {
      expect(kAndroidAppReleasesUrl, startsWith('https://'));
      expect(kAndroidAppReleasesUrl, isNot(contains('/releases/latest')));
      expect(kAndroidAppReleasesUrl, isNot(endsWith('.apk')));
      expect(
        kAndroidAppDownloadUrl,
        startsWith(kAndroidAppReleasesUrl),
        reason: 'the download has to live in the repository it links to',
      );
    });

    test('the caption warns about the install-source prompt', () {
      expect(kAndroidAppInstallCaption, startsWith('Android only'));
      expect(kAndroidAppInstallCaption, contains('installs from this source'));
    });
  });

  // The address in `app_links.dart` is only real if the pipeline puts a file
  // there: the mirror is built by copying the per-ABI splits into
  // `dist/apk/`, committed to `abbaaminu/proctorguard-release`, and served raw
  // off that repository's default branch. Every one of those four facts is
  // spelled in the workflow, and renaming any of them leaves a button that
  // downloads nothing - which no widget test can see, because a browser is the
  // thing that fetches it. So the workflow is the contract, read the way
  // `web_manifest_contract_test.dart` reads `web/index.html`.
  group('the pipeline that has to publish the APK', () {
    /// The workflow, or null in a checkout without it (see the other contract
    /// tests: a test never pretends to have checked something it did not read).
    String? read(String path) {
      final file = File(path);
      return file.existsSync() ? file.readAsStringSync() : null;
    }

    String? workflow() =>
        read('../.github/workflows/proctorguard_pipeline.yml');

    test('builds the ABI the button names, as a split APK', () {
      final yaml = workflow();
      if (yaml == null) return;

      // `--split-per-abi` is what makes the file `app-<abi>-release.apk`; a
      // universal build would be one `app-release.apk` and the URL would 404.
      expect(yaml, contains('--split-per-abi'));
      expect(yaml, contains('*-release.apk'));

      final name = Uri.parse(kAndroidAppDownloadUrl).pathSegments.last;
      expect(
        name,
        matches(RegExp(r'^app-.+-release\.apk$')),
        reason: 'the name has to be one `--split-per-abi` produces',
      );
      // A 32-bit only phone gets the repository link instead; the default has to
      // be the ABI nearly every phone from the last several years runs.
      expect(name, contains('arm64-v8a'));
    });

    test('files it under apk/ in the repository the link names', () {
      final yaml = workflow();
      if (yaml == null) return;

      // The mirror's name appears once, in the job's env; the links have to
      // name the same repository or the download points at somebody else's.
      final mirror = RegExp(
        r'RELEASE_REPOSITORY:\s*(\S+)',
      ).firstMatch(yaml)?.group(1);
      expect(mirror, isNotNull);
      expect(kAndroidAppReleasesUrl, 'https://github.com/$mirror');
      expect(
        kAndroidAppDownloadUrl,
        startsWith('$kAndroidAppReleasesUrl/raw/'),
        reason: 'the download lives in the repository it links to',
      );

      // `dist/apk` is the directory copied into the mirror.
      expect(yaml, contains(r'mkdir -p "$dist/apk"'));
      expect(
        Uri.parse(kAndroidAppDownloadUrl).pathSegments,
        contains('apk'),
      );
    });

    test('serves it raw off the branch the mirror is pushed to', () {
      final yaml = workflow();
      if (yaml == null) return;

      // `/raw/<branch>/<path>` with the clone's default branch. The workflow
      // pushes to whatever branch it cloned, and initialises a missing mirror as
      // `main`; the URL has to name that same branch or a fresh mirror 404s.
      expect(yaml, contains('--initial-branch=main'));
      expect(
        yaml,
        contains('git push origin "\$(git symbolic-ref --short HEAD)"'),
      );

      final segments = Uri.parse(kAndroidAppDownloadUrl).pathSegments;
      expect(segments[2], 'raw');
      expect(segments[3], 'main');
      expect(segments[4], 'apk');
    });
  });

  group('the block', () {
    testWidgets('the main action opens the APK', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(blockUnderTest(opened: opened));

      expect(find.byKey(const Key('android-app-download-block')), findsOne);
      expect(find.text(kAndroidAppDownloadLabel), findsOne);
      expect(find.text(kAndroidAppInstallCaption), findsOne);

      await tester.tap(find.byKey(const Key('android-app-download')));
      await tester.pump();

      expect(opened, <String>[kAndroidAppDownloadUrl]);
    });

    testWidgets('the secondary action opens the repository', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(blockUnderTest(opened: opened));

      await tester.tap(find.byKey(const Key('android-app-releases')));
      await tester.pump();

      expect(opened, <String>[kAndroidAppReleasesUrl]);
    });

    testWidgets('nothing is offered inside the Android app', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(blockUnderTest(opened: opened, isWeb: false));

      // The app is the destination: a button that downloads it would download
      // itself. The whole block goes, spacing included.
      expect(find.byKey(const Key('android-app-download-block')), findsNothing);
      expect(find.text(kAndroidAppDownloadLabel), findsNothing);
      expect(find.text(kAndroidAppReleasesLabel), findsNothing);
      expect(find.text(kAndroidAppInstallCaption), findsNothing);
      expect(opened, isEmpty);
    });

    testWidgets('it fits a 320 dp browser without overflowing', (tester) async {
      // An old small phone in portrait, which is the narrowest browser a
      // student could be told to install the app from.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final opened = <String>[];
      await tester.pumpWidget(
        blockUnderTest(opened: opened, size: const Size(320, 640), padding: 24),
      );

      expect(tester.takeException(), isNull);

      // Inside the 320 px viewport, gutter included.
      final block = tester.getRect(
        find.byKey(const Key('android-app-download-block')),
      );
      expect(block.left, greaterThanOrEqualTo(0));
      expect(block.right, lessThanOrEqualTo(320));

      // And both actions are still tappable at that width.
      await tester.tap(find.byKey(const Key('android-app-download')));
      await tester.tap(find.byKey(const Key('android-app-releases')));
      await tester.pump();

      expect(opened, <String>[kAndroidAppDownloadUrl, kAndroidAppReleasesUrl]);
    });
  });

  group('the surfaces that offer it', () {
    testWidgets('the phone-browser notice', (tester) async {
      // The whole web console replaced by one page: this is where a student on
      // a phone lands, so the only way to the app has to be on it.
      await tester.pumpWidget(const DesktopOnlyBrowserNotice());

      expect(find.byKey(const Key('android-app-download-block')), findsOne);
      expect(find.text(kAndroidAppDownloadLabel), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the exam refusal screen', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MobileExamOnlyPage()));

      expect(find.byKey(const Key('exam-mobile-only')), findsOne);
      expect(find.byKey(const Key('android-app-download-block')), findsOne);
    });

    testWidgets('the exam refusal dialog', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showMobileExamOnlyDialog(
                    context,
                    isWeb: true,
                    userAgent: androidChrome,
                  ),
                  child: const Text('open exam'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // The dialog is the refusal most students meet - the exam list calls it
      // before an attempt exists - so it cannot only point at a document.
      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsOne);
      expect(find.byKey(const Key('android-app-download-block')), findsOne);
      expect(tester.takeException(), isNull);
    });
  });
}
