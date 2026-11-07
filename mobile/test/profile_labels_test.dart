import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/admin/data/student_label_csv.dart';
import 'package:proctorguard/features/admin/data/student_roster_csv.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/entities/profile_labels.dart';
import 'package:proctorguard/features/admin/domain/entities/student_roster.dart';
import 'package:proctorguard/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/admin/presentation/widgets/label_correction_widget.dart';
import 'package:proctorguard/features/admin/presentation/widgets/roster_file.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';

/// Correcting a class's labels, in its two halves:
///
///  * the CSV parser, which turns addresses into the ids the Edge Function
///    selects rows by — and decides, before anything is sent, which lines are
///    corrections and which are problems;
///  * the card, driven with files handed in by the test instead of the platform
///    picker, which shows what a file will change and pages it up.
///
/// The single-account half (the Edit dialog) is driven through the admin
/// dashboard in `role_routing_test.dart`, where that page already has a harness.
void main() {
  const ada = ManagedAccount(
    id: '11111111-1111-4111-8111-111111111111',
    email: 'ada@uni.test',
    fullName: 'Ada Nwosu',
    role: UserRole.student,
  );
  const tunde = ManagedAccount(
    id: '22222222-2222-4222-8222-222222222222',
    email: 'tunde@uni.test',
    fullName: 'Tunde Bello',
    role: UserRole.student,
  );
  const roster = <ManagedAccount>[ada, tunde];

  group('the corrections file, resolved against the roster', () {
    test('maps an address to the id, and sends only the columns it names', () {
      // The address differs in case, the level is spelt the way a spreadsheet
      // usually writes it, and `faculty` is not in the header at all.
      final plan = StudentLabelCsv.resolve(
        'email,level\nADA@uni.test,300 Level\n',
        roster,
      );

      expect(plan.headerError, isNull);
      expect(plan.problems, isEmpty);
      final correction = plan.corrections.single;
      expect(correction.userId, ada.id);
      // The roster's spelling, so a refusal is recognisable against the list.
      expect(correction.email, 'ada@uni.test');
      expect(correction.labels, <ProfileLabel, String?>{
        ProfileLabel.level: '300',
      });
      // The wire body uses the column's own name, never `userId`.
      expect(correction.toJson(), <String, dynamic>{
        'id': ada.id,
        'email': 'ada@uni.test',
        'level': '300',
      });
    });

    test('a blank cell clears its column; a column left out is untouched', () {
      final plan = StudentLabelCsv.resolve(
        'email,faculty,department,level,matric_number\n'
        'ada@uni.test,Science,,300,\n',
        roster,
      );

      expect(plan.problems, isEmpty);
      expect(plan.corrections.single.labels, <ProfileLabel, String?>{
        // Stated.
        ProfileLabel.faculty: 'Science',
        ProfileLabel.level: '300',
        // Present and blank: clear it.
        ProfileLabel.department: null,
        ProfileLabel.matricNumber: null,
        // `staff_id` is absent from the header, so it is not in the map at all
        // — which is what tells the function to leave that column alone.
      });
      expect(
        plan.corrections.single.labels.containsKey(ProfileLabel.staffId),
        isFalse,
      );
    });

    test('a line that changes nothing is a problem, not a request', () {
      // Every named column is blank, so the row would be a PATCH that writes
      // nothing — more likely a mixed-up file than an instruction.
      final plan = StudentLabelCsv.resolve(
        'email,level,matric_number\nada@uni.test,,\n',
        roster,
      );

      expect(plan.corrections, isEmpty);
      expect(
        plan.problems.single.message,
        contains('changes nothing for ada@uni.test'),
      );
      expect(plan.problems.single.line, 2);
    });

    test('an unknown address, an unreadable level and a repeat are refused', () {
      final plan = StudentLabelCsv.resolve(
        'email,level\n'
        'ada@uni.test,3rd year\n'
        'nobody@uni.test,200\n'
        'ada@uni.test,400\n',
        roster,
      );

      expect(plan.corrections, isEmpty);
      // One problem per line, each naming the line a spreadsheet shows.
      expect(plan.problems.map((problem) => problem.line), <int>[2, 3, 4]);
      expect(plan.problems[0].message, contains('Level "3rd year"'));
      expect(plan.problems[1].message, contains('is not on the account list'));
      expect(plan.problems[2].message, contains('also line 2'));
    });

    test('a file with nothing to attribute rows from is refused whole', () {
      // No email column: nothing can be resolved, so no line is sent.
      final noEmail =
          StudentLabelCsv.resolve('grade,cohort\n300,A\n', roster);
      expect(noEmail.headerError, contains('must be the column names'));
      expect(noEmail.corrections, isEmpty);

      // An email column and nothing to write.
      final noLabels = StudentLabelCsv.resolve('email\nada@uni.test\n', roster);
      expect(noLabels.headerError, contains('names no label to correct'));

      final empty = StudentLabelCsv.resolve('', roster);
      expect(empty.headerError, contains('This file is empty'));
    });

    test('spreadsheet spellings of the header are understood', () {
      final plan = StudentLabelCsv.resolve(
        'E-mail,Matric No,Level\nada@uni.test,CSC/2021/041,300\n',
        roster,
      );

      expect(plan.problems, isEmpty);
      expect(plan.corrections.single.labels, <ProfileLabel, String?>{
        ProfileLabel.matricNumber: 'CSC/2021/041',
        ProfileLabel.level: '300',
      });
    });

    test('a file longer than the import cap is refused whole', () {
      // A roster big enough for every line to resolve, so the only thing that
      // can stop the file is the cap itself.
      final everyone = _rosterOf(StudentRosterCsv.maxRows + 1);
      final source = StringBuffer('email,level\n');
      for (final account in everyone) {
        source.writeln('${account.email},300');
      }

      final plan = StudentLabelCsv.resolve(source.toString(), everyone);
      expect(
        plan.headerError,
        contains('more than ${StudentRosterCsv.maxRows}'),
      );
      // What was read before the cap is still reported, so the administrator
      // can see the file was understood rather than malformed.
      expect(plan.corrections, isNotEmpty);
    });
  });

  group('the correction card', () {
    late _FakeAdminUsers repo;

    setUp(() => repo = _FakeAdminUsers(roster));

    Widget cardUnderTest({RosterFilePicker? pickFile}) => ProviderScope(
          overrides: [
            adminUserRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LabelCorrectionWidget(pickFile: pickFile),
              ),
            ),
          ),
        );

    /// Taps [key], scrolling it into view first: the card grows past a test
    /// window once it is showing a class's refusals.
    Future<void> tapKey(WidgetTester tester, String key) async {
      final finder = find.byKey(Key(key));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    /// Pumps a SnackBar's whole lifetime out, so no timer is left pending.
    Future<void> letSnackBarExpire(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 7));
      await tester.pump(const Duration(milliseconds: 300));
    }

    RosterFilePicker answerWith(String name, String contents) =>
        () async => RosterFile(name: name, contents: contents);

    testWidgets('a chosen file is read before anything is sent', (tester) async {
      await tester.pumpWidget(
        cardUnderTest(
          pickFile: answerWith(
            'corrections.csv',
            'email,level\nada@uni.test,300 Level\nnobody@uni.test,200\n',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tapKey(tester, 'label-fix-pick');

      expect(find.text('corrections.csv'), findsOneWidget);
      expect(find.text('1 student will be corrected.'), findsOneWidget);
      expect(find.text('1 skipped'), findsOneWidget);
      expect(find.textContaining('is not on the account list'), findsOneWidget);
      expect(find.text('Correct 1 student'), findsOneWidget);
      // Nothing left the app: a typo is fixed in the file, not discovered from
      // a 400.
      expect(repo.pages, isEmpty);
    });

    testWidgets('the corrections go up in pages and are totalled', (
      tester,
    ) async {
      repo.accounts = _rosterOf(51);

      await tester.pumpWidget(
        cardUnderTest(pickFile: answerWith('all.csv', _levelCsv(51))),
      );
      await tester.pumpAndSettle();

      await tapKey(tester, 'label-fix-pick');
      expect(find.text('51 students will be corrected.'), findsOneWidget);

      await tapKey(tester, 'label-fix-apply');

      // The same page size the roster import uses: the function refuses more.
      expect(repo.pages.map((page) => page.length), <int>[50, 1]);
      expect(find.text('51 students corrected'), findsOneWidget);
      expect(find.text('Corrected 51 students.'), findsOneWidget);
      await letSnackBarExpire(tester);
    });

    testWidgets('a row the server refused is listed with its reason', (
      tester,
    ) async {
      repo.answer = (page) => LabelFixOutcome(
        updated: <ManagedAccount>[repo.corrected(page.first)],
        failed: const <RefusedStudentRow>[
          RefusedStudentRow(
            email: 'tunde@uni.test',
            error: 'That account is not a student.',
          ),
        ],
      );

      await tester.pumpWidget(
        cardUnderTest(
          pickFile: answerWith(
            'two.csv',
            'email,level\nada@uni.test,300\ntunde@uni.test,400\n',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tapKey(tester, 'label-fix-pick');
      await tapKey(tester, 'label-fix-apply');

      // The rows that were written stay listed beside the one that was not —
      // the same shape as the roster import's outcome.
      expect(find.text('1 student corrected'), findsOneWidget);
      expect(find.text('1 row was not corrected'), findsOneWidget);
      expect(
        find.text('tunde@uni.test — That account is not a student.'),
        findsOneWidget,
      );
      await letSnackBarExpire(tester);
    });

    testWidgets('a page that fails stops the run and keeps what it wrote', (
      tester,
    ) async {
      repo.accounts = _rosterOf(51);
      var calls = 0;
      repo.answer = (page) {
        calls++;
        if (calls == 2) {
          throw const AdminAccountException('Could not reach the server.');
        }
        return LabelFixOutcome(
          updated: page.map(repo.corrected).toList(growable: false),
        );
      };

      await tester.pumpWidget(
        cardUnderTest(pickFile: answerWith('all.csv', _levelCsv(51))),
      );
      await tester.pumpAndSettle();

      await tapKey(tester, 'label-fix-pick');
      await tapKey(tester, 'label-fix-apply');

      expect(repo.pages.length, 2);
      expect(find.byKey(const Key('label-fix-error')), findsOneWidget);
      // How far it got, because the first 50 rows really were written.
      expect(
        find.textContaining('50 of 51 students were corrected'),
        findsOneWidget,
      );
      expect(find.text('50 students corrected'), findsOneWidget);
    });
  });
}

/// A roster of [count] students, for the paging tests.
List<ManagedAccount> _rosterOf(int count) => <ManagedAccount>[
      for (var at = 0; at < count; at++)
        ManagedAccount(
          id:
              '00000000-0000-4000-8000-0000000000${at.toString().padLeft(2, '0')}',
          email: 'student$at@uni.test',
          fullName: 'Student $at',
          role: UserRole.student,
        ),
    ];

/// "email,level" plus [count] rows, one per student in [_rosterOf].
String _levelCsv(int count) {
  final source = StringBuffer('email,level\n');
  for (var at = 0; at < count; at++) {
    source.writeln('student$at@uni.test,300');
  }
  return source.toString();
}

/// Stands in for `AdminUserRepositoryImpl`: it answers pages the way
/// `admin-update-profile` does, and keeps them so a test can prove the paging.
class _FakeAdminUsers implements AdminUserRepository {
  _FakeAdminUsers(this.accounts);

  List<ManagedAccount> accounts;

  /// Every page of corrections the card sent, in order.
  final List<List<StudentLabelCorrection>> pages =
      <List<StudentLabelCorrection>>[];

  /// Answers a page instead of the default "every row corrected".
  LabelFixOutcome Function(List<StudentLabelCorrection> page)? answer;

  /// The row a correction writes, as the server would answer it: the columns the
  /// row named are replaced (or cleared), the rest are left as they were.
  ManagedAccount corrected(StudentLabelCorrection correction) {
    final base = accounts.firstWhere(
      (account) => account.id == correction.userId,
    );
    String? pick(ProfileLabel label, String? stored) =>
        correction.labels.containsKey(label)
            ? correction.labels[label]
            : stored;

    return ManagedAccount(
      id: base.id,
      email: base.email,
      fullName: base.fullName,
      role: base.role,
      createdAt: base.createdAt,
      faculty: pick(ProfileLabel.faculty, base.faculty),
      department: pick(ProfileLabel.department, base.department),
      level: pick(ProfileLabel.level, base.level),
      matricNumber: pick(ProfileLabel.matricNumber, base.matricNumber),
      staffId: pick(ProfileLabel.staffId, base.staffId),
    );
  }

  @override
  Future<LabelFixOutcome> correctStudentLabels(
    List<StudentLabelCorrection> corrections,
  ) async {
    pages.add(corrections);
    final custom = answer;
    if (custom != null) return custom(corrections);

    return LabelFixOutcome(
      updated: corrections.map(corrected).toList(growable: false),
    );
  }

  @override
  Future<List<ManagedAccount>> listAccounts() async =>
      List<ManagedAccount>.of(accounts);

  @override
  Future<ManagedAccount> createAccount({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
    String? faculty,
    String? department,
    String? level,
    String? matricNumber,
    String? staffId,
  }) =>
      throw UnimplementedError('the card never creates an account');

  @override
  Future<StudentRosterOutcome> createStudentAccounts(
    List<NewStudentAccount> students,
  ) =>
      throw UnimplementedError('the card never imports a roster');

  @override
  Future<ManagedAccount> updateProfileLabels({
    required String userId,
    required Map<ProfileLabel, String?> labels,
  }) =>
      throw UnimplementedError('the card corrects in bulk, not one at a time');

  @override
  Future<void> updateRole({
    required String userId,
    required UserRole role,
  }) =>
      throw UnimplementedError('the card never re-roles an account');

  @override
  Future<void> resetPassword({
    required String userId,
    required String password,
  }) =>
      throw UnimplementedError('the card never resets a password');

  @override
  Future<void> deleteAccount({required String userId}) =>
      throw UnimplementedError('the card never deletes an account');
}

