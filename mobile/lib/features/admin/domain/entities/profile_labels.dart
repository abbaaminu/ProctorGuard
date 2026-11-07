import 'package:equatable/equatable.dart';

import '../../../auth/domain/entities/user_profile.dart';
import 'managed_account.dart';
import 'student_roster.dart';

/// One writable column of a label correction, with the name it travels under.
///
/// An enum rather than a bare string so a caller cannot misspell
/// `matric_number` — the Edge Function reads the column's own name, and
/// `matricNumber` is only a courtesy spelling it happens to understand — and so
/// "the three columns `exams_select` compares" can be asked for by name
/// ([ProfileLabel.academic]) instead of being re-listed in every widget.
enum ProfileLabel {
  faculty('faculty'),
  department('department'),
  level('level'),
  matricNumber('matric_number'),
  staffId('staff_id');

  const ProfileLabel(this.column);

  /// The `profiles` column, which is also the key the Edge Function reads.
  final String column;

  /// The academic labels, in the order the console offers them: the three
  /// columns `exams_select` compares a published paper against. A blank one is
  /// not cosmetic — it is the reason a student never sees the paper aimed at
  /// their cohort.
  static const List<ProfileLabel> academic = <ProfileLabel>[
    faculty,
    department,
    level,
  ];

  /// The identity number that belongs on an account with [role]: a student is
  /// examined under a matriculation number, everybody else is named by a staff
  /// ID. One rule, so the create form and the Edit dialog cannot disagree.
  static ProfileLabel identityFor(UserRole role) =>
      role == UserRole.student ? matricNumber : staffId;
}

/// A correction to one account: the columns to write, and nothing about the ones
/// to leave alone.
///
/// The absent-versus-blank distinction is the whole point of this type. A key
/// that is missing from [labels] leaves its column untouched, while a key whose
/// value is null or blank *clears* it. Both are needed: a corrections file names
/// the two columns it knows about, whereas the Edit dialog shows all five and a
/// save means what it showed — including "we do not know this student's level",
/// which has to be expressible, or a wrong value could only be swapped for
/// another wrong one.
class StudentLabelCorrection extends Equatable {
  const StudentLabelCorrection({
    required this.userId,
    this.email,
    required this.labels,
  });

  /// `profiles.id` — what the function selects the row by. Never the address:
  /// two students in a badly kept roster can share one, and an address match
  /// would then be a coin toss over whose level is being corrected.
  final String userId;

  /// Where the row came from, echoed back in the answer's `failed` list so the
  /// administrator can see which line of the file was refused. It is *not* used
  /// to find the row.
  final String? email;

  /// The columns to write, keyed by [ProfileLabel] so the column's own name
  /// travels instead of a spelling invented at the call site.
  final Map<ProfileLabel, String?> labels;

  bool get isEmpty => labels.isEmpty;

  /// The row as `admin-update-profile` reads it: `id` (not `userId`), the
  /// column's own spelling for each label, and `email` only when there is one to
  /// echo.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': userId,
        if (trimmedOrNull(email) != null) 'email': trimmedOrNull(email),
        for (final entry in labels.entries)
          entry.key.column: trimmedOrNull(entry.value),
      };

  @override
  List<Object?> get props => [userId, email, labels];
}

/// What one page of corrections came back as.
///
/// Shaped like [StudentRosterOutcome] on purpose — rows the server wrote, rows it
/// refused with a reason — because an administrator reads both the same way. A
/// page answers 200 even when some rows failed: the request was understood, and
/// each refusal travels beside the rows that were written.
class LabelFixOutcome extends Equatable {
  const LabelFixOutcome({
    this.updated = const <ManagedAccount>[],
    this.failed = const <RefusedStudentRow>[],
  });

  /// Reads the function's `{ updated: [...], failed: [...] }`. Anything that is
  /// not a list reads as empty rather than throwing: a deployment from before the
  /// bulk branch answers a single row, which the caller checks for with [isEmpty]
  /// instead of crashing on a cast.
  factory LabelFixOutcome.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>> rows(Object? value) => value is List
        ? value
            .whereType<Map<Object?, Object?>>()
            .map((row) => row.cast<String, dynamic>())
            .toList(growable: false)
        : const <Map<String, dynamic>>[];

    return LabelFixOutcome(
      updated: rows(map['updated'])
          .map(ManagedAccount.fromMap)
          .toList(growable: false),
      failed: rows(map['failed'])
          .map(RefusedStudentRow.fromMap)
          .toList(growable: false),
    );
  }

  /// The corrected rows, as `admin-update-profile` read them back — the columns
  /// it cleared are present and null, so a tile redraws without the label the
  /// administrator just removed.
  final List<ManagedAccount> updated;

  /// The rows the server refused, with the sentence it refused with. The `email`
  /// of a refusal is whichever label the row carried — the address, else the id,
  /// else "(blank)" — so the line can still be found in the file.
  final List<RefusedStudentRow> failed;

  int get updatedCount => updated.length;
  int get failedCount => failed.length;
  bool get isEmpty => updated.isEmpty && failed.isEmpty;
  bool get allUpdated => failed.isEmpty;

  /// Adds another page's answer to this one, so a correction that spans several
  /// requests reports one total.
  LabelFixOutcome operator +(LabelFixOutcome other) => LabelFixOutcome(
        updated: <ManagedAccount>[...updated, ...other.updated],
        failed: <RefusedStudentRow>[...failed, ...other.failed],
      );

  @override
  List<Object?> get props => [updated, failed];
}

/// A corrections file resolved against the roster the page is showing.
///
/// Resolution belongs here rather than in the widget: the server needs a uuid per
/// row, a file can only name people by address, and turning one into the other is
/// the step that decides whether a line is a correction or a problem. Keeping it
/// out of the widget is what lets it be tested without a screen.
class LabelFixPlan extends Equatable {
  const LabelFixPlan({
    this.corrections = const <StudentLabelCorrection>[],
    this.problems = const <StudentRosterProblem>[],
    this.headerError,
  });

  final List<StudentLabelCorrection> corrections;

  /// The lines that will not be sent, each with the reason and the 1-based line
  /// number a spreadsheet shows.
  final List<StudentRosterProblem> problems;

  /// The reason no row could be read at all (a missing `email` column, say).
  final String? headerError;

  bool get isEmpty =>
      corrections.isEmpty && problems.isEmpty && headerError == null;

  bool get hasNothingToSend => headerError != null || corrections.isEmpty;

  @override
  List<Object?> get props => [corrections, problems, headerError];
}

/// The label questions the console asks of a roster row.
extension ManagedAccountLabels on ManagedAccount {
  /// True when every column `exams_select` compares is recorded.
  ///
  /// A student without this cannot see a paper targeted at their cohort: the
  /// policy compares the labels, and a blank matches only a paper that is not
  /// narrowed either. That is why the dashboard counts these rows separately.
  bool get isFullyLabelled =>
      faculty != null && department != null && level != null;

  /// The academic columns this row leaves blank, in catalogue order — what the
  /// Edit dialog pre-highlights and what the "missing labels" filter explains.
  List<ProfileLabel> get missingLabels => <ProfileLabel>[
        if (faculty == null) ProfileLabel.faculty,
        if (department == null) ProfileLabel.department,
        if (level == null) ProfileLabel.level,
      ];

  /// Every writable column as it stands, so the Edit dialog opens on what the
  /// server has rather than on what the app remembered.
  Map<ProfileLabel, String?> get labelSnapshot => <ProfileLabel, String?>{
        ProfileLabel.faculty: faculty,
        ProfileLabel.department: department,
        ProfileLabel.level: level,
        ProfileLabel.matricNumber: matricNumber,
        ProfileLabel.staffId: staffId,
      };
}

/// [raw] trimmed, or null when it says nothing.
///
/// Null rather than `''` because that is what the wire means by "clear this
/// column", and because it keeps a blank cell out of the request body's values.
String? trimmedOrNull(String? raw) {
  final value = raw?.trim() ?? '';
  return value.isEmpty ? null : value;
}
