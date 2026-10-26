import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/widgets/desktop_only_web_guard.dart';

/// What a browser actually reports as `navigator.userAgent`.
const String iphoneSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 '
    'Safari/604.1';
const String androidChrome =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const String ipadSafari =
    'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';
const String desktopChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/126.0.0.0 Safari/537.36';
const String ipadDesktopSafari =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.5 Safari/605.1.15';

/// The guard is the only thing between a phone browser and the administrative
/// console, and its interesting half (`kIsWeb` being true) cannot happen in a
/// Dart VM test. So the decision is a pure function these tests ask directly,
/// and the widget takes the same two facts as overrides — the same seam, and for
/// the same reason, as `platformHasCamera(isWeb:)`.
void main() {
  group('which visits are blocked', () {
    test('a phone announces itself through its user agent', () {
      for (final agent in <String>[iphoneSafari, androidChrome]) {
        expect(
          blocksWebVisit(isWeb: true, userAgent: agent, viewportWidth: 1440),
          isTrue,
          reason: 'a phone is never a usable console, however wide `innerWidth` '
              'claims to be',
        );
      }
    });

    test('an iPad is a tablet, not a desktop browser', () {
      expect(
        blocksWebVisit(isWeb: true, userAgent: ipadSafari, viewportWidth: 834),
        isTrue,
      );
    });

    test('iPadOS desktop mode is blocked at a full-width viewport', () {
      expect(
        blocksWebVisit(
          isWeb: true,
          userAgent: ipadDesktopSafari,
          viewportWidth: 1024,
          platform: 'MacIntel',
          maxTouchPoints: 5,
        ),
        isTrue,
      );
    });

    test('a Mac desktop is not blocked for having its platform name', () {
      expect(
        blocksWebVisit(
          isWeb: true,
          userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5)',
          viewportWidth: 1440,
          platform: 'MacIntel',
        ),
        isFalse,
      );
    });

    test('a narrow window is blocked even when the agent says desktop', () {
      // The iPad-in-desktop-mode case (a Macintosh user agent) and a desktop
      // window dragged down to phone width both land here.
      expect(
        blocksWebVisit(
          isWeb: true,
          userAgent: desktopChrome,
          viewportWidth: kDesktopWebMinimumWidth - 1,
        ),
        isTrue,
      );
    });

    test('a desktop browser at a desktop width is let through', () {
      expect(
        blocksWebVisit(
          isWeb: true,
          userAgent: desktopChrome,
          viewportWidth: kDesktopWebMinimumWidth,
        ),
        isFalse,
      );
      expect(
        blocksWebVisit(
          isWeb: true,
          userAgent: desktopChrome,
          viewportWidth: 1920,
        ),
        isFalse,
      );
    });

    test('a missing user agent falls back to the viewport alone', () {
      expect(
        blocksWebVisit(isWeb: true, userAgent: null, viewportWidth: 1440),
        isFalse,
      );
      expect(
        blocksWebVisit(isWeb: true, userAgent: '', viewportWidth: 320),
        isTrue,
      );
    });

    test('native builds are never blocked, whatever they claim', () {
      // Android and iOS are the student app: a phone there is the intended
      // target, not a visitor who opened the wrong thing.
      expect(
        blocksWebVisit(isWeb: false, userAgent: iphoneSafari, viewportWidth: 390),
        isFalse,
      );
    });

    test('the marker list is the documented one', () {
      expect(
        kMobileUserAgentMarkers,
        containsAll(<String>['iphone', 'ipad', 'android', 'mobile']),
      );
      expect(looksLikeMobileBrowser('Mozilla/5.0 (IPHONE)'), isTrue);
      expect(looksLikeMobileBrowser('Mozilla/5.0 (Windows NT 10.0)'), isFalse);
    });
  });

  group('DesktopOnlyWebGuard', () {
    /// The app under the guard. A real one carries its own `MaterialApp`, which
    /// is also what lets "passes straight through" be asserted by its text.
    Widget console() => const MaterialApp(
          home: Scaffold(body: Text('the administrative console')),
        );

    /// Pumps the guard on a [size]-sized viewport.
    ///
    /// `isWeb` stands in for `kIsWeb` (false on the VM running these tests) and
    /// the view size is the browser window, which `MediaQuery.fromView` reads.
    Future<void> pumpGuard(
      WidgetTester tester, {
      required bool isWeb,
      String? userAgent,
      String? platform,
      int maxTouchPoints = 0,
      Size size = const Size(1400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        DesktopOnlyWebGuard(
          isWeb: isWeb,
          userAgent: userAgent,
          platform: platform,
          maxTouchPoints: maxTouchPoints,
          child: console(),
        ),
      );
    }

    testWidgets('Android and iOS get the app, untouched', (tester) async {
      await pumpGuard(
        tester,
        isWeb: false,
        userAgent: iphoneSafari,
        size: const Size(390, 844),
      );

      expect(find.text('the administrative console'), findsOneWidget);
      expect(find.byType(DesktopOnlyBrowserNotice), findsNothing);
    });

    testWidgets('a phone browser gets the notice instead', (tester) async {
      await pumpGuard(
        tester,
        isWeb: true,
        userAgent: iphoneSafari,
        size: const Size(390, 844),
      );

      expect(find.byType(DesktopOnlyBrowserNotice), findsOneWidget);
      expect(find.text('the administrative console'), findsNothing);
    });

    testWidgets('iPadOS desktop mode gets the notice at tablet width',
        (tester) async {
      await pumpGuard(
        tester,
        isWeb: true,
        userAgent: ipadDesktopSafari,
        platform: 'MacIntel',
        maxTouchPoints: 5,
        size: const Size(1024, 768),
      );

      expect(find.byType(DesktopOnlyBrowserNotice), findsOneWidget);
      expect(find.text('the administrative console'), findsNothing);
    });

    testWidgets('a desktop browser gets the app', (tester) async {
      await pumpGuard(tester, isWeb: true, userAgent: desktopChrome);

      expect(find.text('the administrative console'), findsOneWidget);
      expect(find.byType(DesktopOnlyBrowserNotice), findsNothing);
    });

    testWidgets('a narrow desktop window gets the notice', (tester) async {
      await pumpGuard(
        tester,
        isWeb: true,
        userAgent: desktopChrome,
        size: const Size(700, 900),
      );

      expect(find.byType(DesktopOnlyBrowserNotice), findsOneWidget);
    });

    testWidgets('the notice follows the window as it is resized',
        (tester) async {
      await pumpGuard(tester, isWeb: true, userAgent: desktopChrome);
      expect(find.text('the administrative console'), findsOneWidget);

      // Dragged down to phone width: `MediaQuery.fromView` re-reads the view's
      // metrics, so the guard re-decides without a reload.
      tester.view.physicalSize = const Size(600, 900);
      await tester.pump();

      expect(find.byType(DesktopOnlyBrowserNotice), findsOneWidget);
    });
  });

  group('the notice', () {
    testWidgets('states the requirement with no app around it', (tester) async {
      // It replaces the root `MaterialApp`, so it has to be a complete app: no
      // theme, no `Directionality` and no `MediaQuery` to inherit from.
      await tester.pumpWidget(const DesktopOnlyBrowserNotice());

      expect(find.text('Desktop browser required'), findsOneWidget);
      expect(
        find.textContaining('web administrative tools require a desktop'),
        findsOneWidget,
      );
      expect(find.textContaining('Sitting an exam?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
