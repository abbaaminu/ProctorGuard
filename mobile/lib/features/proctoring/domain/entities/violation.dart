import 'package:equatable/equatable.dart';

enum ViolationType {
  lookingAway,
  multipleFaces,
  noFace,
  appMinimized,
  audioNoise;

  /// Maps to the Postgres check constraint on `proctoring_logs.action_type`.
  String get dbValue => switch (this) {
        ViolationType.lookingAway => 'looking_away',
        ViolationType.multipleFaces => 'multiple_faces',
        ViolationType.noFace => 'no_face',
        ViolationType.appMinimized => 'app_minimized',
        ViolationType.audioNoise => 'audio_noise',
      };
}

class Violation extends Equatable {
  final ViolationType type;
  final DateTime timestamp;
  final String? snapshotUrl;

  const Violation({
    required this.type,
    required this.timestamp,
    this.snapshotUrl,
  });

  @override
  List<Object?> get props => [type, timestamp, snapshotUrl];
}
