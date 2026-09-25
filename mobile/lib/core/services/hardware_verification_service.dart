import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;

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
      'cameraNotReadable' || 'NotReadableError' || 'cameraInUse' =>
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
/// student refuses, and on the web `getUserMedia({video, audio})` rejects unless
/// both are granted. That, plus the permission status, is what "verified" means
/// here — the session is released again immediately, because the exam screen
/// opens its own for the duration of the attempt.
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
    // Explicit opt-in only (`--dart-define=MOCK_CAMERA=true`). Not a fallback:
    // without the define this branch is dead code, so a real build can never end
    // up "verifying" simulated hardware.
    if (MediaPipeProctoringService.mockCameraFromEnvironment) {
      debugPrint(
        'ProctorGuard hardware: MOCK_CAMERA is set — skipping the real device '
        'check (development/CI build).',
      );
      return mockReport();
    }

    final permissions = await _permissions.checkCritical();
    if (permissions.denied.isNotEmpty) {
      return _fromDeniedPermissions(permissions.denied);
    }

    // Web only: one getUserMedia call, which both prompts for the grant and
    // unlocks device enumeration (camera_web drops devices without a deviceId,
    // which is exactly what an ungranted browser reports).
    if (_browserProbe.isSupported && !await _browserProbe.ensureAccess()) {
      return const HardwareReport(
        camera: DeviceProbe.failed(ProbeDevice.camera,
            'The browser refused camera access for this site.'),
        microphone: DeviceProbe.failed(ProbeDevice.microphone,
            'The browser refused microphone access for this site.'),
        settingsHint: true,
      );
    }

    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (error) {
      return _cameraFailure(error.code, settingsHint: true);
    } catch (error) {
      debugPrint('ProctorGuard hardware: camera enumeration failed: $error');
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
      debugPrint('ProctorGuard hardware: capture session failed: $error');
      return _cameraFailure(null, message: 'the camera could not be opened');
    } finally {
      // Released here: the exam screen opens its own session for the attempt.
      try {
        await controller.dispose();
      } catch (error) {
        debugPrint('ProctorGuard hardware: releasing the probe failed: $error');
      }
    }
  }

  @override
  Future<void> openSettings() => _permissions.openSettings();

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
