import 'package:flutter/widgets.dart';

typedef OnAppMinimized = void Function();
typedef OnAppResumed = void Function();

/// Watches [AppLifecycleState] transitions during an active exam session.
///
/// `paused` / `inactive` fire on: switching apps, pulling down the
/// notification shade, incoming calls, and (on most Android builds) taking
/// a screenshot triggers a brief `inactive` blip too, so it's caught here
/// without extra screenshot-detection plumbing.
///
/// Register this ONLY while an exam is in progress (attach in
/// `ExamTakingPage.initState`, detach in `dispose`) — you don't want
/// app-minimize violations firing outside of a live session.
class ExamLifecycleObserver extends WidgetsBindingObserver {
  ExamLifecycleObserver({
    required this.onMinimized,
    this.onResumed,
  });

  final OnAppMinimized onMinimized;
  final OnAppResumed? onResumed;

  bool _hasFiredForThisBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (!_hasFiredForThisBackground) {
          _hasFiredForThisBackground = true;
          onMinimized();
        }
        break;
      case AppLifecycleState.resumed:
        _hasFiredForThisBackground = false;
        onResumed?.call();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  void attach() => WidgetsBinding.instance.addObserver(this);
  void detach() => WidgetsBinding.instance.removeObserver(this);
}
