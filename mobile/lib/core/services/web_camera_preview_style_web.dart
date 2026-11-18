import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../utils/proctor_log.dart';

import 'web_camera_preview_style.dart';

/// Creates the browser styler (web builds only).
WebCameraPreviewStyle createWebCameraPreviewStyle() =>
    const BrowserWebCameraPreviewStyle();

/// Selects the `<video>` Flutter's platform-view host holds.
///
/// `HtmlElementView` puts the element `camera_web` registered inside a
/// `<flt-platform-view>` host, so this reaches the self-view and cannot reach a
/// `<video>` some other part of a host page embedded elsewhere. A renderer that
/// names the host differently answers 0 rather than styling the wrong element -
/// `camera_web`'s own inline styles still keep the preview filling its box.
const String _selfViewVideoSelector = 'flt-platform-view video';

/// Writes the pane's CSS onto the element `camera_web` built.
class BrowserWebCameraPreviewStyle implements WebCameraPreviewStyle {
  const BrowserWebCameraPreviewStyle();

  @override
  bool get isSupported => true;

  @override
  int apply({double cornerRadius = 10}) {
    final radius = '${cornerRadius.toStringAsFixed(1)}px';
    var styled = 0;
    try {
      final videos = web.document.querySelectorAll(_selfViewVideoSelector);
      for (var index = 0; index < videos.length; index++) {
        final node = videos.item(index);
        // `isA` and a cast, not `is`: on the web these are JS interop objects, so
        // a Dart `is` check would answer against the declared supertype (always
        // true) instead of the element actually found.
        if (node == null || !node.isA<web.HTMLVideoElement>()) continue;
        final video = node as web.HTMLVideoElement;

        video.style
          // `cover`, not `contain`: the pane is a fixed box whose aspect ratio
          // is not the lens's (260x195 against a 4:3 capture), and letterboxing
          // a self-view shrinks the face the detector and the supervisor read.
          ..setProperty('object-fit', 'cover')
          ..setProperty('width', '100%')
          ..setProperty('height', '100%')
          // Inline elements leave a few pixels of descender under the video,
          // which shows up as a black hairline at the bottom of the pane.
          ..setProperty('display', 'block')
          // The pane's own backing, so a frame not yet decoded is black rather
          // than the page showing through.
          ..setProperty('background-color', '#000');

        // The wrapper `camera_web` builds around the video, and the host above
        // it: the two boxes that would otherwise paint the video's square
        // corners over the pane's rounded ones.
        _clip(video.parentElement, radius);
        _clip(video.parentElement?.parentElement, radius);
        styled++;
      }
    } catch (error) {
      // Styling is cosmetic. A DOM shape this code does not expect must not
      // reach the exam screen as an exception.
      proctorLog('WebCameraPreviewStyle: self-view not styled: $error');
      return 0;
    }
    return styled;
  }

  /// Clips [element] to the pane's corners without touching its size or its
  /// transform: Flutter positions the host, `camera_web` mirrors the video.
  void _clip(web.Element? element, String radius) {
    // Same reason as above: `isA` before the cast, never `is` on interop.
    if (element == null || !element.isA<web.HTMLElement>()) return;
    (element as web.HTMLElement).style
      ..setProperty('overflow', 'hidden')
      ..setProperty('border-radius', radius);
  }
}
