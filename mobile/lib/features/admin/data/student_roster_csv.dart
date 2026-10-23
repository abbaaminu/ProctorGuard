import 'package:csv/csv.dart';

import '../../../core/utils/academic_catalog.dart';
import '../domain/entities/student_roster.dart';

/// Reads the class list an administrator uploads into rows the Edge Function can
/// accept.
///
/// Parsing lives here, in `data/`, because it is a *format* boundary: the widget
/// above it knows about files and progress, the repository below it knows about
/// HTTP, and neither should know that a spreadsheet separates cells with commas.
/// The result is the domain's [StudentRosterParse], so what a bad file means is
/// described once, in one type, instead of in a screen full of strings.
///
/// The rules are deliberately strict about the two columns the function cannot
/// work without (`email`, `full_name`) and about `level`, which `exams_select`
/// compares with plain equality — a "300 level" stored as text would hide every
/// 300-level paper from that student. `faculty` and `department` are compared
/// case-insensitively by the policy, so they may be spelled freely.
class StudentRosterCsv {
  const StudentRosterCsv._();

  /// The header this parser accepts, in the order the template writes it.
  static const List<String> columns = <String>[
    'email',
    'full_name',
    'faculty',
    'department',
    'level',
  ];

  /// "email,full_name,faculty,department,level" — what the card shows as its
  /// template, and what a rejected header is compared against in its message.
  static String get templateHeader => columns.join(',');

  /// Rows accepted from one file. The function takes 50 per request and the
  /// widget pages through them; this cap only stops a mis-picked 100 000-row
  /// export from becoming 2 000 sequential requests before anyone notices.
  static const int maxRows = 1000;

  /// Every spelling of a column this parser recognises, keyed by the column it
  /// means. Spreadsheets rename headers freely ("Full Name", "E-mail"), and a
  /// file rejected over a capital letter would be a support ticket, not a
  /// safeguard.
  static const Map<String, List<String>> _aliases = <String, List<String>>{
    'email': <String>['email', 'e mail', 'email address', 'mail'],
    'full_name': <String>['full name', 'name', 'student name', 'student'],
    'faculty': <String>['faculty', 'faculty name'],
    'department': <String>['department', 'dept', 'department name'],
    'level': <String>['level', 'class', 'year'],
  };

  /// At least one non-space before and after the `@`, and a dot in the domain:
  /// the same loose test the create form uses, because the Edge Function and
  /// Supabase Auth validate the address again and a clever regex here would only
  /// refuse valid ones.
  static final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// Parses [text] (the decoded contents of the `.csv` file).
  ///
  /// Never throws: a file that cannot be read at all comes back as
  /// [StudentRosterParse.headerError], and a line that cannot be used comes back
  /// in [StudentRosterParse.problems] so the rest of the class still uploads.
  static StudentRosterParse parse(String text) {
    final source = _stripBom(text);
    if (source.trim().isEmpty) {
      return const StudentRosterParse(
        headerError: 'This file is empty. It needs a header row: '
            'email,full_name,faculty,department,level',
      );
    }

    final List<List<dynamic>> table;
    try {
      table = Csv(
        // Keep blank lines: they are counted so a problem can name the line the
        // spreadsheet shows. (A quoted cell containing a newline still shifts
        // the count — the message names the address too, which is the part an
        // administrator can search for.)
        skipEmptyLines: false,
      ).decode(source);
    } on Exception {
      return const StudentRosterParse(
        headerError: 'This file could not be read as CSV. In your spreadsheet '
            'use "Save as" → CSV, then choose it again.',
      );
    }

    if (table.isEmpty) {
      return const StudentRosterParse(
        headerError: 'This file is empty. It needs a header row: '
            'email,full_name,faculty,department,level',
      );
    }

    final header = _readHeader(table.first);
    if (header.error != null) {
      return StudentRosterParse(headerError: header.error);
    }
    if (!header.has('email') || !header.has('full_name')) {
      final missing = <String>[
        if (!header.has('email')) 'email',
        if (!header.has('full_name')) 'full_name',
      ];
      return StudentRosterParse(
        headerError: 'The header is missing ${missing.join(' and ')}. The first '
            'line should read: $templateHeader',
      );
    }


    final rows = <NewStudentAccount>[];
    final problems = <StudentRosterProblem>[];
    // Address → the line it was accepted on, so the second copy can name the
    // first instead of just being refused.
    final seen = <String, int>{};

    for (var index = 1; index < table.length; index++) {
      final line = index + 1;
      final cells = table[index];
      String? cell(String column) {
        final at = header.index[column];
        if (at == null || at >= cells.length) return null;
        return AcademicCatalog.clean(cells[at]?.toString());
      }

      // Blank lines (a trailing newline, a spacer row) are not problems.
      final isBlank = cells.every(
        (value) => AcademicCatalog.clean(value?.toString()) == null,
      );
      if (isBlank) continue;

      if (rows.length >= maxRows) {
        return StudentRosterParse(
          headerError: 'This file has more than $maxRows students. Split it '
              'into smaller files and upload them one after another.',
        );
      }

      final email = cell('email');
      final fullName = cell('full_name');
      final rawLevel = cell('level');

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
      if (fullName == null) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: 'There is no full name for $email.',
          ),
        );
        continue;
      }

      final level = AcademicCatalog.normaliseLevel(rawLevel);
      if (rawLevel != null && level == null) {
        problems.add(
          StudentRosterProblem(
            line: line,
            message: 'Level "$rawLevel" for $email is not one of '
                '${AcademicCatalog.levels.join(', ')}.',
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

      final department = cell('department');
      var faculty = cell('faculty');
      // A department the catalogue knows implies its faculty: filling it in is
      // what lets a paper targeted at the faculty (rather than at one
      // department) still reach this student.
      if (faculty == null && department != null) {
        faculty = AcademicCatalog.facultyOf(department);
      }

      rows.add(
        NewStudentAccount(
          email: email,
          fullName: fullName,
          faculty: faculty,
          department: department,
          level: level,
        ),
      );
    }

    return StudentRosterParse(rows: rows, problems: problems);
  }

  /// Where each known column sits in the header row.
  static _Header _readHeader(List<dynamic> row) {
    final index = <String, int>{};
    for (var at = 0; at < row.length; at++) {
      final name = _normaliseHeader(row[at]?.toString());
      if (name.isEmpty) continue;
      for (final entry in _aliases.entries) {
        if (entry.value.contains(name) && !index.containsKey(entry.key)) {
          index[entry.key] = at;
          break;
        }
      }
    }

    if (index.isEmpty) {
      return const _Header(
        index: <String, int>{},
        error: 'The first line must be the column names: '
            'email,full_name,faculty,department,level',
      );
    }
    return _Header(index: index);
  }

  /// "Full_Name " → "full name", the form [_aliases] is keyed on.
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

/// A parsed header row: the column positions found, or why none were.
class _Header {
  const _Header({required this.index, this.error});

  final Map<String, int> index;
  final String? error;

  bool has(String column) => index.containsKey(column);
}
