import 'dart:async';

import 'package:proctorguard/core/services/hardware_verification_service.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/presentation/pages/exam_hardware_gate_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mandatory pre-exam hardware gate.
///
/// The rules pinned here: "Start Exam" stays disabled until **both** the camera
/// and the microphone have been verified, a refusal says that both are required
/// (and offers a way to fix it), the student can always back out, and the mock
/// build announces itself instead of quietly passing as proctored.
void main() {
  // Plugin channels (camera, permission_handler) need a binding even when the
  // test expects no plugin to be registered behind them.
  TestWidgetsFlutterBinding.ensureInitialized();

  const exam = Exam(
    id: 'exam-1',
    title: 'CS101: Computer Science Fundamentals',
    createdBy: 'sup-1',
    durationMinutes: 60,
    isPublished: true,
  );

  const verified = HardwareReport(
    camera: DeviceProbe.verified(ProbeDevice.camera,
        message: 'Live video is streaming.'),
    microphone: DeviceProbe.verified(ProbeDevice.microphone,
        message: 'The recording session is open.'),
  );

  const refused = HardwareReport(
    camera: DeviceProbe.failed(ProbeDevice.camera,
        'Access was refused. Grant it in your device settings.'),
    microphone: DeviceProbe.failed(ProbeDevice.microphone,
        'Access was refused. Grant it in your device settings.'),
    settingsHint: true,
  );

  /// Pushes the gate behind a launcher route, so the test can see which value it
  /// pops when the student starts or backs out.
  Future<(_GateHost, WidgetTester)> pushGate(
    WidgetTester tester,
    HardwareVerifier verifier,
  ) async {
    final host = _GateHost();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  host.result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute<bool>(
                      builder: (_) =>
                          ExamHardwareGatePage(exam: exam, verifier: verifier),
                    ),
                  );
                  host.popped = true;
                },
                child: const Text('enter exam'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('enter exam'));
    await tester.pumpAndSettle();
    expect(host.popped, isFalse, reason: 'the gate is showing');
    return (host, tester);
  }

  bool startEnabled(WidgetTester tester) =>
      tester
          .widget<FilledButton>(find.byKey(const Key('gate-start-exam')))
          .onPressed !=
      null;

  bool cancelEnabled(WidgetTester tester) =>
      tester
          .widget<TextButton>(find.byKey(const Key('gate-cancel')))
          .onPressed !=
      null;

  /// Scrolls [key] into view before tapping it: the gate scrolls, and on the
  /// 800x600 test viewport the actions sit below the checklist.
  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('keeps Start Exam disabled while checking, then allows entry',
      (tester) async {
    final verifier = _PendingVerifier();

    await tester.pumpWidget(
      MaterialApp(home: ExamHardwareGatePage(exam: exam, verifier: verifier)),
    );
    await tester.pump(); // initState -> first frame, check still in flight

    expect(find.text('Start Exam'), findsOneWidget);
    expect(startEnabled(tester), isFalse,
        reason: 'nothing is verified yet, so the exam cannot start');
    expect(find.text('Checking…'), findsOneWidget);

    verifier.completer.complete(verified);
    await tester.pumpAndSettle();

    expect(startEnabled(tester), isTrue);
    expect(find.byKey(const Key('gate-warning')), findsNothing);
  });

  testWidgets('a refused device blocks entry and explains both are required',
      (tester) async {
    final (host, _) =
        await pushGate(tester, _FakeVerifier(<HardwareReport>[refused]));

    expect(find.byKey(const Key('gate-warning')), findsOneWidget);
    expect(
      find.textContaining('Camera and microphone are both required'),
      findsOneWidget,
    );
    expect(startEnabled(tester), isFalse);
    // Both rows carry the reason, and the summary above them repeats it.
    expect(find.textContaining('Access was refused'), findsWidgets);

    // Tapping the disabled button changes nothing: still on the gate.
    await tapKey(tester, const Key('gate-start-exam'));
    expect(find.text('Device check'), findsOneWidget);
    expect(host.popped, isFalse);
  });

  testWidgets('starting pops true once both devices are verified',
      (tester) async {
    final (host, _) =
        await pushGate(tester, _FakeVerifier(<HardwareReport>[verified]));

    expect(startEnabled(tester), isTrue);
    await tapKey(tester, const Key('gate-start-exam'));

    expect(host.result, isTrue);
  });

  testWidgets('a camera-only failure still blocks: the microphone is mandatory',
      (tester) async {
    final (host, _) = await pushGate(
      tester,
      _FakeVerifier(<HardwareReport>[
        const HardwareReport(
          camera: DeviceProbe.failed(ProbeDevice.camera, 'no camera was found'),
          microphone: DeviceProbe.verified(ProbeDevice.microphone,
              message: 'The recording session is open.'),
        ),
      ]),
    );

    expect(
      find.textContaining('Camera and microphone are both required'),
      findsOneWidget,
    );
    expect(find.textContaining('no camera was found'), findsWidgets);
    expect(startEnabled(tester), isFalse);

    await tapKey(tester, const Key('gate-start-exam'));
    expect(host.popped, isFalse);
  });

  testWidgets('a microphone-only failure blocks too', (tester) async {
    await pushGate(
      tester,
      _FakeVerifier(<HardwareReport>[
        const HardwareReport(
          camera: DeviceProbe.verified(ProbeDevice.camera,
              message: 'Live video is streaming.'),
          microphone: DeviceProbe.failed(
              ProbeDevice.microphone, 'microphone access was refused'),
        ),
      ]),
    );

    expect(startEnabled(tester), isFalse);
    expect(find.textContaining('microphone access was refused'), findsWidgets);
  });

  testWidgets('Check again re-runs the check and clears the block',
      (tester) async {
    final verifier = _FakeVerifier(<HardwareReport>[refused, verified]);
    final (host, _) = await pushGate(tester, verifier);

    expect(verifier.calls, 1);
    expect(startEnabled(tester), isFalse);

    await tapKey(tester, const Key('gate-check-again'));

    expect(verifier.calls, 2, reason: 'the student can retry after fixing it');
    expect(find.byKey(const Key('gate-warning')), findsNothing);
    expect(startEnabled(tester), isTrue);
    expect(host.popped, isFalse);
  });

  testWidgets('Open settings is offered for a refused permission',
      (tester) async {
    final verifier = _FakeVerifier(<HardwareReport>[refused]);
    await pushGate(tester, verifier);

    await tapKey(tester, const Key('gate-open-settings'));

    expect(verifier.settingsOpened, 1);
  });

  testWidgets('backing out reports "not verified" instead of starting',
      (tester) async {
    final (host, _) =
        await pushGate(tester, _FakeVerifier(<HardwareReport>[refused]));

    expect(cancelEnabled(tester), isTrue);
    await tapKey(tester, const Key('gate-cancel'));

    expect(host.result, isFalse);
    expect(host.popped, isTrue);
  });

  testWidgets('the mock build says so out loud and still allows entry',
      (tester) async {
    await pushGate(
      tester,
      _FakeVerifier(<HardwareReport>[DeviceHardwareVerifier.mockReport()]),
    );

    expect(find.textContaining('MOCK HARDWARE'), findsOneWidget);
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('a web attempt is told face detection is inactive, and still '
      'starts', (tester) async {
    await pushGate(
      tester,
      _FakeVerifier(<HardwareReport>[verified.withFaceDetectionInactive()]),
    );

    expect(find.byKey(const Key('gate-face-detection-note')), findsOneWidget);
    // The note is information, not a gate: a browser camera is a real camera,
    // so a verified report still unlocks entry.
    expect(startEnabled(tester), isTrue);
  });

  testWidgets('a platform with an on-device detector shows no such note',
      (tester) async {
    await pushGate(tester, _FakeVerifier(<HardwareReport>[verified]));

    expect(find.byKey(const Key('gate-face-detection-note')), findsNothing);
    expect(startEnabled(tester), isTrue);
  });

  test('the platform note is a copy: the probe results are untouched', () {
    final web = verified.withFaceDetectionInactive();

    expect(web.faceDetectionInactive, isTrue);
    expect(web.isVerified, isTrue);
    expect(web.hasFailed, isFalse);
    expect(web.camera.message, verified.camera.message);
    expect(web.microphone.message, verified.microphone.message);
    // Nothing else is implied by the platform: this is not a mock build, and it
    // is not a refusal that would offer "Open settings".
    expect(web.mock, isFalse);
    expect(web.settingsHint, isFalse);
  });

  testWidgets('fits a small phone and a desktop viewport without overflowing',
      (tester) async {
    for (final size in const <Size>[Size(320, 568), Size(1440, 900)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: ExamHardwareGatePage(
            exam: exam,
            verifier: _FakeVerifier(<HardwareReport>[refused]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // A RenderFlex overflow surfaces as an exception here.
      expect(tester.takeException(), isNull, reason: 'overflowed at $size');
      expect(find.byKey(const Key('gate-warning')), findsOneWidget);
      expect(find.text('Start Exam'), findsOneWidget);
    }
  });

  test('the real verifier blocks instead of throwing when the platform has no '
      'camera plugin', () async {
    // No plugin is registered in a test run — the same shape as a device whose
    // camera stack refused. The gate must receive a blocked report, never an
    // exception: the exam screen has no back button to escape a crash with.
    final report = await DeviceHardwareVerifier().verify();

    expect(report.isVerified, isFalse);
    expect(report.hasFailed, isTrue);
  });
}

/// Holds what the gate popped, observed after the route closed.
class _GateHost {
  bool? result;
  bool popped = false;
}

/// Serves a scripted report per call (the last one repeats once exhausted).
class _FakeVerifier implements HardwareVerifier {
  _FakeVerifier(this._responses);

  final List<HardwareReport> _responses;
  int calls = 0;
  int settingsOpened = 0;

  @override
  Future<HardwareReport> verify() async {
    final index = calls < _responses.length ? calls : _responses.length - 1;
    calls++;
    return _responses[index];
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}

/// Never answers until the test completes it, so the "pending" UI can be seen.
class _PendingVerifier implements HardwareVerifier {
  final Completer<HardwareReport> completer = Completer<HardwareReport>();

  @override
  Future<HardwareReport> verify() => completer.future;

  @override
  Future<void> openSettings() async {}
}
