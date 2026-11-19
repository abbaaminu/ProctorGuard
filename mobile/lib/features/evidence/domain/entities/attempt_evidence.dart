import 'package:equatable/equatable.dart';

/// Which console the Evidence screen was opened from.
///
/// The two audiences read the same rows through the same RPC; the difference is
/// only where the *paper list* comes from (`evidenceExamOptionsProvider`) and
/// whether the page offers the administrator's student search. Nothing about the
/// scope is decided here - `public.exam_evidence()` decides it, server-side.
enum EvidenceAudience { lecturer, admin }

/// One paper the signed-in account may read evidence for.
class EvidenceExamOption extends Equatable {
  const EvidenceExamOption({required this.id, required this.title});

  final String id;
  final String title;

  @override
  List<Object?> get props => <Object?>[id, title];
}

/// One incident: a `proctoring_logs` row as `public.exam_evidence()` answers it.
///
/// [snapshotUrl] is the **stored** value - this build's bucket-relative object
/// path, or a public URL on a row written before the bucket went private - and
/// never a signed URL. Signing happens in the tile that shows it, per tile, with
/// a 10-minute lifetime; a URL kept here would be dead by the time somebody
/// scrolled back to it.
class EvidenceItem extends Equatable {
  const EvidenceItem({
    required this.logId,
    required this.actionType,
    required this.weight,
    required this.countsTowardDq,
    required this.loggedAt,
    this.snapshotUrl,
  });

  factory EvidenceItem.fromMap(Map<String, dynamic> map) => EvidenceItem(
    logId: map['log_id'] as String,
    actionType: (map['action_type'] as String? ?? '').trim(),
    // The RPC already applies register_violation()'s default of (1, true) to
    // an action type with no weights row; repeating it here is what keeps a
    // row readable if an older function answers without the columns.
    weight: (map['weight'] as num?)?.toInt() ?? 1,
    countsTowardDq: map['counts_toward_dq'] as bool? ?? true,
    loggedAt: _timestamp(map['logged_at']),
    snapshotUrl: _text(map['snapshot_url']),
  );

  final String logId;
  final String actionType;

  /// What this action counts towards automatic disqualification, as
  /// `violation_weights` holds it now.
  final int weight;
  final bool countsTowardDq;

  final DateTime? loggedAt;

  /// The stored still reference, or null when the incident was logged without a
  /// picture (offline, camera busy, upload refused).
  final String? snapshotUrl;

  bool get hasStill => snapshotUrl != null;

  /// The action type as a person reads it. Unknown types print as themselves
  /// rather than disappearing: a signal added to the database after this build
  /// shipped must still be visible to the reviewer.
  String get actionLabel => switch (actionType) {
    'looking_away' => 'Looked away',
    'multiple_faces' => 'More than one face',
    'no_face' => 'No face detected',
    'app_minimized' => 'App minimised',
    'audio_noise' => 'Loud noise',
    'copy_paste_attempt' => 'Copy/paste attempt',
    'right_click_blocked' => 'Right click blocked',
    'devtools_detected' => 'Developer tools',
    'secondary_display_detected' => 'Second display',
    'virtual_camera_detected' => 'Virtual camera',
    'idle_afk' => 'Idle',
    _ => actionType.isEmpty ? 'Incident' : actionType,
  };

  /// "1 point" / "Not counted" - the weight in one phrase, so a reviewer does not
  /// have to know the table to read the tile.
  String get weightLabel => countsTowardDq
      ? '$weight ${weight == 1 ? 'point' : 'points'}'
      : 'Not counted';

  @override
  List<Object?> get props => <Object?>[
    logId,
    actionType,
    weight,
    countsTowardDq,
    loggedAt,
    snapshotUrl,
  ];
}

/// One sitting and every incident logged against it, in the order the RPC
/// returned them: newest sitting first, incidents oldest first.
class AttemptEvidence extends Equatable {
  const AttemptEvidence({
    required this.submissionId,
    required this.studentId,
    required this.studentName,
    required this.status,
    required this.startedAt,
    required this.items,
  });

  /// Groups the RPC's flat rows by attempt, keeping the order they arrive in.
  ///
  /// The rows are already sorted by the function (`started_at desc, timestamp`),
  /// so a map built in encounter order preserves it. Every row of one attempt
  /// carries the same attempt columns - they come from the same
  /// `exam_submissions` row - so the first row's copy is the attempt's.
  static List<AttemptEvidence> group(List<Map<String, dynamic>> rows) {
    final bySubmission = <String, List<EvidenceItem>>{};
    final meta = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final id = row['submission_id'] as String?;
      if (id == null) continue;
      meta.putIfAbsent(id, () => row);
      bySubmission
          .putIfAbsent(id, () => <EvidenceItem>[])
          .add(EvidenceItem.fromMap(row));
    }

    return <AttemptEvidence>[
      for (final entry in bySubmission.entries)
        AttemptEvidence(
          submissionId: entry.key,
          studentId: meta[entry.key]!['student_id'] as String? ?? '',
          studentName: _text(meta[entry.key]!['student_name']),
          status: (meta[entry.key]!['attempt_status'] as String? ?? '').trim(),
          startedAt: _timestamp(meta[entry.key]!['attempt_started_at']),
          items: entry.value,
        ),
    ];
  }

  final String submissionId;
  final String studentId;

  /// `profiles.full_name` as the caller is allowed to read it: null when the
  /// roster policy withholds the profile.
  final String? studentName;

  /// `exam_submissions.status`: `ongoing`, `flagged_for_review`, `submitted` or
  /// `disqualified`.
  final String status;
  final DateTime? startedAt;
  final List<EvidenceItem> items;

  /// Never blank: a missing name falls back to the same short id the marking
  /// queue and the live monitor use, so one attempt is recognisable across all
  /// three screens.
  String get displayName => studentName ?? evidenceStudentLabel(studentId);

  String get statusLabel => switch (status) {
    'ongoing' => 'In progress',
    'flagged_for_review' => 'Flagged for review',
    'submitted' => 'Submitted',
    'disqualified' => 'Disqualified',
    _ => status.isEmpty ? 'Unknown' : status,
  };

  /// Whether the attempt is one a reviewer has to act on, which is what makes its
  /// card stand out from a clean sitting's.
  bool get needsReview =>
      status == 'flagged_for_review' || status == 'disqualified';

  bool get hasStills => items.any((item) => item.hasStill);

  /// The points this sitting's incidents carry *today*: the same sum a reviewer
  /// would make by hand from the tiles, not the strike count the server kept when
  /// the attempt closed.
  int get points => items
      .where((item) => item.countsTowardDq)
      .fold<int>(0, (total, item) => total + item.weight);

  @override
  List<Object?> get props => <Object?>[
    submissionId,
    studentId,
    studentName,
    status,
    startedAt,
    items,
  ];
}

/// The label for a student whose profile row could not be read.
///
/// The same `Student <first uuid segment>` convention as
/// `QuestionAuthoringRepositoryImpl` and the live monitor, so a reviewer reading
/// a marking queue and this screen sees one name for one attempt.
String evidenceStudentLabel(String studentId) {
  final text = studentId.trim();
  if (text.isEmpty) return 'Unknown student';
  return 'Student ${text.split('-').first}';
}

String? _text(Object? value) {
  final text = value is String ? value.trim() : '';
  return text.isEmpty ? null : text;
}

DateTime? _timestamp(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toLocal() : null;
