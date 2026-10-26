import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the browser build's Content Security Policy, the way
/// `web_manifest_contract_test.dart` pins the install manifest and
/// `android_manifest_contract_test.dart` pins the Android manifest.
///
/// A CSP is not something a widget test can exercise: it is enforced by the
/// browser, against a page no test renders. What *is* checkable is the policy
/// itself, and the failure mode that matters is a quiet widening - someone adds
/// `https:` to `connect-src` to make a local proxy work, or `*` to `script-src`
/// to load a library from a CDN, and the protection that keeps a student's
/// frames and session token inside the project is gone with no test noticing.
/// Each test below therefore names the *only* sources that may appear, rather
/// than merely checking that the dangerous ones are absent.
void main() {
  /// The policy in `web/index.html`, split into directive -> sources.
  ///
  /// Null when the file or the meta tag is missing, so a test never pretends to
  /// have read a policy it did not.
  Map<String, List<String>>? readPolicy() {
    final file = File('web/index.html');
    if (!file.existsSync()) return null;

    final html = file.readAsStringSync();
    final tag = RegExp(
      r'<meta[^>]*http-equiv="Content-Security-Policy"[^>]*>',
      caseSensitive: false,
    ).firstMatch(html);
    if (tag == null) return null;

    // The tag's own attributes only: `content` is read from the matched tag,
    // not from the document, because the page has other meta tags.
    final content = RegExp(r'content="([^"]*)"', caseSensitive: false)
        .firstMatch(tag.group(0)!)
        ?.group(1);
    if (content == null) return null;

    final directives = <String, List<String>>{};
    for (final directive in content.split(';')) {
      final tokens = directive
          .trim()
          .split(RegExp(r'\s+'))
          .where((token) => token.isNotEmpty)
          .toList();
      if (tokens.isEmpty) continue;
      directives[tokens.first.toLowerCase()] = tokens.sublist(1);
    }
    return directives;
  }

  group('web/index.html Content Security Policy', () {
    late Map<String, List<String>> csp;

    setUpAll(() {
      final parsed = readPolicy();
      expect(
        parsed,
        isNotNull,
        reason: 'web/index.html has no Content-Security-Policy meta tag: a '
            'browser build then runs with no restriction at all, and one '
            'injected script can read the session and the camera',
      );
      csp = parsed!;
    });

    test('is declared before the first script element', () {
      final html = File('web/index.html').readAsStringSync();
      final policyAt = html.indexOf('http-equiv="Content-Security-Policy"');
      final firstScript = html.indexOf('<script');

      expect(policyAt, greaterThanOrEqualTo(0));
      expect(firstScript, greaterThanOrEqualTo(0));
      expect(
        policyAt,
        lessThan(firstScript),
        reason: 'a policy declared after a script does not apply to that '
            'script - the face sensor and the lockdown bootstrap are exactly '
            'the scripts it has to cover',
      );
    });

    test('defaults everything to this origin', () {
      expect(csp['default-src'], <String>["'self'"]);
    });

    test('lets only this origin, the inline bootstrap and CanvasKit run script',
        () {
      final script = csp['script-src'] ?? const <String>[];

      expect(script, contains("'self'"));
      expect(
        script,
        contains("'unsafe-inline'"),
        reason: 'the exam lockdown in web/index.html is an inline script; '
            'without this keyword the browser blocks it and an exam page '
            'boots with no clipboard or devtools guard',
      );
      expect(
        script,
        contains('https://www.gstatic.com'),
        reason: 'CanvasKit is fetched from there unless the build uses '
            '--no-web-resources-cdn',
      );
      expect(
        script,
        isNot(contains("'unsafe-eval'")),
        reason: "'unsafe-eval' lets any string become code; "
            "'wasm-unsafe-eval' is the narrow allowance CanvasKit needs",
      );

      // The exhaustive list, not a denylist: a new host has to be argued for
      // here before it can load script in a proctoring client.
      for (final source in script) {
        expect(
          _scriptSources.contains(source),
          isTrue,
          reason: 'script-src "$source" is not one of $_scriptSources',
        );
      }
    });

    test('keeps the WebAssembly allowance CanvasKit needs', () {
      expect(csp['script-src'], contains("'wasm-unsafe-eval'"));
    });

    test('connects only to Supabase, Sentry ingest and the local dev server',
        () {
      final connect = csp['connect-src'] ?? const <String>[];

      for (final source in connect) {
        expect(
          _connectSources.contains(source),
          isTrue,
          reason: 'connect-src "$source" is not a Supabase project, Sentry '
              'ingest or localhost; a proctoring client must not be able to '
              'post frames or answers anywhere else',
        );
      }
    });

    test('addresses the realtime and storage endpoints, not just REST', () {
      // Auth and PostgREST are https; Realtime is a websocket, and a
      // connect-src without `wss:` leaves the live monitor silently dead.
      expect(csp['connect-src'], contains('https://*.supabase.co'));
      expect(csp['connect-src'], contains('wss://*.supabase.co'));
      expect(
        csp['img-src'],
        contains('https://*.supabase.co'),
        reason: 'evidence stills are signed URLs on the project host',
      );
    });

    test('lets Google Fonts provide the stylesheet and the font files', () {
      final style = csp['style-src'] ?? const <String>[];
      final font = csp['font-src'] ?? const <String>[];

      // Exhaustive, like the other two: injected CSS can call home through
      // `url()` and `@import`, so `style-src` is not a directive to leave open.
      for (final source in style) {
        expect(
          _styleSources.contains(source),
          isTrue,
          reason: 'style-src "$source" is not one of $_styleSources',
        );
      }
      for (final source in font) {
        expect(
          _fontSources.contains(source),
          isTrue,
          reason: 'font-src "$source" is not one of $_fontSources',
        );
      }

      // The pair a Google Fonts build needs: without the first the stylesheet
      // is refused, and without the second every @font-face inside it fails and
      // the app silently renders in the system face.
      expect(style, contains('https://fonts.googleapis.com'));
      expect(font, contains('https://fonts.gstatic.com'));

      // ...and the pair belongs to *these* directives only. A `<link>` or an
      // `@font-face` load is governed by `style-src` / `font-src`; the only
      // font traffic `connect-src` would govern is a fetch made from Dart, and
      // `main()` disables that (`GoogleFonts.config.allowRuntimeFetching =
      // false`), so the hosts are a widening of the network surface with
      // nothing behind it. `_connectSources` does not name them either; this
      // assertion is the one that says so out loud.
      final connect = csp['connect-src'] ?? const <String>[];
      expect(
        connect,
        isNot(contains('https://fonts.gstatic.com')),
        reason: 'fonts.gstatic.com belongs to font-src: with runtime fetching '
            'off, nothing in the app fetches a font from Dart, so a '
            'connect-src entry only widens what an injected script can reach',
      );
      expect(
        connect,
        isNot(contains('https://fonts.googleapis.com')),
        reason: 'fonts.googleapis.com belongs to style-src, where the '
            'stylesheet is already allowed',
      );
    });

    test('blocks plugins, pins <base> to this origin and forbids form posts',
        () {
      expect(csp['object-src'], <String>["'none'"]);
      expect(csp['base-uri'], <String>["'self'"]);
      expect(csp['form-action'], <String>["'self'"]);
    });
  });
}

/// The complete set `script-src` may name.
const Set<String> _scriptSources = <String>{
  "'self'",
  "'unsafe-inline'",
  "'wasm-unsafe-eval'",
  'https://www.gstatic.com',
};

/// The complete set `style-src` may name.
///
/// `'unsafe-inline'` is Flutter writing element styles directly;
/// `fonts.googleapis.com` is a Google Fonts stylesheet. Nothing else: a
/// `style-src` that reaches `https:` lets injected CSS exfiltrate through
/// `url()` and `@import`.
const Set<String> _styleSources = <String>{
  "'self'",
  "'unsafe-inline'",
  'https://fonts.googleapis.com',
};

/// The complete set `font-src` may name.
///
/// `data:` covers the fonts Flutter inlines, and `fonts.gstatic.com` is where
/// the Google Fonts stylesheet's `@font-face` sources live - the second half of
/// the pair `style-src` starts.
const Set<String> _fontSources = <String>{
  "'self'",
  'data:',
  'https://fonts.gstatic.com',
};

/// The complete set `connect-src` may name.
///
/// `*.supabase.co` / `*.supabase.in` are Supabase's hosted domains (a project
/// is `<ref>.supabase.co`; Auth, Storage, PostgREST and Realtime share the
/// host). `*.ingest.*.sentry.io` is where crash reports go, and only when the
/// build was given a DSN. `www.gstatic.com` is CanvasKit, which the engine
/// fetches itself. The localhost entries are `flutter run -d chrome` and a
/// local Supabase stack: a production deployment can drop them, and this test
/// then fails until it is updated deliberately.
///
/// The Google Fonts hosts are deliberately *not* here. They are `style-src` /
/// `font-src` sources, and `main()` turns `google_fonts`' runtime fetching off
/// (`GoogleFonts.config.allowRuntimeFetching = false`), so no font is ever
/// fetched from Dart - which is the only font traffic `connect-src` would
/// govern.
const Set<String> _connectSources = <String>{
  "'self'",
  'https://*.supabase.co',
  'wss://*.supabase.co',
  'https://*.supabase.in',
  'wss://*.supabase.in',
  'https://*.ingest.sentry.io',
  'https://*.ingest.us.sentry.io',
  'https://*.ingest.de.sentry.io',
  'https://www.gstatic.com',
  'http://localhost:*',
  'http://127.0.0.1:*',
  'ws://localhost:*',
  'ws://127.0.0.1:*',
};
