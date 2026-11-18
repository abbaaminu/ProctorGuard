import 'web_camera_preview_style_stub.dart'
    if (dart.library.js_interop) 'web_camera_preview_style_web.dart' as impl;

/// Restates the self-view's CSS on the browser's own `<video>`, once the
/// platform view has attached it.
///
/// Why this exists: on the web the camera preview is not painted by Flutter at
/// all. `camera_web` builds a `<video>` inside a `<div>`, registers that `<div>`
/// as a platform view, and Flutter layers the element **above** its canvas - so
/// the pane's appearance is only as good as the CSS the element carries: a
/// `ClipRRect` in the widget tree cannot round its corners, and Flutter's box
/// does not size the frame inside it.
///
/// `camera_web` does set what the pane depends on (`object-fit: cover`, `width`/
/// `height: 100%` and the front-camera mirror - see `CameraWeb.initialize` and
/// `_applyDefaultVideoStyles`), but those are inline styles on an element owned
/// by another package, applied on `initialize()`. A host page stylesheet served
/// with `video { height: auto }` and `!important`, an element re-attached for a
/// new controller, or any of it being dropped by a plugin upgrade turns the
/// pane into a letterboxed strip or a video spilling over the question - all
/// without a Dart-side error to catch.
///
/// [apply] writes exactly what the pane needs and nothing else: `object-fit:
/// cover`, 100% × 100%, a black backing, and the corner clip on the two elements
/// that wrap the video. It deliberately does **not** touch `transform` - the
/// horizontal flip belongs to `camera_web`, and re-stating it here would either
/// un-mirror a front lens or double-mirror it into a mirror image.
///
/// Only meaningful in a browser: everywhere else [isSupported] is false and
/// [apply] is a no-op returning 0.
abstract class WebCameraPreviewStyle {
  /// Picks the implementation for the platform this code was compiled for.
  factory WebCameraPreviewStyle() => impl.createWebCameraPreviewStyle();

  /// False on every non-web platform (and in VM widget tests).
  bool get isSupported;

  /// Styles every attached camera platform view and returns how many `<video>`
  /// elements it reached.
  ///
  /// Zero means "nothing attached yet": the element exists only once
  /// `HtmlElementView` has built it, which is the frame *after* the widget that
  /// asks for the preview, so a caller retries on the next frame instead of
  /// treating 0 as a failure. [cornerRadius] is the pane's own radius in logical
  /// pixels, and the element is clipped to it. Never throws.
  int apply({double cornerRadius = 10});
}
