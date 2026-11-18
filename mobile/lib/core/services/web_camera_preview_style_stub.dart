import 'web_camera_preview_style.dart';

/// Creates the styler for platforms that have no browser.
WebCameraPreviewStyle createWebCameraPreviewStyle() =>
    const UnsupportedWebCameraPreviewStyle();

/// No-op styler for Android, iOS, desktop - and for the Dart VM, which is what
/// `flutter test` runs on.
///
/// Off the web there is nothing to restate: the preview is a texture (or a
/// `Texture` platform view) painted *inside* the widget tree, so `ClipRRect`
/// rounds it, the caller's `SizedBox` sizes it, and no stylesheet can reach it.
/// The mirror, the crop and the corners are all Flutter's own.
class UnsupportedWebCameraPreviewStyle implements WebCameraPreviewStyle {
  const UnsupportedWebCameraPreviewStyle();

  @override
  bool get isSupported => false;

  /// Always 0: no element exists to style, and a caller retrying on the next
  /// frame must not be told otherwise. Every caller checks [isSupported] first,
  /// so this is never read as "not attached yet".
  @override
  int apply({double cornerRadius = 10}) => 0;
}
