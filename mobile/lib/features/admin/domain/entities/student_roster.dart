import 'package:equatable/equatable.dart';

import 'managed_account.dart';

/// One student a roster import wants to create: the four things a class list can
/// be expected to hold, and the three academic labels that make the account
/// targetable by a paper.
///
/// This is the unit the CSV parser produces and the repository sends, so the
/// validation that matters for a whole class (an address, a name, a level the
/// columns can compare) happens once, in one type, rather than in the parser,
/// the widget and the repository separately.
class NewStudentAccount extends Equatable {
  const NewStudentAccount({
    required this.email,
    required this.fullName,
    this.faculty,
    this.department,
    this.level,
  });

  final String email;
  final String fullName;

  /// The `profiles` academic labels, or null for "not stated". All three are
  /// free text in the schema and are compared by `exams_select`, so they are
  /// carried exactly as the file spelled them (after trimming).
  final String? faculty;
  final String? department;
  final String? level;

  /// The row as `admin-create-user` reads it: `full_name` rather than
  /// `fullName` (the column's own spelling), and unset labels omitted rather
  /// than sent as null — NULL and "absent" mean the same thing there, and the
  /// shorter body says it once.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'email': email,
        'full_name': fullName,
        if (faculty != null) 'faculty': faculty,
        if (department != null) 'department': department,
        if (level != null) 'level': level,
      };

  @override
  List<Object?> get props => [email, fullName, faculty, department, level];
}

/// One account the import created, with the generated password that is the only
/// way its owner will ever sign in.
///
/// The password is carried beside the account rather than on it: [ManagedAccount]
/// is a `profiles` row, and a password is not a column.
class CreatedStudentAccount extends Equatable {
  const CreatedStudentAccount({
    required this.account,
    required this.temporaryPassword,
  });

  /// Reads one entry of the function's `created` list: the profile row plus
  /// `temporary_password`. A row whose password is missing is still reported —
  /// with an empty password — because the account exists either way, and hiding
  /// it would leave the administrator believing the import did nothing.
  factory CreatedStudentAccount.fromMap(Map<String, dynamic> map) =>
      CreatedStudentAccount(
        account: ManagedAccount.fromMap(map),
        temporaryPassword: (map['temporary_password'] as String? ?? '').trim(),
      );

  final ManagedAccount account;
  final String temporaryPassword;

  /// "ada@uni.test\tPg-…" — the line the copy-all control puts on the clipboard,
  /// so one paste hands a whole class its passwords.
  String get handoverLine => '${account.email}\t$temporaryPassword';

  @override
  List<Object?> get props => [account, temporaryPassword];
}

/// One row the server refused, and the sentence it refused with (the same prose
/// a single creation would have answered, so a duplicate e-mail reads the same
/// whether it came from the form or from a file).
class RefusedStudentRow extends Equatable {
  const RefusedStudentRow({required this.email, required this.error});

  factory RefusedStudentRow.fromMap(Map<String, dynamic> map) =>
      RefusedStudentRow(
        email: (map['email'] as String? ?? '').trim(),
        error: (map['error'] as String? ?? '').trim(),
      );

  final String email;
  final String error;

  @override
  List<Object?> get props => [email, error];
}

/// What one `{ students: [...] }` request did: the accounts it created and the
/// rows it refused. Both lists are part of one answer — a bulk call is not
/// all-or-nothing, which is what lets one duplicate address be corrected without
/// re-uploading the class.
class StudentRosterOutcome extends Equatable {
  const StudentRosterOutcome({
    this.created = const <CreatedStudentAccount>[],
    this.failed = const <RefusedStudentRow>[],
  });

  /// Reads the function's `{ created: [...], failed: [...] }`. Anything that is
  /// not a list reads as empty rather than throwing: a deployment from before
  /// the bulk branch answers a single row, which the caller checks for with
  /// [isEmpty] instead of crashing on a cast.
  factory StudentRosterOutcome.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>> rows(Object? value) => value is List
        ? value
            .whereType<Map<Object?, Object?>>()
            .map((row) => row.cast<String, dynamic>())
            .toList(growable: false)
        : const <Map<String, dynamic>>[];

    return StudentRosterOutcome(
      created: rows(map['created'])
          .map(CreatedStudentAccount.fromMap)
          .toList(growable: false),
      failed: rows(map['failed'])
          .map(RefusedStudentRow.fromMap)
          .toList(growable: false),
    );
  }

  final List<CreatedStudentAccount> created;
  final List<RefusedStudentRow> failed;

  int get createdCount => created.length;
  int get failedCount => failed.length;
  bool get isEmpty => created.isEmpty && failed.isEmpty;
  bool get allCreated => failed.isEmpty;

  /// Adds another page's answer to this one, so an import that spans several
  /// requests reports one total.
  StudentRosterOutcome operator +(StudentRosterOutcome other) =>
      StudentRosterOutcome(
        created: <CreatedStudentAccount>[...created, ...other.created],
        failed: <RefusedStudentRow>[...failed, ...other.failed],
      );

  /// Every password in one paste: one `email<TAB>password` line per created
  /// account. Tabs rather than commas so it pastes into a spreadsheet's columns
  /// instead of needing quoting.
  String get handoverSheet =>
      created.map((row) => row.handoverLine).join('\n');

  @override
  List<Object?> get props => [created, failed];
}

/// One line of the file the parser refused, and why.
///
/// Separate from [RefusedStudentRow] on purpose: this is a *file* problem found
/// before anything was sent (a cell that is not an address, an unreadable
/// level), and [RefusedStudentRow] is the *server's* answer about a row it was
/// sent. Merging them would lose which half needs correcting.
class StudentRosterProblem extends Equatable {
  const StudentRosterProblem({required this.line, required this.message});

  /// The 1-based line in the file, counting the header as line 1 — the number a
  /// spreadsheet shows.
  final int line;
  final String message;

  @override
  List<Object?> get props => [line, message];
}

/// A parsed roster: the rows worth sending, the lines that will not be sent, and
/// the reason the file could not be read at all (a missing `email` column, say).
///
/// [headerError] and [problems] are both refusals but of different scope: a
/// header error means *no* row can be attributed, so nothing is sent; a problem
/// is one line, so the rest of the class still goes.
class StudentRosterParse extends Equatable {
  const StudentRosterParse({
    this.rows = const <NewStudentAccount>[],
    this.problems = const <StudentRosterProblem>[],
    this.headerError,
  });

  final List<NewStudentAccount> rows;
  final List<StudentRosterProblem> problems;
  final String? headerError;

  bool get isEmpty => rows.isEmpty && problems.isEmpty && headerError == null;
  bool get hasNothingToSend => headerError != null || rows.isEmpty;

  @override
  List<Object?> get props => [rows, problems, headerError];
}
