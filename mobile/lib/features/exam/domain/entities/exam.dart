import 'package:equatable/equatable.dart';

/// One paper as a student (or the supervisor picker) sees it.
///
/// [startsAt] / [endsAt] mirror `exams.starts_at` / `exams.ends_at`, the
/// *optional* scheduling window:
///
///  * both null — an unscheduled paper: offered the moment it is published,
///    which is the default and how every paper behaved before scheduling
///    existed;
///  * [startsAt] — not offered before that instant;
///  * [endsAt] — closed at that instant: no new attempt may be created, and an
///    attempt already in progress is capped by it (`attempt_deadline()` in
///    `schema.sql`), so the close is a real close.
///
/// The window is **enforced by the database** — `submissions_insert_own_ongoing`
/// asks it before any attempt row exists. Everything computed here is
/// presentation: which tile is locked, and why. That is also why [isOpenAt]
/// takes the instant to judge against instead of reading the clock itself: one
/// screen renders one frame from one `now`, and a test can hold that instant
/// still instead of racing it.
class Exam extends Equatable {
  const Exam({
    required this.id,
    required this.title,
    required this.createdBy,
    required this.durationMinutes,
    required this.isPublished,
    this.startsAt,
    this.endsAt,
  });

  factory Exam.fromMap(Map<String, dynamic> map) => Exam(
        id: map['id'] as String,
        title: map['title'] as String,
        createdBy: map['created_by'] as String,
        durationMinutes: map['duration_minutes'] as int,
        isPublished: map['is_published'] as bool,
        startsAt: _timestamp(map['starts_at']),
        endsAt: _timestamp(map['ends_at']),
      );

  final String id;
  final String title;
  final String createdBy;
  final int durationMinutes;
  final bool isPublished;

  /// When the paper is first offered, or null when it has no opening bound.
  final DateTime? startsAt;

  /// When the paper closes, or null when it has no closing bound.
  final DateTime? endsAt;

  /// `timestamptz` arrives as an ISO-8601 string; it is read in the device's own
  /// zone so every label is local time.
  ///
  /// Anything else — a number, a missing key (a database from before the
  /// columns existed), an unparseable string — reads as *no bound* rather than
  /// throwing out of a list, because "no bound" is the reading that cannot lock
  /// a student out of a paper they were told to sit.
  static DateTime? _timestamp(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toLocal() : null;

  /// True when the paper names either bound — i.e. it is not a "take it any
  /// time" paper.
  bool get isScheduled => startsAt != null || endsAt != null;

  /// Whether the paper has opened by [now]. A missing opening bound is open.
  bool opensAt(DateTime now) => startsAt == null || !now.isBefore(startsAt!);

  /// Whether the paper has closed by [now]. The closing bound is inclusive: at
  /// exactly `endsAt` the paper is spent, matching the policy's `now() <=
  /// e.ends_at`. A missing bound never closes.
  bool closesAt(DateTime now) => endsAt != null && !now.isBefore(endsAt!);

  /// Whether a student may start the paper at [now] — the client's reading of
  /// the same question `submissions_insert_own_ongoing` answers on the server.
  bool isOpenAt(DateTime now) => opensAt(now) && !closesAt(now);

  /// The one-line window, for a tile: "Anytime", "Opens 5 Jan 2026, 09:00",
  /// "Closes 5 Jan 2026, 17:00", or the full span. A window whose two ends fall
  /// on one day prints the date once and the two times, which is the common case
  /// (a morning and an afternoon sitting) and reads better.
  String get scheduleLabel {
    final start = startsAt;
    final end = endsAt;

    if (start == null && end == null) return 'Anytime';
    if (start != null && end == null) return 'Opens ${formatStamp(start)}';
    if (start == null) return 'Closes ${formatStamp(end!)}';

    return _sameDay(start, end!)
        ? '${formatStamp(start)} – ${_clock(end)}'
        : '${formatStamp(start)} – ${formatStamp(end)}';
  }

  /// Why the paper cannot be started at [now], or null when it can.
  ///
  /// One sentence, used by both the locked tile and the portal's message, so a
  /// student never gets two different explanations of one refusal.
  String? closedReason(DateTime now) {
    if (!opensAt(now)) return 'It opens ${formatStamp(startsAt!)}.';
    if (closesAt(now)) return 'It closed ${formatStamp(endsAt!)}.';
    return null;
  }

  /// "5 Jan 2026, 09:00" in the local zone. Hand-rolled rather than `intl`: one
  /// format is needed in two places (this label and the console's picker), and a
  /// locale-dependent month name would make the label untestable.
  ///
  /// Public because the console has to render a bound the author has just picked
  /// *before* any exam row exists to hang it on, and two formatters is how the
  /// same instant ends up shown two ways.
  static String formatStamp(DateTime value) =>
      '${value.day} ${_months[value.month - 1]} ${value.year}, '
      '${_clock(value)}';

  static String _clock(DateTime value) {
    String two(int part) => part.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}';
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  List<Object?> get props =>
      [id, title, createdBy, durationMinutes, isPublished, startsAt, endsAt];
}
