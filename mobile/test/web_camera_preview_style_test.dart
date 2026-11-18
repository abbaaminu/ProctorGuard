import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/web_camera_preview_style.dart';

/// Pins the browser half of the self-view, the way
/// `web_face_detector_contract_test.dart` pins the face sensor.
///
/// The self-view is a `<video>` element on the web, layered above Flutter's
/// canvas by `camera_web`. Nothing in `flutter test` can observe it - there is no
/// DOM on the VM - so the contract is the source: what the styler writes, what it
/// must never write, and when the widget applies it.
///
/// Each group stands for a way this fails silently in production:
///
///  * **The pane was styled on a platform that has no DOM.** A stub that
///    reported support would have every widget test reach for `document`.
///  * **The crop was never restated.** `camera_web`'s own inline styles are the
///    only thing keeping the preview inside its box; a pane that restates none
///    of them is one plugin upgrade - or one host stylesheet - away from a
///    stretched or letterboxed self-view.
///  * **The mirror was overwritten.** `camera_web` flips a front lens with
///    `transform: scaleX(-1)`; writing a transform here would un-mirror the
///    student's own face (or mirror it twice).
///  * **The style ran before the element existed.** `HtmlElementView` creates
///    the element the frame *after* the widget that asks for it, so styling
///    during build - or once, with no retry - reaches nothing.
void main() {
  /// Reads a file relative to the package root (`mobile/`, the working directory
  /// `flutter test` uses). Null when a checkout does not have it, so a failure
  /// says "missing" rather than throwing a `FileSystemException`.
  String? read(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  final webSource = read('lib/core/services/web_camera_preview_style_web.dart');
  final widgetSource =
      read('lib/features/exam/presentation/widgets/exam_session_widgets.dart');
  final pageSource =
      read('lib/features/exam/presentation/pages/exam_taking_page.dart');

  group('no browser, no styling', () {
    test('the VM picks the stub, which styles nothing', () {
      final style = WebCameraPreviewStyle();

      // Every widget test runs on the VM: a stub that claimed support would
      // have the exam screen reaching for a `document` that does not exist.
      expect(style.isSupported, isFalse);
      expect(style.apply(), 0);
      expect(style.apply(cornerRadius: 4), 0);
    });
  });

  group('the browser half states the pane\'s CSS', () {
    /// The styler, with one assertion of presence so every test below can use it
    /// as a plain string.
    String styler() {
      expect(
        webSource,
        isNotNull,
        reason:
            'lib/core/services/web_camera_preview_style_web.dart is missing - a '
            "browser build has nothing restating the self-view's CSS",
      );
      return webSource!;
    }

    test('it writes the crop and the full size onto the element', () {
      final source = styler();

      // `cover` is the whole point: the pane's box is not the lens's aspect
      // ratio, and `contain` would letterbox the face the detector reads.
      expect(
        source,
        contains("setProperty('object-fit', 'cover')"),
        reason: 'the preview must fill the pane, not letterbox inside it',
      );
      expect(source, contains("setProperty('width', '100%')"));
      expect(source, contains("setProperty('height', '100%')"));
      // A black backing, so a frame that has not decoded yet is not the page
      // showing through the pane.
      expect(source, contains("setProperty('background-color', '#000')"));
    });

    test('it clips the two boxes that wrap the video', () {
      final source = styler();

      // A platform view is not painted by Flutter: the pane's rounded corners
      // exist only if the elements around the video are clipped.
      expect(source, contains("setProperty('overflow', 'hidden')"));
      expect(source, contains("setProperty('border-radius', radius)"));
      expect(
        source,
        contains('video.parentElement'),
        reason: 'the wrapper camera_web builds around the video',
      );
      expect(
        source,
        contains('video.parentElement?.parentElement'),
        reason: "Flutter's platform-view host above it",
      );
    });

    test('it never touches the transform camera_web mirrors with', () {
      final source = styler();

      // `camera_web` flips a front lens with `transform: scaleX(-1)` at attach.
      // Restating or resetting it here would un-mirror the student's face.
      expect(
        source,
        isNot(contains("setProperty('transform'")),
        reason:
            'the mirror belongs to camera_web - a transform written here '
            'un-mirrors or double-mirrors the preview',
      );
    });

    test('it reaches the self-view and nothing else', () {
      final source = styler();

      // Scoped to Flutter's platform-view host: a bare `video` selector would
      // restyle any video a host page embeds, and would not say which video is
      // the camera.
      expect(source, contains("'flt-platform-view video'"));
      expect(source, contains('querySelectorAll'));
      // Cosmetic work must not be able to fail the exam screen.
      expect(source, contains('catch'));
    });
  });

  group('the widget styles the element after it attaches', () {
    test('the preview applies the style post-frame, from the state', () {
      expect(
        widgetSource,
        isNotNull,
        reason: 'lib/features/exam/presentation/widgets/'
            'exam_session_widgets.dart is missing - the self-view widget lives '
            'there',
      );
      final source = widgetSource!;

      expect(source, contains('class ExamSelfViewPreview'));
      // The element exists only after the frame that builds the platform view.
      expect(
        source,
        contains('addPostFrameCallback'),
        reason:
            'a style applied during build reaches an element that has not been '
            'created yet',
      );
      // ...and the camera can take one more frame to attach, so the attempt is
      // retried - a bounded number of times, never in a loop.
      expect(source, contains('_maxStyleAttempts'));
      expect(source, contains('apply(cornerRadius:'));
      // A post-frame callback waits for a frame; it does not ask for one. Without
      // this the retry chain would advance only when the exam clock (once a
      // second) happened to repaint - or never, on a page drawing no frames.
      expect(
        source,
        contains('scheduleFrame()'),
        reason: 'the retry chain has to request the frames it waits on',
      );
      // Off the web there is no element and no styling to do.
      expect(source, contains('_style.isSupported'));
    });

    test('a new controller re-styles', () {
      final source = widgetSource!;

      // A different controller is a different platform view, and a different
      // `<video>` to style: the one case that must style again.
      expect(source, contains('didUpdateWidget'));
      expect(source, contains('identical(oldWidget.controller'));
    });

    test('the exam page renders its preview through that widget', () {
      expect(pageSource, isNotNull);
      final source = pageSource!;

      expect(
        source,
        contains('ExamSelfViewPreview('),
        reason: 'the pane must use the widget that restates the browser CSS, '
            'not a bare CameraPreview',
      );
      // One preview, built in two shapes: the float and the phone strip must
      // never both be mounted, or a second platform view would attach for the
      // same controller.
      expect(
        'ExamSelfViewPreview('.allMatches(source).length,
        1,
        reason: 'the self-view is built once, in _buildCameraPane',
      );
      // Both shapes carry the same key, so a layout test can find the pane in
      // either: pinned in the corner on a wide viewport, in the flow on a phone.
      expect(source, contains("Key('exam-self-view')"));
    });
  });
}
