import 'package:proctorguard/core/services/exam_lifecycle_observer.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Requirement 2, mobile half: while an exam is running, the app being moved to
/// the background (another app, the notification shade, an incoming call) is one
/// violation per *episode* - not one per lifecycle frame, and never one for coming
/// back to the exam.
///
/// The observer is driven directly (its `didChangeAppLifecycleState` is the
/// platform callback), so the rules are testable on the VM without a device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one violation per background episode, none for returning', () {
    var minimized = 0;
    var resumed = 0;
    final observer = ExamLifecycleObserver(
      onMinimized: () => minimized++,
      onResumed: () => resumed++,
    );

    observer.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(minimized, 1);

    // One background episode reports several states on Android
    // (inactive -> hidden -> paused); it must still be one strike.
    observer.didChangeAppLifecycleState(AppLifecycleState.hidden);
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(minimized, 1, reason: 'the same episode is counted once');

    observer.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(resumed, 1);
    expect(minimized, 1, reason: 'returning is not a violation');

    // A second episode is a second violation.
    observer.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(minimized, 2);
  });

  test('a detached engine is not the student leaving the app', () {
    var minimized = 0;
    final observer = ExamLifecycleObserver(onMinimized: () => minimized++);

    observer.didChangeAppLifecycleState(AppLifecycleState.detached);

    expect(minimized, 0);
  });

  test('attach and detach pair around a session', () {
    final observer = ExamLifecycleObserver(
      onMinimized: () {},
      onResumed: () {},
    );

    // The exam page attaches while the attempt is on screen and detaches in
    // dispose(); neither may throw, and the rules above neither depend on nor are
    // changed by being registered.
    observer.attach();
    observer.detach();
    observer.detach(); // dispose can run after a failed bootstrap
  });
}
