import 'package:equatable/equatable.dart';

/// One paragraph of the consent notice: a heading and the sentence(s) under it.
///
/// Data only, with no icon and no colour: the wording is the contract and the
/// page is free to draw it however a phone or a desktop needs it.
class ConsentClause extends Equatable {
  const ConsentClause({
    required this.id,
    required this.heading,
    required this.body,
  });

  /// Stable identifier for tests and for the widget key
  /// (`consent-clause-<id>`); never rendered.
  final String id;

  final String heading;
  final String body;

  @override
  List<Object?> get props => [id, heading, body];
}

/// Everything about the proctoring consent notice, in one place.
///
/// THE SINGLE SOURCE OF THE VERSION AND THE RETENTION PERIODS
///   [version] is the string `record_consent()` stores and the database compares
///   against `public.proctoring_consent_config.current_version`. Bumping the
///   wording means bumping [version] here **and** updating that row - in the same
///   release - and `mobile/test/schema_contract_test.dart` fails if this file and
///   the migration disagree about the shipped value. A build that ships older
///   wording still records what it showed (the RPC answers `is_current: false`)
///   but cannot satisfy `submissions_insert_own_ongoing`, so the screen tells the
///   student to update instead of letting them accept text that no longer counts.
///
///   [snapshotRetentionDays] and [attemptRetentionDays] are the numbers the
///   notice quotes, and they are the numbers the server enforces:
///   `retention_policies('proctor_snapshots')` and
///   `retention_policies('exam_submissions')` in
///   `supabase/migrations/20261106090100_snapshot_retention.sql`. The same test
///   pins them together, because "we delete your photographs after N days" is a
///   promise the database has to keep, not a sentence the app is allowed to
///   drift away from.
///
/// TODO(institution): the wording below is plain-language placeholder text
/// written for a demonstration, not legal advice. Your institution's own notices
/// office must supply the final sentences - the lawful basis, the data
/// controller's identity and address, the complaints route - before this screen
/// is used in a real sitting. Search for `TODO(institution)` in this file: every
/// place that needs their text is marked. Bump [version] when they are in.
class ProctorConsentConfig {
  const ProctorConsentConfig._();

  /// The notice version. Must equal
  /// `public.proctoring_consent_config.current_version` on the server.
  ///
  /// Format is free (the column only checks 1-64 characters); a date plus a
  /// revision is used here because a human reading a consent row can tell at a
  /// glance which wording it was.
  static const String version = '2026-11-v1';

  /// How long a still from the camera is kept, in days. Deleted by the
  /// `purge-snapshots` Edge Function (or `purge_expired_snapshots()`), which
  /// reads the same number from `retention_policies`.
  static const int snapshotRetentionDays = 30;

  /// How long the attempt record - answers, mark, incidents, and the fact that
  /// consent was given - is kept, in days. Align this with the institution's
  /// appeals period; the attempt itself is not deleted by any scheduled job.
  static const int attemptRetentionDays = 180;

  /// Who a student contacts about this notice, its data, or a decision made with
  /// it.
  ///
  /// TODO(institution): replace both of these with the real office, address and
  /// telephone number. They are deliberately obviously-placeholder strings
  /// rather than a plausible-looking address that would quietly ship.
  static const String contactName = 'TODO(institution): the exams office';

  /// TODO(institution): the real contact address.
  static const String contactEmail = 'TODO(institution): exams@example.edu';

  /// The heading the screen shows above the clauses.
  static const String title = 'Before you sit this proctored exam';

  /// The sentence under the heading - what accepting actually does.
  static const String preamble =
      'This exam is proctored. Please read what that means before you accept. '
      'You can leave without accepting and nothing will be recorded.';

  /// The label on the checkbox the student has to tick.
  static const String acceptanceLabel =
      'I have read this notice and I accept it for this exam.';

  /// Shown when the server says the installed build carries older wording.
  static const String staleVersionMessage =
      'This version of ProctorGuard shows an older version of the notice, so '
      'your acceptance would not count. Update the app, then start the exam '
      'again.';

  /// "30 days", "180 days" - never "30 day(s)" in front of a student.
  static String daysLabel(int days) => days == 1 ? '1 day' : '$days days';

  /// The notice, clause by clause, in the order a student reads it: what is
  /// captured, what happens to the pictures, who sees them, how long it is kept,
  /// and who to ask about it.
  ///
  /// Every clause is written in the second person and names the concrete thing
  /// the app does - "a still photograph", "the loudness of the room, not the
  /// sound" - because a notice a student cannot map onto what they are about to
  /// see is a notice they cannot meaningfully accept.
  ///
  /// The two retention numbers are *interpolated from the constants above*, so
  /// the sentence a student reads and the window the purge enforces cannot
  /// disagree without somebody deleting the interpolation on purpose.
  static const List<ConsentClause> clauses = <ConsentClause>[
    ConsentClause(
      id: 'capture',
      heading: 'What this exam records',
      body: 'While the exam is running, ProctorGuard keeps your camera and '
          'microphone switched on. On the device it watches for a face in '
          'frame, a second person, a second screen and a change of window; '
          'from the microphone it measures the loudness of the room, not the '
          'sound. Everything it notices is recorded as an incident with the '
          'time it happened. It also sends a "still here" signal every 15 '
          'seconds, so your supervisor can tell an exam that was watched from '
          'one where the app had stopped.',
    ),
    ConsentClause(
      id: 'stills',
      heading: 'Photographs are kept when something is flagged',
      body: 'When the app records an incident it also saves a single still '
          'photograph from your camera at that moment, and only then. There is '
          'no recording of video or audio, ever. The still is stored privately '
          'and can only be opened through a signed link that expires, minted '
          'for somebody who is allowed to look.',
    ),
    ConsentClause(
      id: 'who',
      heading: 'Who can see it',
      body: 'Your own attempt, its incidents and its stills can be seen by '
          'you, by the lecturer who wrote the paper, and by the exam '
          'supervisor for that sitting. An administrator can see them when '
          'you ask about a decision. Nobody else in the institution can, and '
          'nothing is shown to other students.',
    ),
    ConsentClause(
      id: 'retention',
      heading: 'How long it is kept, and what happens then',
      body: 'A still photograph is deleted after $snapshotRetentionDays days, '
          'or sooner if your supervisor resets the attempt. The record of the '
          'attempt itself - your answers, your mark and the list of incidents '
          '- is kept for $attemptRetentionDays days, which is the period in '
          'which you can appeal a result, and then deleted. The incidents stay '
          'readable after their photographs have gone: what disappears is the '
          'picture, not the fact that something was flagged.',
    ),
    ConsentClause(
      id: 'decisions',
      heading: 'What it is used for, and what it is not',
      body: 'The record is used to decide whether a sitting was fair, and for '
          'nothing else. It is not used to grade you, it is not shared with '
          'anybody outside your institution, and no automatic decision is '
          'made from it: a person reviews what the app flagged, and you are '
          'told the outcome. If your connection drops, your answers are kept '
          'and sent when it returns - a gap is a question for a human, not a '
          'presumption against you.',
    ),
    ConsentClause(
      id: 'contact',
      heading: 'If you want to ask about it',
      body: 'You can ask to see what was recorded about you, ask for a '
          'correction, or object to how it was used, by contacting '
          '$contactName ($contactEmail). If you do not accept this notice you '
          'cannot sit a proctored exam, and your institution will tell you '
          'what the alternative is.',
    ),
  ];
}

/// What `public.record_consent()` stored, as the client sees it.
///
/// [isCurrentVersion] is the server's answer to "is the wording this build
/// displayed the one in force?" - the one thing a client cannot work out for
/// itself, and the reason the RPC replies with a row rather than a boolean.
class ConsentRecord extends Equatable {
  const ConsentRecord({
    required this.id,
    required this.version,
    this.acceptedAt,
    this.isCurrentVersion = true,
  });

  /// `proctoring_consents.id`.
  final String id;

  /// The version the server stored - the one this build sent, verbatim.
  final String version;

  /// Server time of the acceptance, or null when the reply could not be read.
  final DateTime? acceptedAt;

  /// False when the server's current version is not the one accepted. The
  /// student is told to update rather than being sent to an insert the policy
  /// will refuse.
  final bool isCurrentVersion;

  /// Maps the RPC's `(consent_id, consent_version, accepted_at, is_current)`
  /// row. Tolerant on purpose: a missing field must not throw inside the one
  /// screen a student cannot get past, so an unreadable reply is treated as
  /// "recorded, current".
  factory ConsentRecord.fromRpc(Object? response) {
    final row = switch (response) {
      List<dynamic> list when list.isNotEmpty => list.first,
      Map<String, dynamic> map => map,
      _ => const <String, dynamic>{},
    };
    final map =
        row is Map ? Map<String, dynamic>.from(row) : const <String, dynamic>{};
    final acceptedAt = map['accepted_at'];
    return ConsentRecord(
      id: (map['consent_id'] as String?) ?? '',
      version: (map['consent_version'] as String?) ?? '',
      acceptedAt: acceptedAt is String
          ? DateTime.tryParse(acceptedAt)?.toLocal()
          : null,
      // Only an explicit `false` blocks the student: an older server that
      // answered without the field is not evidence that the wording is stale.
      isCurrentVersion: map['is_current'] != false,
    );
  }

  @override
  List<Object?> get props => [id, version, acceptedAt, isCurrentVersion];
}

