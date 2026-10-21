import 'dart:async';

import 'web_face_signal_source.dart';

/// Creates the source where there is no browser to host a detector.
WebFaceSignalSource createWebFaceSignalSource() =>
    const UnsupportedWebFaceSignalSource();

/// Reports "no detector available" for Android, iOS, desktop — and for the Dart
/// VM, which is what `flutter test` runs on.
///
/// Android and iOS do have a detector, just not through this hook: ML Kit feeds
/// `MediaPipeProctoringService` directly. Saying so here keeps one interface for
/// the exam page without promising a bridge that only the browser needs.
class UnsupportedWebFaceSignalSource implements WebFaceSignalSource {
  const UnsupportedWebFaceSignalSource();

  @override
  bool get isSupported => false;

  /// Empty and already still: nothing can call the hook, so nothing is missed.
  @override
  Stream<String> get messages => const Stream<String>.empty();

  @override
  void dispose() {}
}
