import 'package:exam_proctor/core/services/hardware_integrity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the Dart half of the device-integrity bridge: the wire format on
/// `hardware_integrity_channel` (the method `MainActivity.kt` must answer), what a
/// missing or partial native reply means, and the reporting *policy* — a finding is
/// reported when it appears rather than while it lasts, and a platform that cannot
/// answer is never an accusation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(HardwareIntegrityService.channelName);

  /// Polling interval used by the tests — short, so they stay quick.
  const poll = Duration(milliseconds: 10);

  final calls = <MethodCall>[];

  /// Answer for the next probe. `null` means "no native half listening".
  late Map<String, Object?>? Function() reply;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    calls.clear();
    reply = () => null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply();
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// Lets a few polls go by.
  Future<void> polls([int count = 4]) async {
    for (var i = 0; i < count; i++) {
      await Future<void>.delayed(poll);
    }
  }

  group('check()', () {
    test('names the channel the native handler registers', () {
      // The Kotlin side hard-codes the same string; a rename on one side only is a
      // silently disabled check, because an unanswered channel is indistinguishable
      // from a clean device.
      expect(HardwareIntegrityService.channelName, 'hardware_integrity_channel');
      expect(
        HardwareIntegrityService.defaultInterval,
        const Duration(seconds: 15),
      );
    });

    test('sends the camera in use and reads the native report', () async {
      reply = () => <String, Object?>{
            'supported': true,
            'secondaryDisplay': true,
            'secondaryDisplayNames': <Object?>['SAMSUNG S24 (casting)', 7],
            'virtualCamera': false,
            'externalCameraSupported': true,
            'detail': 'a second display is attached',
          };
      final integrity = HardwareIntegrityService();

      final report = await integrity.check(cameraId: '1');

      expect(calls.single.method, 'getIntegrityReport');
      expect(calls.single.arguments, <String, Object?>{'cameraId': '1'});
      expect(report.supported, isTrue);
      expect(report.secondaryDisplay, isTrue);
      expect(
        report.secondaryDisplays,
        <String>['SAMSUNG S24 (casting)'],
        reason: 'a malformed name is dropped, not fatal',
      );
      expect(report.virtualCamera, isFalse);
      expect(report.externalCameraSupported, isTrue);
      expect(report.detail, 'a second display is attached');
      expect(report.hasFinding, isTrue);
    });

    test('a missing handler is "cannot see", not "clean"', () async {
      final integrity = HardwareIntegrityService();

      final report = await integrity.check();

      expect(calls.single.arguments, <String, Object?>{'cameraId': null});
      expect(report.supported, isFalse);
      expect(report.hasFinding, isFalse);
      expect(integrity.isMonitoring, isFalse);
    });

    test('a partial reply from an older host reads as not found', () async {
      // A host whose native half predates this contract: the flags are simply
      // absent, and inside the proctoring path that must not throw.
      reply = () => <String, Object?>{'supported': true};
      final integrity = HardwareIntegrityService();

      final report = await integrity.check();

      expect(report.supported, isTrue);
      expect(report.secondaryDisplays, isEmpty);
      expect(report.detail, isNull);
      expect(report.hasFinding, isFalse);
    });
  });

  group('startMonitoring()', () {
    test('reports a display when it appears, once per episode', () async {
      var attached = false;
      reply = () => <String, Object?>{
            'supported': true,
            'secondaryDisplay': attached,
            'secondaryDisplayNames':
                attached ? <Object?>['HDMI-1'] : const <Object?>[],
          };
      final integrity = HardwareIntegrityService();
      addTearDown(integrity.stopMonitoring);
      final findings = <HardwareFinding>[];
      var cameraId = '1';

      integrity.startMonitoring(
        onFinding: findings.add,
        cameraId: () => cameraId,
        interval: poll,
      );
      expect(integrity.isMonitoring, isTrue);

      await polls();
      expect(findings, isEmpty, reason: 'a clean device is silence');

      attached = true;
      await polls();
      expect(findings, <HardwareFinding>[HardwareFinding.secondaryDisplay]);
      expect(
        calls.last.arguments,
        <String, Object?>{'cameraId': '1'},
        reason: 'the camera in use is read again on every probe',
      );

      await polls();
      expect(findings, hasLength(1), reason: 'still attached is not a new event');

      // Unplugged, then plugged back in: a second event — and by then the attempt
      // may well be on its second camera.
      attached = false;
      await polls();
      attached = true;
      cameraId = '2';
      await polls();

      expect(findings, hasLength(2), reason: 'reconnecting is a new event');
      expect(calls.last.arguments, <String, Object?>{'cameraId': '2'});
    });

    test('a probe that cannot succeed is not a finding', () async {
      final integrity = HardwareIntegrityService(); // reply: null
      addTearDown(integrity.stopMonitoring);
      final findings = <HardwareFinding>[];

      integrity.startMonitoring(onFinding: findings.add, interval: poll);
      await polls();

      expect(findings, isEmpty);
      expect(calls, isNotEmpty, reason: 'the poll itself still runs');
      expect(integrity.isMonitoring, isTrue);
    });

    test('stopMonitoring stops polling and re-arms the findings', () async {
      reply = () => <String, Object?>{
            'supported': true,
            'virtualCamera': true,
          };
      final integrity = HardwareIntegrityService();
      final findings = <HardwareFinding>[];

      integrity.startMonitoring(onFinding: findings.add, interval: poll);
      await polls();
      expect(findings, <HardwareFinding>[HardwareFinding.virtualCamera]);

      integrity.stopMonitoring();
      await pumpEventQueue(); // let any in-flight probe settle
      expect(integrity.isMonitoring, isFalse);

      final settled = calls.length;
      await polls();
      expect(
        calls,
        hasLength(settled),
        reason: 'a finished attempt stops probing the device',
      );

      // A restarted attempt has not seen anything yet, so the camera that is still
      // substituted is reported again rather than remembered.
      integrity.startMonitoring(onFinding: findings.add, interval: poll);
      await polls();
      expect(findings, hasLength(2));

      integrity.dispose(); // alias for stopMonitoring
      expect(integrity.isMonitoring, isFalse);
      integrity.dispose(); // idempotent
    });

    test('startMonitoring is idempotent: one timer, one report', () async {
      reply = () => <String, Object?>{
            'supported': true,
            'secondaryDisplay': true,
          };
      final integrity = HardwareIntegrityService();
      addTearDown(integrity.stopMonitoring);
      final findings = <HardwareFinding>[];

      integrity.startMonitoring(onFinding: findings.add, interval: poll);
      integrity.startMonitoring(onFinding: findings.add, interval: poll);
      await polls();

      expect(findings, hasLength(1));
    });
  });
}
