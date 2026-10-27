import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/entities/student_roster.dart';
import 'package:proctorguard/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/admin/presentation/widgets/bulk_student_upload_widget.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';

/// The bulk student card, driven with files handed in by the test instead of the
/// platform picker:
///
///  * a chosen file is *read* (and shown, with the lines it could not use)
///    before anything is sent, so a typo in row 40 is visible before it becomes
///    an account;
///  * a large file goes up in pages of [AdminUserRepository.maxStudentPageSize],
///    and a page that fails stops the run with the passwords already created
///    still on screen — they are the only copy that exists.
void main() {
  late _FakeAdminUsers repo;

  const roster = 'email,full_name,faculty,department,level\n'
      'ada@uni.test,Ada Nwosu,Science,Computer Science,300\n'
      'tunde@uni.test,Tunde Bello,Engineering,Computer Engineering,400\n'
      'chi@uni.test,Chi Eze,Science,Physics,200\n'
      'not-an-address,Not An Address,,,\n';

  /// A roster of [count] students, for the paging tests.
  String bigRoster(int count) {
    final source = StringBuffer('email,full_name\n');
    for (var at = 0; at < count; at++) {
      source.writeln('student$at@uni.test,Student $at');
    }
    return source.toString();
  }

  setUp(() => repo = _FakeAdminUsers());

  Widget uploadUnderTest({RosterFilePicker? pickFile}) => ProviderScope(
        overrides: [
          adminUserRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BulkStudentUploadWidget(pickFile: pickFile),
            ),
          ),
        ),
      );

  /// Taps [key], scrolling it into view first: the card grows well past a test
  /// window once it is showing a class's passwords.
  Future<void> tapKey(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Picks whatever [pickFile] hands the card.
  Future<void> choose(WidgetTester tester) => tapKey(tester, 'roster-pick');

  /// Pumps a SnackBar's whole lifetime out, so no timer is left pending when the
  /// test ends — the card's messages last three seconds, its errors six.
  Future<void> letSnackBarExpire(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a chosen file is read and summarised before anything is sent',
      (tester) async {
    await tester.pumpWidget(
      uploadUnderTest(
        pickFile: () async =>
            const RosterFile(name: 'students.csv', contents: roster),
      ),
    );
    await tester.pumpAndSettle();

    // Nothing chosen yet, so nothing to upload and nothing to press.
    expect(find.byKey(const Key('roster-upload')), findsNothing);

    await choose(tester);

    // Reading is not sending: the counts are on screen for the administrator to
    // check first.
    expect(repo.pages, isEmpty);
    expect(find.text('students.csv'), findsOneWidget);
    expect(find.text('3 students ready to upload.'), findsOneWidget);
    expect(find.text('1 skipped'), findsOneWidget);
    expect(
      find.text('Line 5: "not-an-address" is not an email address.'),
      findsOneWidget,
    );
    expect(find.text('Create 3 student accounts'), findsOneWidget);
    expect(find.byKey(const Key('roster-outcome')), findsNothing);
  });

  testWidgets('a cancelled picker leaves the file already chosen alone',
      (tester) async {
    RosterFile? next = const RosterFile(name: 'students.csv', contents: roster);
    await tester.pumpWidget(uploadUnderTest(pickFile: () async => next));
    await tester.pumpAndSettle();
    await choose(tester);
    expect(find.text('students.csv'), findsOneWidget);

    // Closing the dialog is not a decision to clear the card.
    next = null;
    await choose(tester);

    expect(find.text('students.csv'), findsOneWidget);
    expect(find.text('3 students ready to upload.'), findsOneWidget);
    expect(find.byKey(const Key('roster-error')), findsNothing);
  });

  testWidgets('a header no row can be attributed from is never uploaded',
      (tester) async {
    await tester.pumpWidget(
      uploadUnderTest(
        pickFile: () async => const RosterFile(
          name: 'broken.csv',
          contents: 'Ada Nwosu,ada@uni.test\n',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester);

    expect(find.byKey(const Key('roster-header-error')), findsOneWidget);
    expect(find.textContaining('column names'), findsOneWidget);

    // The button is there but dead: a file that names no columns would create
    // nothing, and saying so beats sending it.
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('roster-upload')),
    );
    expect(button.onPressed, isNull);
    expect(repo.pages, isEmpty);
  });

  testWidgets('a large file goes up in pages, and every password is listed',
      (tester) async {
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      uploadUnderTest(
        pickFile: () async =>
            RosterFile(name: 'class.csv', contents: bigRoster(51)),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester);
    expect(find.text('51 students ready to upload.'), findsOneWidget);

    await tapKey(tester, 'roster-upload');

    // 50 is what the function accepts in one body; the 51st is a second page.
    expect(repo.pages.map((page) => page.length), <int>[50, 1]);
    expect(find.text('51 student accounts created'), findsOneWidget);
    // Both pages' passwords are on screen: the second page's are as
    // unrecoverable as the first's.
    expect(find.byKey(const Key('roster-created-50')), findsOneWidget);
    expect(find.text('Pg-student0'), findsOneWidget);

    await tapKey(tester, 'roster-copy');

    // One address and password per line, tab-separated: what a class handout is
    // pasted from.
    expect(copied.single.split('\n').length, 51);
    expect(copied.single.split('\n').first, 'student0@uni.test\tPg-student0');
    await letSnackBarExpire(tester);
  });

  testWidgets('a row the server refused is listed beside the ones it created',
      (tester) async {
    repo.answer = (page) => StudentRosterOutcome(
          created: <CreatedStudentAccount>[
            if (page.isNotEmpty) repo.createdFor(page.first),
          ],
          failed: <RefusedStudentRow>[
            for (final student in page.skip(1))
              RefusedStudentRow(
                email: student.email,
                error: '${student.email} already has an account.',
              ),
          ],
        );

    await tester.pumpWidget(
      uploadUnderTest(
        pickFile: () async =>
            const RosterFile(name: 'students.csv', contents: roster),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester);
    await tapKey(tester, 'roster-upload');

    // A success with two refusals is not a failed import: the account that was
    // made is reported, and so is each reason the other two were not.
    expect(find.text('1 student account created'), findsOneWidget);
    expect(find.text('2 rows were not created'), findsOneWidget);
    expect(find.text('Pg-ada'), findsOneWidget);
    expect(
      find.text('tunde@uni.test — tunde@uni.test already has an account.'),
      findsOneWidget,
    );
    // The page's own error box stays empty: nothing whole failed.
    expect(find.byKey(const Key('roster-error')), findsNothing);
    await letSnackBarExpire(tester);
  });

  testWidgets('a page that fails stops the run and keeps what it made',
      (tester) async {
    repo.failOnPage = 2;

    await tester.pumpWidget(
      uploadUnderTest(
        pickFile: () async =>
            RosterFile(name: 'class.csv', contents: bigRoster(51)),
      ),
    );
    await tester.pumpAndSettle();
    await choose(tester);
    await tapKey(tester, 'roster-upload');

    // The second page is not retried on its own: the rest of the file stays
    // unsent, and the administrator is told how far it got.
    expect(repo.pages.length, 2);
    expect(find.byKey(const Key('roster-error')), findsOneWidget);
    expect(
      find.textContaining('50 of 51 students were created'),
      findsOneWidget,
    );
    // The first page's passwords survive the failure — that is the whole point
    // of keeping the partial outcome.
    expect(find.byKey(const Key('roster-created-49')), findsOneWidget);
    // Re-uploading the same file is offered as the way forward, so it stays
    // chosen.
    expect(find.text('Choose another file'), findsOneWidget);
  });

  testWidgets('choosing another file drops the previous run\'s passwords',
      (tester) async {
    final picks = <RosterFile>[
      const RosterFile(name: 'first.csv', contents: roster),
      const RosterFile(
        name: 'second.csv',
        contents: 'email,full_name\nada2@uni.test,Ada Two\n',
      ),
    ];
    var next = 0;
    await tester.pumpWidget(
      uploadUnderTest(pickFile: () async => picks[next++]),
    );
    await tester.pumpAndSettle();
    await choose(tester);
    await tapKey(tester, 'roster-upload');
    expect(find.text('3 student accounts created'), findsOneWidget);

    await choose(tester);

    // The old passwords belong to the old file; leaving them beside a new one
    // is how a class gets handed the wrong accounts.
    expect(find.byKey(const Key('roster-outcome')), findsNothing);
    expect(find.text('second.csv'), findsOneWidget);
    expect(find.text('1 student ready to upload.'), findsOneWidget);
    await letSnackBarExpire(tester);
  });
}

/// An [AdminUserRepository] that records every page the card sent and answers
/// the way `admin-create-user` does: one created account per row, with the
/// password the server would have generated.
class _FakeAdminUsers implements AdminUserRepository {
  final List<List<NewStudentAccount>> pages = <List<NewStudentAccount>>[];

  /// Answers a page instead of the default "created every row".
  StudentRosterOutcome Function(List<NewStudentAccount> page)? answer;

  /// The 1-based page that throws [failure] instead of answering.
  int? failOnPage;
  String failure =
      'Could not reach the server. Check your connection and try again.';

  CreatedStudentAccount createdFor(NewStudentAccount student) =>
      CreatedStudentAccount(
        account: ManagedAccount(
          id: 'id-${student.email}',
          email: student.email,
          fullName: student.fullName,
          role: UserRole.student,
          faculty: student.faculty,
          department: student.department,
          level: student.level,
        ),
        temporaryPassword: 'Pg-${student.email.split('@').first}',
      );

  @override
  Future<StudentRosterOutcome> createStudentAccounts(
    List<NewStudentAccount> students,
  ) async {
    pages.add(students);
    if (failOnPage != null && pages.length >= failOnPage!) {
      throw AdminAccountException(failure);
    }

    final custom = answer;
    if (custom != null) return custom(students);

    return StudentRosterOutcome(
      created: <CreatedStudentAccount>[
        for (final student in students) createdFor(student),
      ],
    );
  }

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
      throw UnimplementedError('the card only uses createStudentAccounts');

  @override
  Future<List<ManagedAccount>> listAccounts() async => const <ManagedAccount>[];

  @override
  Future<void> updateRole({
    required String userId,
    required UserRole role,
  }) async {}

  @override
  Future<void> resetPassword({
    required String userId,
    required String password,
  }) async {}

  @override
  Future<void> deleteAccount({required String userId}) async {}
}
