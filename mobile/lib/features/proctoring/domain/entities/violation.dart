import 'package:equatable/equatable.dart';

enum ViolationType {
  lookingAway,
  multipleFaces,
  noFace,
  appMinimized,
  audioNoise,

  /// Copy, cut or paste was caught and blocked during the attempt (browser
  /// build): moving question text out of the exam, or an answer in.
  copyPasteAttempt,

  /// The context menu was suppressed - the right-click route to "view source",
  /// "inspect" and the browser's own paste.
  rightClickBlocked,

  /// A docked developer-tools panel is open while the exam runs.
  devtoolsDetected,

  /// Android: a second display (HDMI/DP, casting, screen mirroring) is attached.
  secondaryDisplayDetected,

  /// Android: the camera in use is not a physical lens (external/USB device, or
  /// an emulator's virtual camera).
  virtualCameraDetected,

  /// No keyboard or pointer activity for the AFK window: the student may have
  /// left the device, or somebody else may have sat down at it.
  idleAfk;

  /// Maps to the Postgres check constraint on `proctoring_logs.action_type`.
  String get dbValue => switch (this) {
        ViolationType.lookingAway => 'looking_away',
        ViolationType.multipleFaces => 'multiple_faces',
        ViolationType.noFace => 'no_face',
        ViolationType.appMinimized => 'app_minimized',
        ViolationType.audioNoise => 'audio_noise',
        ViolationType.copyPasteAttempt => 'copy_paste_attempt',
        ViolationType.rightClickBlocked => 'right_click_blocked',
        ViolationType.devtoolsDetected => 'devtools_detected',
        ViolationType.secondaryDisplayDetected => 'secondary_display_detected',
        ViolationType.virtualCameraDetected => 'virtual_camera_detected',
        ViolationType.idleAfk => 'idle_afk',
      };

  /// The inverse of [dbValue], for rows rebuilt from the offline queue.
  ///
  /// Throws on an unknown value rather than defaulting: a queued violation whose
  /// type cannot be mapped is evidence of a *drift* between this enum and the
  /// schema's check constraint, and it should not be logged as some other
  /// violation. `OfflineSyncService` drops such a row (see `_readQueue`).
  static ViolationType fromDb(String value) => switch (value) {
        'looking_away' => ViolationType.lookingAway,
        'multiple_faces' => ViolationType.multipleFaces,
        'no_face' => ViolationType.noFace,
        'app_minimized' => ViolationType.appMinimized,
        'audio_noise' => ViolationType.audioNoise,
        'copy_paste_attempt' => ViolationType.copyPasteAttempt,
        'right_click_blocked' => ViolationType.rightClickBlocked,
        'devtools_detected' => ViolationType.devtoolsDetected,
        'secondary_display_detected' =>
          ViolationType.secondaryDisplayDetected,
        'virtual_camera_detected' => ViolationType.virtualCameraDetected,
        'idle_afk' => ViolationType.idleAfk,
        _ => throw ArgumentError('Unknown action_type: $value'),
      };
}

class Violation extends Equatable {
  final ViolationType type;
  final DateTime timestamp;
  final String? snapshotUrl;

  /// Client-minted UUID for this one event, sent as
  /// `register_violation(p_client_event_id => ...)`.
  ///
  /// It is what makes the offline retry safe: a violation whose call failed
  /// (timeout, dropped connection) is queued with this id, and the retry inserts
  /// either the row or nothing at all - never a second strike for the same event
  /// (see the unique index on `proctoring_logs.client_event_id`). Null only for
  /// callers that predate the queue.
  final String? clientEventId;

  const Violation({
    required this.type,
    required this.timestamp,
    this.snapshotUrl,
    this.clientEventId,
  });

  /// Round-trip for the durable queue; [fromJson] tolerates a missing
  /// `snapshotUrl`/`clientEventId` (older queued rows, or an aborted upload).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.dbValue,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (snapshotUrl != null) 'snapshot_url': snapshotUrl,
        if (clientEventId != null) 'client_event_id': clientEventId,
      };

  /// Rebuilds a queued violation. Throws [FormatException] when the row is not a
  /// violation at all, so the queue can drop it instead of mis-logging it.
  factory Violation.fromJson(Map<String, dynamic> json) {
    final type = json['type'];
    final timestamp = json['timestamp'];
    if (type is! String || timestamp is! String) {
      throw const FormatException('not a violation row');
    }
    return Violation(
      type: ViolationType.fromDb(type),
      timestamp: DateTime.parse(timestamp).toLocal(),
      snapshotUrl: json['snapshot_url'] as String?,
      clientEventId: json['client_event_id'] as String?,
    );
  }

  @override
  List<Object?> get props => [type, timestamp, snapshotUrl, clientEventId];
}

