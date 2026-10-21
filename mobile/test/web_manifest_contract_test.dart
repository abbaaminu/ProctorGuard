import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Pins the web half of the install contract, the way
/// `android_manifest_contract_test.dart` pins the Android half:
/// `web/manifest.json` is the record a browser installs ProctorGuard from, and
/// `web/index.html` is what names the tab and hands out the home-screen icon.
///
/// None of it is reachable from a widget test - a manifest is metadata a browser
/// fetches, and the icons are bytes on disk - so the files, and the PNG headers
/// they point at, are the contract. Each group below stands for a way this broke
/// or could break silently:
///
///  * **The icons were the stock Flutter logo.** `web/icons/Icon-*.png` still
///    held the artwork `flutter create` wrote while `web/favicon.png` and
///    `assets/icon/app_icon.png` held the real shield, so the tab, the
///    apple-touch-icon and an app installed off a custom domain all showed
///    Flutter's mark. The icons are now generated from `app_icon.png` by
///    `flutter_launcher_icons` (the `web:` block in `pubspec.yaml`), and the
///    artwork check below is what notices a source swap.
///  * **A URL that only works at a domain root.** The build is served from
///    `https://example.edu/proctorguard/` as often as from a root, and relative
///    URLs resolve against `<base href>` - the value `--base-href` writes.
///    An icon path starting with `/` 404s under a sub-path; one naming an
///    absolute `https://<old host>/...` keeps working until the app moves and
///    then renders nothing. Both are refusals here.
///  * **A `sizes` the file disagrees with.** A browser trusts the declared size
///    when it chooses an icon and draws nothing when the bytes disagree, so a
///    512 icon declared as 192 is an install with no icon. The IHDR is read and
///    compared with the manifest rather than trusted.
///  * **A favicon that is a poster.** `favicon.png` was once a 2720 px, 409 KB
///    copy of the artwork, downloaded for every tab in the app's life.
void main() {
  /// The background of the app icon, and so of its top-left corner: `#14284B`,
  /// the navy the shield is drawn on (`manifest.json`'s `background_color`).
  const int brandNavy = 0x14284B;

  /// Reads a file relative to the package root (`mobile/`, the working directory
  /// `flutter test` uses). Null when a checkout does not have it, so a test
  /// never pretends to have checked something it did not read.
  String? read(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// Width and height from a PNG's IHDR chunk, or null when the file is missing
  /// or is not a PNG at all. Plain `dart:io` + `dart:typed_data`: the app has no
  /// image-decoding dependency and reading two integers out of a header is not a
  /// reason to add one.
  ({int width, int height})? pngSize(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    // 8-byte signature, 4-byte chunk length, `IHDR`, then width and height. The
    // first chunk of a valid PNG is always IHDR, so 24 bytes is all this needs.
    if (bytes.length < 24) return null;
    const signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return null;
    }
    final header = ByteData.sublistView(bytes, 16, 24);
    return (width: header.getUint32(0), height: header.getUint32(4));
  }

  /// The top-left pixel of an 8-bit RGB or RGBA PNG as `(r, g, b, a)`, or null
  /// when the file is missing or is a shape this helper does not read (palette,
  /// grey, 16-bit, interlaced).
  ///
  /// Only the first scanline is decoded, and only its first pixel: a corner is
  /// all the artwork check asks for, and comparing whole icons in a test is not
  /// worth carrying a full decoder for. That the filters cost nothing here is
  /// not luck - `Sub`, `Up`, `Average` and `Paeth` all predict from the pixel to
  /// the *left* or the row *above*, and the first pixel of the first row has
  /// neither, so its bytes are its own whatever the filter byte says.
  ({int r, int g, int b, int a})? cornerPixel(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (pngSize(path) == null || bytes.length < 33) return null;

    final bitDepth = bytes[24];
    final colorType = bytes[25];
    final interlace = bytes[28];
    // 2 = RGB, 6 = RGBA, which is what the generated artwork is.
    final channels = switch (colorType) {
      2 => 3,
      6 => 4,
      _ => 0,
    };
    if (bitDepth != 8 || channels == 0 || interlace != 0) return null;

    // Every `IDAT` belongs to one zlib stream and the spec keeps them
    // consecutive, so concatenating them is enough to inflate.
    final compressed = BytesBuilder(copy: false);
    var offset = 8;
    while (offset + 8 <= bytes.length) {
      final length = ByteData.sublistView(
        bytes,
        offset,
        offset + 4,
      ).getUint32(0);
      final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
      final start = offset + 8;
      final end = start + length;
      if (end > bytes.length) return null;
      if (type == 'IDAT') {
        compressed.add(bytes.sublist(start, end));
      } else if (type == 'IEND') {
        break;
      }
      offset = end + 4; // Skip the chunk's CRC.
    }

    final List<int> raw;
    try {
      raw = ZLibDecoder().convert(compressed.takeBytes());
    } on FormatException {
      return null;
    }
    // Byte 0 of the first scanline is its filter type; the pixel follows it.
    if (raw.length < 1 + channels) return null;

    return (
      r: raw[1],
      g: raw[2],
      b: raw[3],
      a: channels == 4 ? raw[4] : 0xFF,
    );
  }

  /// True when [url] is a path the browser resolves against `<base href>`
  /// instead of against the origin, which is what makes one build work at a
  /// domain root and under a sub-path.
  bool isRelativeUrl(String url) =>
      !url.startsWith('/') &&
      !url.startsWith('http://') &&
      !url.startsWith('https://') &&
      !url.startsWith('//');

  /// Every `href="..."` / `src="..."` in a document, minus the `<base href>`
  /// placeholder: `--base-href` may legitimately write `/` there, so it is the
  /// one URL whose absoluteness is the build's business.
  List<String> checkedUrls(String html) => RegExp(r'(?:href|src)="([^"]+)"')
      .allMatches(html)
      .map((match) => match.group(1)!)
      .where((url) => !url.contains(r'$'))
      .toList();

  group('web/manifest.json', () {
    test('describes an installable app', () {
      final source = read('web/manifest.json');
      if (source == null) return;

      final manifest = jsonDecode(source) as Map<String, dynamic>;

      // `name` is the install dialog and the home-screen label, `short_name` the
      // launcher; both name the app the student was told to allow, and
      // `android_manifest_contract_test.dart` already pins that they agree with
      // the APK's label.
      expect(manifest['name'], isNotEmpty);
      expect(manifest['short_name'], 'ProctorGuard');
      expect(manifest['description'], isNotEmpty);

      // `standalone` is what makes an install an app rather than a bookmark, and
      // the two colours keep the splash screen from flashing white between the
      // icon and the first frame. They are hex, because a browser drops
      // anything else silently.
      expect(manifest['display'], 'standalone');
      expect(manifest['background_color'], '#14284B');
      expect(manifest['theme_color'], '#3F51B5');
      expect(manifest['prefer_related_applications'], isFalse);

      // `start_url` and `scope` both point at the app's own directory. Relative
      // on purpose: an absolute `/` would install a home-screen app that opens
      // the domain root, which on a custom domain hosting several apps is
      // somebody else's page.
      expect(manifest['start_url'], '.');
      expect(manifest['scope'], '.');
    });

    test('points every icon at a real, correctly sized, relative PNG', () {
      final source = read('web/manifest.json');
      if (source == null) return;

      final manifest = jsonDecode(source) as Map<String, dynamic>;
      final icons = (manifest['icons'] as List).cast<Map<String, dynamic>>();
      expect(icons, isNotEmpty);

      for (final icon in icons) {
        final src = icon['src'] as String;
        final sizes = icon['sizes'] as String;

        // Relative, or the icon is missing under `--base-href /<sub-path>/`.
        expect(
          isRelativeUrl(src),
          isTrue,
          reason: '"$src" is not a relative URL: it would not resolve against '
              '<base href> when the app is served from a sub-path',
        );
        expect(icon['type'], 'image/png');

        // The declared size is what the browser picks by; the bytes decide
        // whether it can draw the icon at all.
        final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(sizes);
        expect(match, isNotNull, reason: '"$src" declares sizes "$sizes"');
        final declared = (
          width: int.parse(match!.group(1)!),
          height: int.parse(match.group(2)!),
        );

        final actual = pngSize('web/$src');
        expect(actual, isNotNull, reason: 'web/$src is missing or not a PNG');
        expect(
          actual,
          declared,
          reason: 'web/$src is ${actual!.width}x${actual.height} but '
              'manifest.json advertises $sizes',
        );
      }
    });

    test('offers both sizes an install needs, maskable included', () {
      final source = read('web/manifest.json');
      if (source == null) return;

      final manifest = jsonDecode(source) as Map<String, dynamic>;
      final icons = (manifest['icons'] as List).cast<Map<String, dynamic>>();

      bool isMaskable(Map<String, dynamic> icon) =>
          icon['purpose']?.toString().contains('maskable') ?? false;

      // Chrome wants a 192 for the home screen and a 512 for the splash screen;
      // Android crops a maskable icon to its own shape, so that has to be a
      // separate entry rather than the only entry.
      final plain = <String>{
        for (final icon in icons)
          if (!isMaskable(icon)) icon['sizes'] as String,
      };
      final maskable = <String>{
        for (final icon in icons)
          if (isMaskable(icon)) icon['sizes'] as String,
      };

      expect(plain, containsAll(<String>['192x192', '512x512']));
      expect(maskable, containsAll(<String>['192x192', '512x512']));
    });

    test('the icons are the app artwork, not the Flutter template logo', () {
      final source = read('web/manifest.json');
      if (source == null) return;

      final manifest = jsonDecode(source) as Map<String, dynamic>;
      final icons = (manifest['icons'] as List).cast<Map<String, dynamic>>();
      final paths = <String>[
        for (final icon in icons) 'web/${icon['src']}',
        'web/favicon.png',
      ];
      final expected = (
        r: (brandNavy >> 16) & 0xFF,
        g: (brandNavy >> 8) & 0xFF,
        b: brandNavy & 0xFF,
      );

      for (final path in paths) {
        // A missing icon is a failure here as well as in the sizes test: this
        // one is the group that names the artwork, so it should not pass on an
        // absent file.
        expect(pngSize(path), isNotNull, reason: '$path is missing');

        final pixel = cornerPixel(path);
        // Not a shape the helper reads (palette, 16-bit, interlaced): nothing to
        // assert, and failing here would blame the artwork for the helper.
        if (pixel == null) continue;

        // The shield sits on `#14284B`; the stock Flutter icon this directory
        // used to hold had a white corner. This is the assertion that fails when
        // `flutter_launcher_icons` is pointed at the wrong source, or is not
        // re-run after `assets/icon/app_icon.png` changes.
        expect(
          (r: pixel.r, g: pixel.g, b: pixel.b),
          expected,
          reason: '$path does not contain the ProctorGuard artwork - rerun '
              '`dart run flutter_launcher_icons` (see the `web:` block in '
              'pubspec.yaml)',
        );
        // Opaque, near enough: the resize down from 2720 px resamples the alpha
        // channel and can shave a level off a corner (254 on the 192 px icon).
        expect(
          pixel.a,
          greaterThanOrEqualTo(0xF0),
          reason: '$path has a transparent corner',
        );
      }
    });

    test('carries a favicon small enough to be a favicon', () {
      final size = pngSize('web/favicon.png');
      expect(size, isNotNull, reason: 'web/favicon.png is missing');
      if (size == null) return;

      // A tab icon is fetched for every tab and cached per origin: the artwork
      // is 2720 px, and serving it here meant a 409 KB download to draw 16 px.
      expect(
        size.width,
        lessThanOrEqualTo(64),
        reason: 'web/favicon.png is ${size.width}px wide - regenerate it with '
            '`dart run flutter_launcher_icons` instead of copying app_icon.png',
      );
      expect(size.height, lessThanOrEqualTo(64));
      expect(size.width, size.height, reason: 'a favicon has to be square');
    });
  });

  group('web/index.html', () {
    test('keeps <base href> a build-time value', () {
      final html = read('web/index.html');
      if (html == null) return;

      // `flutter build web --base-href /proctorguard/` rewrites this
      // placeholder. A hard-coded "/" is a custom-domain deploy that loads the
      // document and then 404s on `main.dart.js`; a sub-path deploy run without
      // `--base-href` is the same failure with the icons on top.
      expect(html, contains('<base href="\$FLUTTER_BASE_HREF">'));
    });

    test('addresses every icon, the manifest and the script relatively', () {
      final html = read('web/index.html');
      if (html == null) return;

      final urls = checkedUrls(html);
      expect(urls, isNotEmpty);

      for (final url in urls) {
        expect(
          isRelativeUrl(url),
          isTrue,
          reason: '"$url" in web/index.html is absolute: it keeps working '
              'until the app moves to a custom domain or a sub-path, and then '
              'renders nothing',
        );
      }
    });

    test('links only files the web folder actually ships', () {
      final html = read('web/index.html');
      if (html == null) return;

      // `flutter_bootstrap.js` is written by `flutter build web`, not checked
      // in; everything else the page names has to exist here, because a 404 in
      // the document head is an icon-less tab on a deploy that "works".
      const generatedByBuild = <String>{'flutter_bootstrap.js'};

      for (final url in checkedUrls(html)) {
        if (url.startsWith('#') || generatedByBuild.contains(url)) continue;
        expect(
          File('web/$url').existsSync(),
          isTrue,
          reason: 'web/index.html points at "$url", which is not in web/',
        );
      }
    });

    test('gives the apple-touch-icon a size iOS can use', () {
      final html = read('web/index.html');
      if (html == null) return;

      final match = RegExp(
        r'<link[^>]+rel="apple-touch-icon"[^>]*href="([^"]+)"',
      ).firstMatch(html);
      expect(match, isNotNull, reason: 'no apple-touch-icon in web/index.html');

      final size = pngSize('web/${match!.group(1)}');
      expect(size, isNotNull);
      // iOS does not upscale a touch icon: below 180 it draws a screenshot of
      // the page instead.
      expect(size!.width, greaterThanOrEqualTo(180));
    });
  });
}
