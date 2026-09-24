import 'dart:async';

import 'package:exam_proctor/core/services/kiosk_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the Dart half of the kiosk bridge: the wire format on
/// `lock_task_channel` (method names + the reply map the Kotlin side must send)
/// and the escape signal the exam page turns into `app_minimized` violations.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(KioskService.channelName);

  /// Polling interval used by the tests — short, so they stay quick.
  const poll = Duration(milliseconds: 10);

  final calls = <MethodCall>[];
  late Map<String, Object?> startLockReply;

  /// Queued answers for `isLockTaskActive`, consumed in order, so a poll
  /// sequence can be scripted exactly.
  late List<bool> activeReplies;

  /// Answer used once [activeReplies] runs dry.
  late bool idleActiveReply;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void installMockPlatform() {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'startLock':
          return startLockReply;
        case 'isLockTaskActive':
          return activeReplies.isEmpty ? idleActiveReply : activeReplies.removeAt(0);
        default:
          return null;
      }
    });
  }

  setUp(() {
    calls.clear();
    // Polling stays off unless a test asks for it: `canDetectEscape` is what
    // makes the service start its timer.
    startLockReply = <String, Object?>{
      'granted': true,
      'strict': false,
      'canDetectEscape': false,
    };
    activeReplies = <bool>[];
    idleActiveReply = false;
    installMockPlatform();
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('startLock / stopLock', () {
    test('pins the app and reports device-owner strictness', () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'strict': true,
        'canDetectEscape': true,
        'message': 'Locked by device policy',
      };
      final kiosk = KioskService(escapePollInterval: poll);
      addTearDown(kiosk.dispose);

      final result = await kiosk.startLock();

      expect(calls.first.method, 'startLock');
      expect(result.granted, isTrue);
      expect(result.strict, isTrue);
      expect(result.isBestEffort, isFalse);
      expect(result.canDetectEscape, isTrue);
      expect(result.message, 'Locked by device policy');
    });

    test('flags best-effort screen pinning when the app is not whitelisted',
        () async {
      final kiosk = KioskService();
      addTearDown(kiosk.dispose);

      final result = await kiosk.startLock();

      expect(result.granted, isTrue);
      expect(result.strict, isFalse);
      expect(result.isBestEffort, isTrue);
    });

    test('refused pinning comes back as granted: false with a reason',
        () async {
      startLockReply = <String, Object?>{
        'granted': false,
        'strict': false,
        'message': 'Unable to start lock task mode',
      };
      final kiosk = KioskService();
      addTearDown(kiosk.dispose);

      final result = await kiosk.startLock();

      expect(result.granted, isFalse);
      expect(result.message, 'Unable to start lock task mode');
    });

    test('degrades instead of throwing when no platform handler exists',
        () async {
      // iOS/desktop/web: nothing is registered on the channel.
      messenger.setMockMethodCallHandler(channel, null);
      final kiosk = KioskService();
      addTearDown(kiosk.dispose);

      final result = await kiosk.startLock();
      await kiosk.stopLock(); // must not throw either

      expect(result.granted, isFalse);
      expect(result.message, isNotNull);
    });

    test('stopLock unpins without being reported as an escape', () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'canDetectEscape': true,
      };
      // The platform keeps confirming the pin until the app unpins.
      activeReplies = <bool>[];
      idleActiveReply = true;
      final kiosk = KioskService(escapePollInterval: poll);
      addTearDown(kiosk.dispose);
      final escapes = <KioskExitReason>[];
      final sub = kiosk.escapes.listen(escapes.add);
      addTearDown(sub.cancel);

      await kiosk.startLock();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // The app unpins on purpose, so lock task going away is not a strike.
      await kiosk.stopLock();
      idleActiveReply = false;
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(calls.last.method, 'stopLock');
      expect(escapes, isEmpty);
    });

    test('a bridge that never answers cannot hang the exam bootstrap',
        () async {
      // A wedged platform (or an engine that never replies) used to leave
      // `await startLock()` pending forever — i.e. the exam screen stuck on its
      // loading spinner. It now times out and the session runs unpinned.
      messenger.setMockMethodCallHandler(
        channel,
        (call) => Completer<Object?>().future, // accepted, never answered
      );
      final kiosk = KioskService();
      addTearDown(kiosk.dispose);

      final result = await kiosk.startLock();

      expect(result.granted, isFalse);
      expect(result.message, contains('did not answer'));

      // The unpin path has to survive the same silence.
      await kiosk.stopLock();
    });
  });

  group('escape detection', () {
    test('two inactive polls after pinning confirms an escape', () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'canDetectEscape': true,
      };
      activeReplies = <bool>[true, true, false, false];
      final kiosk = KioskService(escapePollInterval: poll);
      addTearDown(kiosk.dispose);
      final escapes = <KioskExitReason>[];
      final sub = kiosk.escapes.listen(escapes.add);
      addTearDown(sub.cancel);

      await kiosk.startLock();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(escapes, <KioskExitReason>[KioskExitReason.studentEscaped]);

      // Polling stops once the escape has been reported.
      final polls = calls.where((c) => c.method == 'isLockTaskActive').length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        calls.where((c) => c.method == 'isLockTaskActive').length,
        polls,
      );
    });

    test('a single inactive poll is not an escape', () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'canDetectEscape': true,
      };
      // A resume animation or permission dialog can produce one blip, and the
      // platform keeps reporting the pin afterwards.
      activeReplies = <bool>[true, false];
      idleActiveReply = true;
      final kiosk = KioskService(escapePollInterval: poll);
      addTearDown(kiosk.dispose);
      final escapes = <KioskExitReason>[];
      final sub = kiosk.escapes.listen(escapes.add);
      addTearDown(sub.cancel);

      await kiosk.startLock();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(escapes, isEmpty);
    });

    test('pinning that never engages is not reported as an escape', () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'canDetectEscape': true,
      };
      // startLockTask() was accepted but the platform never confirms lock task
      // mode (OEM policy): the lifecycle observer still covers minimising.
      activeReplies = <bool>[false, false, false, false, false];
      final kiosk = KioskService(escapePollInterval: poll);
      addTearDown(kiosk.dispose);
      final escapes = <KioskExitReason>[];
      final sub = kiosk.escapes.listen(escapes.add);
      addTearDown(sub.cancel);

      await kiosk.startLock();
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(escapes, isEmpty);
    });

    test('no polling starts when the platform cannot report its state',
        () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'canDetectEscape': false, // e.g. API < 23
      };
      final kiosk = KioskService(escapePollInterval: poll);
      addTearDown(kiosk.dispose);

      final result = await kiosk.startLock();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(result.granted, isTrue);
      expect(
        calls.where((c) => c.method == 'isLockTaskActive'),
        isEmpty,
        reason: 'nothing to compare against, so nothing to poll for',
      );
    });

    test('reports the platform lock task state, false when unsupported',
        () async {
      activeReplies = <bool>[true];
      final kiosk = KioskService();
      addTearDown(kiosk.dispose);

      expect(await kiosk.isLockTaskActive(), isTrue);

      messenger.setMockMethodCallHandler(channel, null);
      expect(await kiosk.isLockTaskActive(), isFalse);
    });

    test('dispose stops polling and closes the stream', () async {
      startLockReply = <String, Object?>{
        'granted': true,
        'canDetectEscape': true,
      };
      activeReplies = <bool>[true, false, false, false];
      final kiosk = KioskService(escapePollInterval: poll);
      final escapes = <KioskExitReason>[];
      final sub = kiosk.escapes.listen(escapes.add);
      addTearDown(sub.cancel);

      await kiosk.startLock();
      kiosk.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(escapes, isEmpty);
      await expectLater(kiosk.escapes, emitsDone);
    });
  });
}
