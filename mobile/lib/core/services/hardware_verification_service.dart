import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import '../utils/proctor_log.dart';
import 'mediapipe_proctoring_service.dart';
import 'permission_service.dart';
import 'web_camera_permission.dart';

/// The two devices an exam cannot be proctored without.
enum ProbeDevice { camera, microphone }

/// State of a single device probe, as the gate renders it.
enum ProbeOutcome { pending, running, verified, failed }

/// What one device reported — the unit the pre-exam checklist is built from.
class DeviceProbe {
  const DeviceProbe({
    required this.device,
    required this.outcome,
    this.message,
  });

  const DeviceProbe.pending(this.device)
      : outcome = ProbeOutcome.pending,
        message = null;

  const DeviceProbe.running(this.device)
      : outcome = ProbeOutcome.running,
        message = null;

  const DeviceProbe.verified(this.device, {this.message})
      : outcome = ProbeOutcome.verified;

  const DeviceProbe.failed(this.device, this.message)
      : outcome = ProbeOutcome.failed;

  final ProbeDevice device;
  final ProbeOutcome outcome;

  /// Detail for the student ("another app is already using the camera").
  final String? message;

  bool get isVerified => outcome == ProbeOutcome.verified;
  bool get hasFailed => outcome == ProbeOutcome.failed;

  /// "Camera" / "Microphone", for a label.
  String get label => switch (device) {
        ProbeDevice.camera => 'Camera',
        ProbeDevice.microphone => 'Microphone',
      };
}

/// The result of one full pre-exam hardware check.
class HardwareReport {
  const HardwareReport({
    required this.camera,
    required this.microphone,
    this.mock = false,
    this.settingsHint = false,
    this.faceDetectionInactive = false,
  });

  /// Both devices mid-flight (the gate's first frame).
  factory HardwareReport.checking() => const HardwareReport(
        camera: DeviceProbe.running(ProbeDevice.camera),
        microphone: DeviceProbe.running(ProbeDevice.microphone),
      );

  final DeviceProbe camera;
  final DeviceProbe microphone;

  /// True only on the explicit `--dart-define=MOCK_CAMERA=true` path, where no
  /// real hardware is expected (emulators, desktop targets, CI). The gate says
  /// so out loud and the exam screen shows its own MOCK tile — this is never
  /// reached silently.
  final bool mock;

  /// True when a refused **permission** caused this report, so the gate also
  /// offers "Open settings" (Android/iOS stop prompting after a denial).
  final bool settingsHint;

  /// True when this report comes from a platform whose on-device face detector
  /// does not exist — the web, because Google ML Kit has no browser
  /// implementation (the same limitation `PermissionService`'s platform notes
  /// describe).
  ///
  /// The camera and microphone probes are one code path on every platform, so
  /// this is the only thing that tells the gate apart: on the web [isVerified]
  /// can be true — a browser camera is a real camera — while no attempt started
  /// here will flag faces automatically. A student is entitled to know that
  /// before the exam rather than from a proctoring report afterwards: the exam
  /// screen keeps recording what the camera sees, it just cannot pick a face out
  /// of it, so the review is a person's, in full.
  final bool faceDetectionInactive;

  /// The same report, marked [faceDetectionInactive]. How the platform
  /// independent probe's result reaches the gate — kept as a copy rather than a
  /// constructor argument so [DeviceHardwareVerifier.verify] can apply it once,
  /// on the way out, instead of at each of the probe's exits.
  HardwareReport withFaceDetectionInactive() => HardwareReport(
        camera: camera,
        microphone: microphone,
        mock: mock,
        settingsHint: settingsHint,
        faceDetectionInactive: true,
      );

  /// The only state that unlocks "Start Exam".
  bool get isVerified => camera.isVerified && microphone.isVerified;

  bool get hasFailed => camera.hasFailed || microphone.hasFailed;

  bool get isRunning =>
      camera.outcome == ProbeOutcome.running ||
      microphone.outcome == ProbeOutcome.running;

  /// The blocked devices, in checklist order.
  List<DeviceProbe> get failedDevices =>
      <DeviceProbe>[camera, microphone].where((probe) => probe.hasFailed).toList();

  /// The headline shown when the exam cannot start. Deliberately blunt about
  /// both devices being mandatory: a student who reads "microphone" as optional
  /// would otherwise sit an exam that is not being proctored.
  String get blockingMessage {
    final details = failedDevices
        .map((probe) => '${probe.label}: ${probe.message ?? 'not verified'}.')
        .join(' ');
    return 'Camera and microphone are both required for proctoring, and this '
        'device could not verify '
        '${failedDevices.length > 1 ? 'them' : 'one of them'}. '
        '$details Fix it and check again to start the exam.';
  }
}

/// Verifies that a real camera **and** a real microphone can be opened before an
/// exam is allowed to start.
///
/// The contract the exam flow relies on: [verify] always resolves (never throws,
/// never leaves the student on a spinner) and only reports
/// [HardwareReport.isVerified] when both devices were actually proved usable.
abstract class HardwareVerifier {
  /// Picks the real implementation; tests inject a fake instead.
  factory HardwareVerifier() = DeviceHardwareVerifier;

  Future<HardwareReport> verify();

  /// Opens the OS settings page for a permission the student must change there.
  Future<void> openSettings();
}

/// The camera plugin's error codes, worded for a student: the raw code
/// (`cameraAccess`) does not tell anybody what to do about it.
String cameraFailureMessage(String? code) => switch (code) {
      'cameraAccess' || 'CameraAccessDenied' || 'NotAllowedError' =>
        'camera access was refused',
      'audioAccess' || 'AudioAccessDenied' => 'microphone access was refused',
      'cameraNotReadable' || 'NotReadableError' || 'TrackStartError' ||
      'cameraInUse' =>
        'another app or tab is already using the camera',
      'cameraNotFound' || 'NotFoundError' => 'no camera was found',
      'cameraNotSupported' || 'NotSupportedError' =>
        'this browser cannot capture video',
      _ => 'the camera reported "${code ?? 'unknown error'}"',
    };

/// True when a camera-plugin error code is really an *audio* refusal, so the
/// gate can point at the microphone row instead of the camera row.
bool cameraFailureIsAudio(String? code) =>
    code == 'audioAccess' || code == 'AudioAccessDenied';

/// True when a camera-plugin error code means the device is momentarily *held*
/// rather than broken.
///
/// The codes are the same ones [cameraFailureMessage] words as "another app or
/// tab is already using the camera": `camera_web` raises
/// `CameraWebException` → `CameraException('cameraNotReadable', …)` for the
/// DOMException `NotReadableError` / `TrackStartError` (or the raw `name`,
/// depending on which layer rewrote it), and the native plugins have their own
/// `cameraInUse` spelling.
///
/// This is worth its own name because a *busy* device is retryable while a
/// *broken* one is not: on the web Chromium answers the open that follows
/// `availableCameras()` with `NotReadableError` while it is still releasing the
/// device that enumeration just probed, and the next attempt a moment later
/// succeeds. The exam screen uses this to retry exactly that case once (see
/// `ExamTakingPage._openCamera`).
bool isDeviceBusyCameraCode(String? code) =>
    code == 'cameraNotReadable' ||
    code == 'NotReadableError' ||
    code == 'TrackStartError' ||
    code == 'cameraInUse';

/// How long the exam screen waits before re-opening a camera the browser
/// reported as still in use.
///
/// Long enough for the engine to finish tearing down the stream it was
/// replacing (Chromium's own release is a frame or two of work, but a slow
/// Android WebView or a Bluetooth headset's audio endpoint can take longer),
/// and short enough that a student never reads it as a frozen start. Only used
/// for [isDeviceBusyCameraCode] — a refusal or a missing device is final and is
/// reported at once.
const Duration webCameraOpenRetryDelay = Duration(milliseconds: 700);

/// The pixel format ML Kit can consume, per platform.
///
/// ML Kit reads exactly one plane (NV21 on Android, BGRA8888 on iOS); the
/// browser converts frames itself and has neither buffer format, so web keeps
/// the platform default.
ImageFormatGroup proctorImageFormatGroup() {
  if (kIsWeb) return ImageFormatGroup.unknown;
  return defaultTargetPlatform == TargetPlatform.android
      ? ImageFormatGroup.nv21
      : ImageFormatGroup.bgra8888;
}

/// The real probe: permission statuses first, then a live capture session.
///
/// Ordering matters. A *denied* permission is reported per device, so the
/// checklist can say which one to grant; an *unknown* status (a plugin that
/// stayed silent, a platform without the permission) is not treated as a
/// refusal — the capture session below is stronger evidence than a status query,
/// and it is the session that decides. Opening the camera with `enableAudio`
/// covers the microphone in the same step: on Android the plugin asks for
/// `RECORD_AUDIO` as part of the session and reports `audioAccess` when the
/// student refuses. That, plus the permission status, is what "verified" means
/// here — the session is released again immediately, because the exam screen
/// opens its own for the duration of the attempt.
///
/// The **web** takes the other branch on purpose. There is no camera plugin
/// status to read and no session worth opening (see [_webReport]): the one
/// `getUserMedia({video, audio})` the browser probe makes resolves only when a
/// real camera *and* a real microphone were granted, which is exactly the
/// question this class exists to answer — and it is also the only way to ask it
/// without the second open that Chromium reports as "another app or tab is
/// already using the camera".
class DeviceHardwareVerifier implements HardwareVerifier {
  DeviceHardwareVerifier({
    PermissionService? permissions,
    WebCameraPermission? browserProbe,
    this.timeout = defaultTimeout,
  })  : _permissions = permissions ?? PermissionService(),
        _browserProbe = browserProbe ?? WebCameraPermission();

  /// Upper bound on a live capture session; a wedged driver must not strand the
  /// student on the gate's spinner.
  static const Duration defaultTimeout = Duration(seconds: 20);

  final Duration timeout;
  final PermissionService _permissions;
  final WebCameraPermission _browserProbe;

  /// What the gate shows on the documented no-hardware path.
  static HardwareReport mockReport() => const HardwareReport(
        camera: DeviceProbe.verified(ProbeDevice.camera,
            message: 'Simulated — no real camera is opened.'),
        microphone: DeviceProbe.verified(ProbeDevice.microphone,
            message: 'Simulated — no real microphone is opened.'),
        mock: true,
      );
  @override
  Future<HardwareReport> verify() async {
    final report = await _probe();

    // The one platform note, applied here rather than inside the probe: it is a
    // property of the platform and not of how the probe ended, so every exit
    // below (a denied permission, a refused getUserMedia, a camera that never
    // answered) reaches the gate with it already on. A mock build is skipped —
    // MOCK_CAMERA already says nothing here is proctored, and it is the
    // documented way to run on the web.
    if (!kIsWeb || report.mock) return report;
    return report.withFaceDetectionInactive();
  }

  /// The probe itself: permissions, then a live capture session.
  Future<HardwareReport> _probe() async {
    // Explicit opt-in only (`--dart-define=MOCK_CAMERA=true`). Not a fallback:
    // without the define this branch is dead code, so a real build can never end
    // up "verifying" simulated hardware.
    if (MediaPipeProctoringService.mockCameraFromEnvironment) {
      proctorLog(
        'ProctorGuard hardware: MOCK_CAMERA is set — skipping the real device '
        'check (development/CI build).',
      );
      return mockReport();
    }

    final permissions = await _permissions.checkCritical();
    if (permissions.denied.isNotEmpty) {
      return _fromDeniedPermissions(permissions.denied);
    }

    // Web: the browser's own answer is the whole verdict, and one
    // `getUserMedia` call is what produces it — see [_webReport] for why no
    // capture session is opened behind it here.
    if (_browserProbe.isSupported) {
      return _webReport(await _browserProbe.probe());
    }

    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (error) {
      return _cameraFailure(error.code, settingsHint: true);
    } catch (error) {
      proctorLog('ProctorGuard hardware: camera enumeration failed: $error');
      return _cameraFailure(null, message: 'the camera is not available here');
    }

    if (cameras.isEmpty) {
      return _cameraFailure(
        null,
        message: kIsWeb
            ? 'no camera is visible. Allow camera access for this site and '
                'check that the device has one'
            : 'no camera is available on this device',
      );
    }

    final front = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      front,
      ResolutionPreset.low,
      // Opening the audio session in the same call is what makes this a
      // microphone check too — see the class doc.
      enableAudio: true,
      imageFormatGroup: proctorImageFormatGroup(),
    );

    try {
      await controller.initialize().timeout(timeout);

      if (!controller.value.isInitialized ||
          controller.value.previewSize == null) {
        return _cameraFailure(null,
            message: 'the camera opened but produced no frames');
      }

      return const HardwareReport(
        camera: DeviceProbe.verified(ProbeDevice.camera,
            message: 'Live video is streaming.'),
        microphone: DeviceProbe.verified(ProbeDevice.microphone,
            message: 'The recording session is open.'),
      );
    } on TimeoutException {
      return _cameraFailure(null,
          message: 'the camera did not answer within ${timeout.inSeconds}s');
    } on CameraException catch (error) {
      return _cameraFailure(error.code);
    } catch (error) {
      proctorLog('ProctorGuard hardware: capture session failed: $error');
      return _cameraFailure(null, message: 'the camera could not be opened');
    } finally {
      // Released here: the exam screen opens its own session for the attempt.
      try {
        await controller.dispose();
      } catch (error) {
        proctorLog('ProctorGuard hardware: releasing the probe failed: $error');
      }
    }
  }

  @override
  Future<void> openSettings() => _permissions.openSettings();

  /// The web verdict, built from the browser's own `getUserMedia` answer.
  ///
  /// There is deliberately no capture session behind this. On the web
  /// `availableCameras()` already opens (and immediately stops) a stream per
  /// device, and Chromium answers an `initialize()` that follows it with
  /// `NotReadableError` — the "another app or tab is already using the camera"
  /// row students were seeing — because the device it just enumerated has not
  /// finished being released. Opening a third session on the gate bought
  /// nothing: a resolved `getUserMedia({video, audio})` is the browser's own
  /// statement that a real camera **and** a real microphone were granted, it is
  /// the same answer the exam screen's session then confirms for real, and the
  /// web is the one platform where the gate could not turn that stream into
  /// face detection anyway. Fewer opens also means the microphone row is now
  /// reported from the same grant as the camera row, instead of being inferred
  /// from a camera session that may never have started.
  HardwareReport _webReport(WebCameraAccess access) {
    if (!access.granted) {
      return const HardwareReport(
        camera: DeviceProbe.failed(ProbeDevice.camera,
            'The browser refused camera access for this site.'),
        microphone: DeviceProbe.failed(ProbeDevice.microphone,
            'The browser refused microphone access for this site.'),
        settingsHint: true,
      );
    }

    // One half arrived and the other did not: name the missing one rather than
    // reporting the pair as one failure, so the student knows what to plug in or
    // un-mute. This is how a laptop with a camera and no microphone reads.
    if (!access.video || !access.audio) {
      return HardwareReport(
        camera: access.video
            ? const DeviceProbe.verified(ProbeDevice.camera,
                message: 'Live video is streaming.')
            : const DeviceProbe.failed(ProbeDevice.camera,
                'The browser granted access but no camera answered. '
                'Check that a camera is connected and not hidden behind a '
                'closed lid.'),
        microphone: access.audio
            ? const DeviceProbe.verified(ProbeDevice.microphone,
                message: 'The recording session is open.')
            : const DeviceProbe.failed(ProbeDevice.microphone,
                'The browser granted access but no microphone answered. '
                'Check that one is connected and selected.'),
        settingsHint: true,
      );
    }

    return const HardwareReport(
      camera: DeviceProbe.verified(ProbeDevice.camera,
          message: 'Live video is streaming.'),
      microphone: DeviceProbe.verified(ProbeDevice.microphone,
          message: 'The recording session is open.'),
    );
  }

  /// One refused permission is enough to block, and the report names it.
  HardwareReport _fromDeniedPermissions(List<StartupPermission> denied) {
    final cameraDenied = denied.contains(StartupPermission.camera);
    final microphoneDenied = denied.contains(StartupPermission.microphone);

    return HardwareReport(
      camera: cameraDenied
          ? const DeviceProbe.failed(ProbeDevice.camera,
              'Access was refused. Grant it in your device settings.')
          : const DeviceProbe.pending(ProbeDevice.camera),
      microphone: microphoneDenied
          ? const DeviceProbe.failed(ProbeDevice.microphone,
              'Access was refused. Grant it in your device settings.')
          : const DeviceProbe.pending(ProbeDevice.microphone),
      settingsHint: true,
    );
  }

  /// A capture-session failure: the camera row carries the reason, and the
  /// microphone row says plainly that it could not be confirmed — `enableAudio`
  /// opens both in one call, so an unverified microphone must never read as
  /// "fine".
  HardwareReport _cameraFailure(
    String? code, {
    String? message,
    bool settingsHint = false,
  }) {
    final detail = message ?? cameraFailureMessage(code);

    if (cameraFailureIsAudio(code)) {
      return HardwareReport(
        camera: const DeviceProbe.verified(ProbeDevice.camera,
            message: 'Video is streaming, but the microphone was refused.'),
        microphone: DeviceProbe.failed(ProbeDevice.microphone, detail),
        settingsHint: true,
      );
    }

    return HardwareReport(
      camera: DeviceProbe.failed(ProbeDevice.camera, detail),
      microphone: const DeviceProbe.failed(ProbeDevice.microphone,
          'Not verified — the recording session could not be opened.'),
      settingsHint: settingsHint,
    );
  }
}
