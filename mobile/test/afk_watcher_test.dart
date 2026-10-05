import 'package:proctorguard/core/services/afk_watcher.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the `idle_afk` rule: three minutes without input is *one* violation,
/// reported at the moment the window opens and never again while the student is
/// away. The clock is injected, so the tests move time by hand instead of
/// waiting for it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  final reported = <String>[];

  setUp(() {
    now = DateTime.utc(2026, 6, 1, 9);
    reported.clear();
  });

  AfkWatcher newWatcher({
    Duration threshold = AfkWatcher.defaultIdleThreshold,
    Duration interval = const Duration(milliseconds: 10),
  }) =>
      AfkWatcher(
        onIdle: () => reported.add('idle'),
        idleThreshold: threshold,
        checkInterval: interval,
        clock: () => now,
      );

  /// Lets the periodic check run a few times. Only the timer needs real time:
  /// the elapsed-time comparison reads the injected clock.
  Future<void> tick() =>
      Future<void>.delayed(const Duration(milliseconds: 40));

  test('nothing is reported while the device is still being touched', () async {
    final watcher = newWatcher();
    addTearDown(watcher.stop);
    watcher.start();

    for (var minute = 0; minute < 3; minute++) {
      now = now.add(const Duration(minutes: 1));
      watcher.noteActivity();
      await tick();
    }

    expect(reported, isEmpty);
    expect(watcher.isWatching, isTrue);
    expect(watcher.idleFor, Duration.zero, reason: 'activity just now');
  });

  test('one idle episode is reported exactly once', () async {
    final watcher = newWatcher();
    addTearDown(watcher.stop);
    watcher.start();

    now = now.add(const Duration(minutes: 2, seconds: 59));
    await tick();
    expect(reported, isEmpty, reason: 'a second short of the window');

    now = now.add(const Duration(seconds: 2));
    await tick();
    expect(reported, <String>['idle']);

    // Still nobody there. The episode has already been reported, so the ticks
    // that follow must not turn one walked-away student into a stream of strikes.
    now = now.add(const Duration(minutes: 5));
    await tick();
    expect(reported, <String>['idle']);
    expect(
      watcher.idleFor,
      const Duration(minutes: 8, seconds: 1),
      reason: 'counted from the last input, not from the last report',
    );
  });

  test('coming back re-arms the watcher for a second episode', () async {
    final watcher = newWatcher();
    addTearDown(watcher.stop);
    watcher.start();

    now = now.add(const Duration(minutes: 4));
    await tick();
    expect(reported, hasLength(1));

    watcher.noteActivity();
    now = now.add(const Duration(minutes: 4));
    await tick();

    expect(reported, hasLength(2), reason: 'a second episode, a second strike');
  });

  test('a keystroke counts as activity even outside a text field', () async {
    final watcher = newWatcher(threshold: const Duration(seconds: 30));
    addTearDown(watcher.stop);
    watcher.start();

    now = now.add(const Duration(seconds: 20));
    // Routed through HardwareKeyboard, which is the path that matters: Flutter
    // sends keys to whoever holds focus, not necessarily to the exam page.
    final handled = HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ),
    );
    expect(handled, isFalse, reason: 'an observer, never a filter');

    now = now.add(const Duration(seconds: 20));
    await tick();

    expect(reported, isEmpty, reason: 'the keystroke reset the idle window');
  });

  test('stop() releases the timer, and start() re-arms it', () async {
    final watcher = newWatcher(threshold: Duration.zero);
    watcher.start();
    expect(watcher.isWatching, isTrue);

    watcher.stop();
    expect(watcher.isWatching, isFalse);
    expect(watcher.idleFor, Duration.zero, reason: 'not watching');

    await tick();
    expect(reported, isEmpty, reason: 'a finished attempt stops reporting');

    watcher.stop(); // idempotent
    watcher.start();
    expect(watcher.isWatching, isTrue);
    watcher.stop();
  });

  test('start() is idempotent, so a retried bootstrap cannot double-report',
      () async {
    final watcher = newWatcher(threshold: Duration.zero);
    addTearDown(watcher.stop);

    watcher.start();
    watcher.start(); // e.g. a rebuild of the exam page
    await tick();

    expect(reported, hasLength(1), reason: 'one timer, one episode');
  });
}
