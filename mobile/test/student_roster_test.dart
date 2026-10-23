import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/admin/data/student_roster_csv.dart';
import 'package:proctorguard/features/admin/domain/entities/student_roster.dart';

/// The two halves of a roster import that never touch a network:
///
///  * **reading the file** — a spreadsheet is the one input an administrator
///    cannot be walked through by the UI, so what the parser accepts, guesses
///    and refuses is pinned here;
///  * **what comes back** — the pages of an import add up into one handover
///    sheet, and an old deployment's answer reads as "nothing", not a crash.
void main() {
  group('reading a roster file', () {
    test('a complete row becomes an account with its academic labels', () {
      final parse = StudentRosterCsv.parse(
        '${StudentRosterCsv.templateHeader}\n'
        'ada@uni.test,Ada Nwosu,Science,Computer Science,300\n'
        'tunde@uni.test,Tunde Bello,Engineering,Computer Engineering,400\n',
      );

      expect(parse.headerError, isNull);
      expect(parse.problems, isEmpty);
      expect(parse.rows, <NewStudentAccount>[
        const NewStudentAccount(
          email: 'ada@uni.test',
          fullName: 'Ada Nwosu',
          faculty: 'Science',
          department: 'Computer Science',
          level: '300',
        ),
        const NewStudentAccount(
          email: 'tunde@uni.test',
          fullName: 'Tunde Bello',
          faculty: 'Engineering',
          department: 'Computer Engineering',
          level: '400',
        ),
      ]);
      // `hasNothingToSend` is what disables the upload button.
      expect(parse.hasNothingToSend, isFalse);
    });

    test('the header is read through the spellings a spreadsheet writes', () {
      final parse = StudentRosterCsv.parse(
        'E-mail,Student Name,Faculty Name,Dept,Year\n'
        'ada@uni.test,Ada Nwosu,Science,Computer Science,300 Level\n',
      );

      expect(parse.headerError, isNull);
      expect(parse.rows.single.email, 'ada@uni.test');
      expect(parse.rows.single.fullName, 'Ada Nwosu');
      expect(parse.rows.single.department, 'Computer Science');
      // `level` is compared with plain equality by `exams_select`, so
      // "300 Level" has to become the '300' the column stores.
      expect(parse.rows.single.level, '300');
    });

    test('a byte-order mark, blank lines and padded cells are tolerated', () {
      final parse = StudentRosterCsv.parse(
        '\uFEFFemail,full_name,faculty,department,level\r\n'
        '  ada@uni.test , Ada Nwosu , Science ,  ,  300 \r\n'
        '\r\n'
        '   \r\n'
        'tunde@uni.test,Tunde Bello,,,\r\n',
      );

      expect(parse.headerError, isNull);
      // Blank lines are not reported as problems: they are a trailing newline,
      // not a mistake the administrator has to fix.
      expect(parse.problems, isEmpty);
      expect(parse.rows.length, 2);
      expect(parse.rows.first.email, 'ada@uni.test');
      expect(parse.rows.first.fullName, 'Ada Nwosu');
      expect(parse.rows.first.faculty, 'Science');
      // A blank cell is "not stated", which is null — not the string ''.
      expect(parse.rows.first.department, isNull);
      expect(parse.rows.first.level, '300');
      expect(parse.rows.last.faculty, isNull);
      expect(parse.rows.last.level, isNull);
    });

    test('a department the catalogue knows fills in its faculty', () {
      final parse = StudentRosterCsv.parse(
        'email,full_name,department\n'
        'ada@uni.test,Ada Nwosu,computer science\n',
      );

      // Case-insensitively matched to the catalogue, then written in the
      // catalogue's spelling: a paper aimed at the *faculty* still reaches her.
      expect(parse.rows.single.department, 'computer science');
      expect(parse.rows.single.faculty, 'Science');
    });

    test('an empty file names the header it needs', () {
      final parse = StudentRosterCsv.parse('  \n');

      expect(parse.rows, isEmpty);
      expect(parse.headerError, contains(StudentRosterCsv.templateHeader));
      expect(parse.hasNothingToSend, isTrue);
    });

    test('a missing column is named, so the header can be fixed', () {
      final parse = StudentRosterCsv.parse(
        'email,faculty,department\nada@uni.test,Science,Computer Science\n',
      );

      expect(parse.rows, isEmpty);
      expect(parse.headerError, contains('missing full_name'));
      expect(parse.headerError, contains(StudentRosterCsv.templateHeader));
    });

    test('a first line that is not a header is refused whole', () {
      final parse = StudentRosterCsv.parse('Ada Nwosu,ada@uni.test\n');

      expect(parse.rows, isEmpty);
      expect(parse.headerError, contains('column names'));
    });

    test('more rows than one import allows is refused whole', () {
      final source = StringBuffer('email,full_name\n');
      for (var at = 0; at <= StudentRosterCsv.maxRows; at++) {
        source.writeln('student$at@uni.test,Student $at');
      }

      final parse = StudentRosterCsv.parse(source.toString());

      // Refused rather than truncated: a class list that silently loses its
      // last row is worse than one that has to be split.
      expect(parse.rows, isEmpty);
      expect(
        parse.headerError,
        contains('more than ${StudentRosterCsv.maxRows} students'),
      );
    });
  });

  group('lines that cannot be sent', () {
    test('a bad address, a missing name, a duplicate and a bad level are '
        'reported by line while the rest of the class goes', () {
      final parse = StudentRosterCsv.parse(
        'email,full_name,faculty,department,level\n'
        'not-an-address,Ada Nwosu,,,\n'
        'ada@uni.test,,,,\n'
        'ada@uni.test,Ada Nwosu,,,\n'
        'ADA@UNI.TEST,Ada Again,,,\n'
        'boom@uni.test,Bo Om,,,700\n'
        'tunde@uni.test,Tunde Bello,,,\n',
      );

      expect(parse.headerError, isNull);
      expect(parse.rows.map((row) => row.email), <String>[
        'ada@uni.test',
        'tunde@uni.test',
      ]);
      expect(parse.problems.map((problem) => problem.line), <int>[2, 3, 5, 6]);
      expect(
        parse.problems.first.message,
        '"not-an-address" is not an email address.',
      );
      expect(
        parse.problems[1].message,
        contains('no full name for ada@uni.test'),
      );
      // The duplicate names the line it duplicates, case-insensitively: the
      // second account would be refused by the function anyway.
      expect(
        parse.problems[2].message,
        'ADA@UNI.TEST appears twice in this file (also line 4).',
      );
      expect(parse.problems.last.message, contains('Level "700"'));
      expect(parse.problems.last.message, contains('600'));
    });

    test('a level that is not a catalogue level is refused, not guessed', () {
      for (final level in <String>['3', '3000', 'third', '700']) {
        final parse = StudentRosterCsv.parse(
          'email,full_name,level\nada@uni.test,Ada Nwosu,$level\n',
        );

        expect(parse.rows, isEmpty, reason: '"$level" names no cohort');
        expect(parse.problems.single.line, 2);
      }

      // The spellings a spreadsheet actually writes are read.
      for (final level in <String>['100', '100 level', '100L', 'LEVEL 100']) {
        final parse = StudentRosterCsv.parse(
          'email,full_name,level\nada@uni.test,Ada Nwosu,$level\n',
        );

        expect(parse.rows.single.level, '100', reason: level);
      }
    });
  });

  group('what an import reports back', () {
    CreatedStudentAccount created(String email, String password) =>
        CreatedStudentAccount.fromMap(<String, dynamic>{
          'id': 'id-$email',
          'email': email,
          'full_name': email.split('@').first,
          'role': 'student',
          'faculty': 'Science',
          'department': 'Computer Science',
          'level': '300',
          'temporary_password': password,
        });

    test('a row is sent with the column spellings the function reads', () {
      const row = NewStudentAccount(
        email: 'ada@uni.test',
        fullName: 'Ada Nwosu',
        faculty: 'Science',
      );

      // `full_name`, not `fullName`; and the labels that were not stated are
      // absent rather than null, so an unlabelled row's body is unchanged from
      // before academic targeting existed.
      expect(row.toJson(), <String, dynamic>{
        'email': 'ada@uni.test',
        'full_name': 'Ada Nwosu',
        'faculty': 'Science',
      });
    });

    test('the pages of one import add up into a single handover sheet', () {
      final first = StudentRosterOutcome(created: <CreatedStudentAccount>[
        created('ada@uni.test', 'Pg-ada'),
      ]);
      final second = StudentRosterOutcome(
        created: <CreatedStudentAccount>[created('tunde@uni.test', 'Pg-tunde')],
        failed: <RefusedStudentRow>[
          const RefusedStudentRow(
            email: 'chi@uni.test',
            error: 'chi@uni.test already has an account.',
          ),
        ],
      );

      final total = first + second;

      expect(total.createdCount, 2);
      expect(total.failedCount, 1);
      expect(total.allCreated, isFalse);
      // One address and password per line, tab-separated so a paste lands in
      // two spreadsheet columns instead of one.
      expect(
        total.handoverSheet,
        'ada@uni.test\tPg-ada\ntunde@uni.test\tPg-tunde',
      );
      expect(first.allCreated, isTrue);
    });

    test('an answer from before the roster branch reads as empty', () {
      // A single-account answer: no `created`, no `failed`. Nothing was
      // uploaded, and `isEmpty` is what lets the caller say so instead of
      // reporting an empty success.
      final outcome = StudentRosterOutcome.fromMap(<String, dynamic>{
        'id': 'new-1',
        'email': 'ada@uni.test',
        'role': 'student',
      });

      expect(outcome.isEmpty, isTrue);
      expect(outcome.handoverSheet, isEmpty);
    });

    test('a created row whose password is missing is still reported', () {
      final outcome = StudentRosterOutcome.fromMap(<String, dynamic>{
        'created': <dynamic>[
          <String, dynamic>{
            'id': 'id-ada',
            'email': 'ada@uni.test',
            'full_name': 'Ada Nwosu',
            'role': 'student',
          },
        ],
      });

      // The account exists either way; hiding it would leave the administrator
      // believing nothing was created.
      expect(outcome.createdCount, 1);
      expect(outcome.created.single.temporaryPassword, isEmpty);
    });
  });
}
