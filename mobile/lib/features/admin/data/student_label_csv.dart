import 'package:csv/csv.dart';

import '../../../core/utils/academic_catalog.dart';
import '../domain/entities/managed_account.dart';
import '../domain/entities/profile_labels.dart';
import '../domain/entities/student_roster.dart';
import 'student_roster_csv.dart';

/// Reads the corrections file an administrator uploads into the columns
/// `admin-update-profile` writes.
///
/// The sibling of `StudentRosterCsv`, and the same boundary: a corrections file
/// can only name people by *address*, while the function needs a `profiles.id`
/// per row, so resolving one into the other happens here — once, in a type
/// ([LabelFixPlan]) a test can inspect — rather than in a widget that would have
/// to grow a screenful of string handling.
///
/// The two files differ in one important way. A roster row that says nothing is
/// useless, whereas a *blank cell* in a corrections file is a statement: it
/// clears that column (the function writes a key that is present and empty). So
/// the columns the header names are exactly the columns the file speaks about:
/// omit `level` to leave every student's level alone, include it and leave a cell
/// empty to remove a wrong one.
class StudentLabelCsv {
  const StudentLabelCsv._();

  /// "email,faculty,department,level,matric_number,staff_id" — the header the
  /// card shows as its template, and what a rejected header is compared against.
  static String get templateHeader => <String>[
        'email',
        for (final label in ProfileLabel.values) label.column,
      ].join(',');

  /// The label columns, in template order — what the description under the
  /// picker lists as "at least one of".
  static List<String> get labelColumns =>
      ProfileLabel.values.map((label) => label.column).toList(growable: false);

  /// The same cap as the roster import: it only stops a mis-picked export from
  /// becoming thousands of sequential requests before anyone notices.
  static int get maxRows => StudentRosterCsv.maxRows;

  static const List<String> _emailAliases = <String>[
    'email',
    'e mail',
    'email address',
    'mail',
  ];

  /// Every spelling of a label column this parser recognises, keyed by the
  /// column it means (the name `ProfileLabel.column` carries).
  static const Map<String, List<String>> _labelAliases = <String, List<String>>{
    'faculty': <String>['faculty', 'faculty name'],
    'department': <String>['department', 'dept', 'department name'],
    'level': <String>['level', 'class', 'year'],
    'matric_number': <String>[
      'matric number',
      'matric no',
      'matriculation number',
      'matric',
    ],
    'staff_id': <String>['staff id', 'staff number', 'staff no'],
  };

  /// The same loose test the roster import and the create form use: the Edge
  /// Function validates the address again, and a cleverer pattern here would
  /// only refuse valid ones.
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// Resolves [text] (the decoded contents of the `.csv` file) against [roster]
  /// (the accounts the page is showing).
  ///
  /// Never throws: a file that cannot be read at all comes back as
  /// [LabelFixPlan.headerError], and a line that cannot be used comes back in
  /// [LabelFixPlan.problems] so the rest of the class is still corrected.
  ///
  /// A line is refused rather than guessed at when the address names nobody on
  /// [roster]: sending it with an empty id would be a request per line the
  /// function answers "Expected the account's id (a uuid)" for, and the
  /// administrator would have to work out which of their addresses the app no
  /// longer has.
  static LabelFixPlan resolve(String text, List<ManagedAccount> roster) {
    final source = _stripBom(text);
    if (source.trim().isEmpty) {
      return LabelFixPlan(
        headerError: 'This file is empty. It needs a header row: $templateHeader',
      );
    }

    final List<List<dynamic>> table;
    try {
      table = Csv(
        // Blank lines are kept so a problem can name the line the spreadsheet
        // shows; they are skipped below rather than refused.
        skipEmptyLines: false,
      ).decode(source);
    } on Exception {
      return LabelFixPlan(
        headerError: 'This file could not be read as CSV. In your spreadsheet '
            'use "Save as" → CSV, then choose it again.',
      );
    }

    if (table.isEmpty) {
      return LabelFixPlan(
        headerError: 'This file is empty. It needs a header row: $templateHeader',
      );
    }

    final header = _readHeader(table.first);
    if (header.error != null) return LabelFixPlan(headerError: header.error);
    if (!header.hasEmail) {
      return LabelFixPlan(
        headerError: 'The header is missing email. The first line should read: '
            '$templateHeader',
      );
    }
    if (header.labels.isEmpty) {
      return LabelFixPlan(
        headerError: 'The header names no label to correct. Keep email and at '
            'least one of ${labelColumns.join(', ')}.',
      );
    }

    // Address → the row it belongs to. Lower-cased because an address that
    // differs only in case is the same mailbox to every mail server there is.
    final byEmail = <String, ManagedAccount>{};
    for (final account in roster) {
      final email = account.email.trim().toLowerCase();
      if (email.isNotEmpty) byEmail[email] = account;
    }

    final corrections = <StudentLabelCorrection>[];
    final problems = <StudentRosterProblem>[];
    final seen = <String, int>{};

    for (var index = 1; index < table.length; index++) {
      final line = index + 1;
      final cells = table[index];
      String? cell(int? at) {
        if (at == null || at >= cells.length) return null;
        return AcademicCatalog.clean(cells[at]?.toString());
      }

      final isBlank = cells.every(
        (value) => AcademicCatalog.clean(value?.toString()) == null,
      );
      if (isBlank) continue;

      if (corrections.length >= maxRows) {
        return LabelFixPlan(
          corrections: corrections,
          problems: problems,
          headerError: 'This file has more than $maxRows students. Split it '
              'into smaller files and correct them one after another.',
        );
      }

      final email = cell(header.emailIndex);
      if (email == null) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: 'There is no email address on this line.',
          ),
        );
        continue;
      }
      if (!_emailPattern.hasMatch(email)) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: '"$email" is not an email address.',
          ),
        );
        continue;
      }

      final key = email.toLowerCase();
      final firstSeen = seen[key];
      if (firstSeen != null) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: '$email appears twice in this file (also line $firstSeen).',
          ),
        );
        continue;
      }
      seen[key] = line;

      final account = byEmail[key];
      if (account == null) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: '"$email" is not on the account list shown here. Reload '
                'the list, or check the address in the file.',
          ),
        );
        continue;
      }

      final values = <ProfileLabel, String?>{};
      var refusedLevel = false;
      for (final entry in header.columns.entries) {
        final raw = cell(entry.value);
        if (entry.key == ProfileLabel.level) {
          final level = AcademicCatalog.normaliseLevel(raw);
          if (raw != null && level == null) {
            problems.add(
              StudentRosterProblem(
                line: line,
                message: 'Level "$raw" for $email is not one of '
                    '${AcademicCatalog.levels.join(', ')}.',
              ),
            );
            refusedLevel = true;
            break;
          }
          values[entry.key] = level;
        } else {
          values[entry.key] = raw;
        }
      }
      if (refusedLevel) continue;

      if (values.values.every((value) => value == null)) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: 'This line changes nothing for $email: every label in it '
                'is blank.',
          ),
        );
        continue;
      }

      corrections.add(
        StudentLabelCorrection(
          userId: account.id,
          // The roster's spelling, not the file's: a refusal has to be
          // recognisable against the list the administrator is looking at.
          email: account.email,
          labels: values,
        ),
      );
    }

    return LabelFixPlan(corrections: corrections, problems: problems);
  }

  /// Where the `email` cell and each recognised label sit in the header row.
  static _Header _readHeader(List<dynamic> row) {
    int? emailIndex;
    final columns = <ProfileLabel, int>{};
    for (var at = 0; at < row.length; at++) {
      final name = _normaliseHeader(row[at]?.toString());
      if (name.isEmpty) continue;

      if (emailIndex == null && _emailAliases.contains(name)) {
        emailIndex = at;
        continue;
      }
      for (final entry in _labelAliases.entries) {
        if (!entry.value.contains(name)) continue;
        final label = ProfileLabel.values.firstWhere(
          (value) => value.column == entry.key,
        );
        // First occurrence wins, so a file that repeats a column heading uses
        // the one a spreadsheet would show first rather than the last.
        columns.putIfAbsent(label, () => at);
        break;
      }
    }

    if (emailIndex == null && columns.isEmpty) {
      return _Header(
        error: 'The first line must be the column names: $templateHeader',
      );
    }
    return _Header(emailIndex: emailIndex, columns: columns);
  }

  /// "Matric_Number " → "matric number", the form [_labelAliases] is keyed on.
  static String _normaliseHeader(String? raw) => (raw ?? '')
      .replaceAll('\uFEFF', '')
      .replaceAll(RegExp(r'[_\-\s]+'), ' ')
      .trim()
      .toLowerCase();

  /// Excel exports UTF-8 with a byte-order mark; left in place it would turn the
  /// first header cell into "\uFEFFemail" and lose the `email` column.
  static String _stripBom(String text) =>
      text.startsWith('\uFEFF') ? text.substring(1) : text;
}

/// A parsed header row: where `email` and each label sit, or why none could be
/// read.
class _Header {
  const _Header({
    this.emailIndex,
    this.columns = const <ProfileLabel, int>{},
    this.error,
  });

  final int? emailIndex;
  final Map<ProfileLabel, int> columns;
  final String? error;

  bool get hasEmail => emailIndex != null;

  List<ProfileLabel> get labels => columns.keys.toList(growable: false);
}
