import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

/// The device-level integrity signals an exam attempt can be checked against.
///
/// Both are things the *proctoring app cannot see through*: a second screen is
/// somewhere else the exam content can be read or replicated, and a camera that
/// is not the device's own lens is a feed the student (or a virtual-camera app)
/// can substitute for the real one.
enum HardwareFinding {
  /// Another display is attached (HDMI/DP, screen casting, mirroring).
  secondaryDisplay,

  /// The camera feeding the attempt is not this device's own lens: an external
  /// (USB) camera, or an emulator's virtual camera.
  virtualCamera,
}

/// What one integrity probe reported.
///
/// [supported] is the gate the caller reads first: on every platform without a
/// native half (and in a test, and in a build without the channel) the probe
/// answers `unsupported` and the caller reports nothing. An unsupported probe is
/// **not** a finding — silence here means "cannot see", never "clean".
class HardwareIntegrityReport {
  const HardwareIntegrityReport({
    required this.supported,
    this.secondaryDisplay = false,
    this.secondaryDisplays = const <String>[],
    this.virtualCamera = false,
    this.externalCameraSupported = false,
    this.detail,
  });

  /// No native probe answered.
  const HardwareIntegrityReport.unsupported()
      : supported = false,
        secondaryDisplay = false,
        secondaryDisplays = const <String>[],
        virtualCamera = false,
        externalCameraSupported = false,
        detail = null;

  /// Rebuilds a report from the native reply.
  ///
  /// Every field is read defensively: a host whose native half predates this
  /// contract answers a partial map, and a missing flag must read as "not found"
  /// rather than throwing inside the proctoring path.
  factory HardwareIntegrityReport.fromPlatform(Map<Object?, Object?> reply) =>
      HardwareIntegrityReport(
        supported: reply['supported'] == true,
        secondaryDisplay: reply['secondaryDisplay'] == true,
        secondaryDisplays: <String>[
          for (final name in reply['secondaryDisplayNames'] as List<Object?>? ??
              const <Object?>[])
            if (name is String) name,
        ],
        virtualCamera: reply['virtualCamera'] == true,
        externalCameraSupported: reply['externalCameraSupported'] == true,
        detail: reply['detail'] as String?,
      );

  final bool supported;

  /// True when at least one display other than the default is on and attached.
  final bool secondaryDisplay;

  /// The attached displays' names, for the audit trail ("SAMSUNG S24 (casting)").
  final List<String> secondaryDisplays;

  /// True when the camera in use (or one attached to the device) is not a
  /// physical lens of this device.
  final bool virtualCamera;

  /// True when the platform itself supports external cameras at all. Reported for
  /// context only: on its own it is a device capability, not a violation.
  final bool externalCameraSupported;

  /// One human-readable sentence about what was found, or null when clean.
  final String? detail;

  /// True when this report is evidence of [HardwareFinding]s.
  bool get hasFinding => secondaryDisplay || virtualCamera;

  @override
  String toString() => 'HardwareIntegrityReport('
      'supported: $supported, '
      'secondaryDisplay: $secondaryDisplay, '
      'virtualCamera: $virtualCamera, '
      'detail: $detail)';
}

/// Reads the device-integrity signals Android can see for an exam session, and
/// watches them for as long as the attempt lasts (see [HardwareFinding]).
///
/// The native half is `MainActivity.kt` (`hardware_integrity_channel`,
/// `getIntegrityReport`), which is also where the *rules* about what counts as a
/// virtual camera live — they are Android API questions (`LENS_FACING_EXTERNAL`,
/// the emulator's build fingerprint), not Dart ones. This class owns the
/// *policy*: how often to look, that a finding is reported when it appears rather
/// than while it lasts, and that a platform which cannot answer is never an
/// accusation.
///
/// The check is a poll rather than a broadcast receiver on purpose: `DISPLAY_ADDED`
/// is a sticky broadcast that a plain app may not register for from Android 14
/// on, while polling a `DisplayManager` list is a permission-free read that
/// cannot go stale — and the exam is a bounded window, so there is no
/// long-lived registration to leak.
class HardwareIntegrityService {
  HardwareIntegrityService({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 3),
  }) : _channel = channel ?? platformChannel;

  /// The channel `MainActivity` registers its integrity handler on.
  static const String channelName = 'hardware_integrity_channel';

  /// Default instance, for the production path.
  static const MethodChannel platformChannel = MethodChannel(channelName);

  /// How often the device is re-checked while an attempt runs.
  ///
  /// A display or a USB camera is plugged in by hand, so this only has to be
  /// faster than a student is willing to wait — and it has to stay cheap, because
  /// every probe is a platform round-trip (two `getSystemService` lookups and a
  /// camera-id list; no camera is opened).
  static const Duration defaultInterval = Duration(seconds: 15);

  /// True only on the platform that has a native half.
  ///
  /// Everything else would answer "no implementation", so the exam page checks
  /// this before starting a poll it knows cannot succeed.
  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;

  /// Upper bound on one probe: a platform that stops answering must not keep the
  /// exam waiting (see [check]).
  final Duration timeout;

  Timer? _timer;
  bool _checking = false;
  bool _stopped = true;
  bool _reportedSecondaryDisplay = false;
  bool _reportedVirtualCamera = false;

  /// True between [startMonitoring] and [stopMonitoring].
  bool get isMonitoring => _timer != null;

  /// One probe, resolved to a report. Never throws, never returns null.
  ///
  /// The camera id is passed in rather than looked up here, because only the
  /// caller knows which camera is actually feeding the attempt: the exam page
  /// owns the `CameraController`.
  Future<HardwareIntegrityReport> check({String? cameraId}) async {
    try {
      final reply = await _channel
          .invokeMapMethod<Object?, Object?>(
            'getIntegrityReport',
            <String, Object?>{'cameraId': cameraId},
          )
          .timeout(timeout);
      if (reply == null) return const HardwareIntegrityReport.unsupported();
      return HardwareIntegrityReport.fromPlatform(reply);
    } on MissingPluginException {
      // A platform without the handler (iOS, desktop, a unit test): not an
      // error, just an answer this build cannot give.
      return const HardwareIntegrityReport.unsupported();
    } on PlatformException catch (error) {
      debugPrint('ProctorGuard integrity: the platform refused: ${error.message}');
      return const HardwareIntegrityReport.unsupported();
    } on TimeoutException {
      debugPrint(
        'ProctorGuard integrity: no answer within ${timeout.inSeconds}s — '
        'reporting nothing rather than holding the exam',
      );
      return const HardwareIntegrityReport.unsupported();
    } catch (error) {
      debugPrint('ProctorGuard integrity: probe failed: $error');
      return const HardwareIntegrityReport.unsupported();
    }
  }
  /// Starts watching: one probe immediately, then one every [interval].
  ///
  /// [onFinding] fires the first time a finding appears — not on every probe
  /// while it persists, because a display left attached for an hour is one piece
  /// of evidence and the strike counter already weighs one event. A finding that
  /// goes away and comes back is a new event, so a student who reconnects the
  /// same screen twice is reported twice.
  ///
  /// [cameraId] is read on every probe rather than captured once: the exam page
  /// can only name the camera it is using after its controller is initialised,
  /// and a session that re-opens its camera must not be judged by the old one.
  ///
  /// Idempotent, and safe after [stopMonitoring].
  void startMonitoring({
    required void Function(HardwareFinding finding) onFinding,
    String? Function()? cameraId,
    Duration interval = defaultInterval,
  }) {
    if (_timer != null) return;
    _stopped = false;
    _reportedSecondaryDisplay = false;
    _reportedVirtualCamera = false;

    void probe() => unawaited(_poll(onFinding: onFinding, cameraId: cameraId));
    probe();
    _timer = Timer.periodic(interval, (_) => probe());
  }

  /// Stops watching. Idempotent, and safe to follow with another
  /// [startMonitoring].
  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
    _stopped = true;
    _reportedSecondaryDisplay = false;
    _reportedVirtualCamera = false;
  }

  /// Alias for [stopMonitoring], so the exam page can release this the way it
  /// releases its other services.
  void dispose() => stopMonitoring();

  Future<void> _poll({
    required void Function(HardwareFinding finding) onFinding,
    String? Function()? cameraId,
  }) async {
    // One probe at a time: a slow platform reply must not stack probes, and two
    // in flight would only duplicate the same work.
    if (_checking || _stopped) return;
    _checking = true;

    try {
      final report = await check(cameraId: cameraId?.call());
      if (_stopped || !report.supported) return;

      for (final finding in HardwareFinding.values) {
        final present = switch (finding) {
          HardwareFinding.secondaryDisplay => report.secondaryDisplay,
          HardwareFinding.virtualCamera => report.virtualCamera,
        };
        if (present) {
          if (_markReported(finding, true)) onFinding(finding);
        } else {
          // Gone: re-arm, so the same finding appearing again is reported again.
          _markReported(finding, false);
        }
      }
    } finally {
      _checking = false;
    }
  }

  /// Records that [finding] is (or is not) currently reported, and returns
  /// whether this probe is the one that reported it.
  bool _markReported(HardwareFinding finding, bool reported) {
    switch (finding) {
      case HardwareFinding.secondaryDisplay:
        final first = reported && !_reportedSecondaryDisplay;
        _reportedSecondaryDisplay = reported;
        return first;
      case HardwareFinding.virtualCamera:
        final first = reported && !_reportedVirtualCamera;
        _reportedVirtualCamera = reported;
        return first;
    }
  }
}


