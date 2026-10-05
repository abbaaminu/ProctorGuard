import 'dart:async';

import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/auth/domain/repositories/profile_repository.dart';
import 'package:proctorguard/features/auth/presentation/providers/profile_provider.dart';
import 'package:proctorguard/features/auth/presentation/widgets/role_gate.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/pages/student_exam_portal_page.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Post-login routing: `profiles.role` decides between the student portal, the
/// staff console and the admin dashboard, with the loading and failure states
/// around it.
///
/// Everything is injected (auth stream, user id, repositories, sign-out), so no
/// Supabase project, no camera and no platform channel is involved.
void main() {
  // Ids straight out of supabase/seed.sql.
  const aishaId = '22222222-2222-4222-8222-222222222222';
  const aisha = UserProfile(
    id: aishaId,
    role: UserRole.student,
    fullName: 'Aisha Bello',
    email: 'aisha.bello@proctor.test',
  );
  const ada = UserProfile(
    id: adaUserId,
    role: UserRole.supervisor,
    fullName: 'Dr. Ada Nwosu',
    email: 'supervisor@proctor.test',
  );
  // The seed's lecturer and the bootstrap admin.
  const musa = UserProfile(
    id: '55555555-5555-4555-8555-555555555555',
    role: UserRole.lecturer,
    fullName: 'Musa Ibrahim',
    email: 'lecturer@proctor.test',
  );
  const rootAdmin = UserProfile(
    id: '44444444-4444-4444-8444-444444444444',
    role: UserRole.admin,
    fullName: 'Root Admin',
    email: 'admin@proctor.test',
  );
  const cs101Id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1';
  const mat201Id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
  const cs101 = Exam(
    id: cs101Id,
    title: 'CS101: Computer Science Fundamentals',
    createdBy: adaUserId,
    durationMinutes: 60,
    isPublished: true,
  );
  const mat201 = Exam(
    id: mat201Id,
    title: 'MAT201: Calculus Quiz',
    createdBy: adaUserId,
    durationMinutes: 45,
    isPublished: true,
  );

  late _FakeProfileRepository profiles;
  late _FakeExamRepository exams;
  late _FakeAdminUserRepository admin;

  Widget gateUnderTest({
    String userId = aishaId,
    Future<AuthOutcome> Function()? signOut,
  }) => ProviderScope(
    overrides: [
      profileRepositoryProvider.overrideWithValue(profiles),
      examRepositoryProvider.overrideWithValue(exams),
      adminUserRepositoryProvider.overrideWithValue(admin),
    ],
    child: MaterialApp(
      home: RoleGate(
        signedInChanges: Stream<bool>.value(true),
        currentUserId: () => userId,
        signOut: signOut,
      ),
    ),
  );

  setUp(() {
    profiles = _FakeProfileRepository(profile: aisha);
    exams = _FakeExamRepository(exams: <Exam>[cs101, mat201]);
    admin = _FakeAdminUserRepository();
  });

  group('profiles.role parsing', () {
    test('maps every value of the user_role enum', () {
      expect(UserRole.fromDb('student'), UserRole.student);
      expect(UserRole.fromDb('supervisor'), UserRole.supervisor);
      expect(UserRole.fromDb('lecturer'), UserRole.lecturer);
      expect(UserRole.fromDb('admin'), UserRole.admin);
      expect(UserRole.values.map((role) => role.dbValue).toList(), <String>[
        'admin',
        'lecturer',
        'supervisor',
        'student',
      ]);
    });

    test('rejects an unknown role instead of guessing', () {
      expect(() => UserRole.fromDb('principal'), throwsArgumentError);
    });

    test('falls back to the email when the row has no name', () {
      final profile = UserProfile.fromMap(<String, dynamic>{
        'id': aishaId,
        'role': 'student',
        'full_name': '   ',
        'email': 'aisha.bello@proctor.test',
      });
      expect(profile.displayName, 'aisha.bello@proctor.test');
      expect(profile.isStudent, isTrue);
      expect(profile.isStaff, isFalse);
      expect(profile.isAdmin, isFalse);
    });

    test('the staff tier is every non-student role', () {
      expect(ada.isStaff, isTrue);
      expect(musa.isStaff, isTrue);
      expect(rootAdmin.isStaff, isTrue);
      expect(rootAdmin.isAdmin, isTrue);
      expect(ada.isAdmin, isFalse);
    });
  });

  /// The portal on its own, with a stub session screen so the routing contract
  /// can be asserted without a camera.
  ///
  /// [gate] stands in for the mandatory pre-exam hardware check: the real one
  /// opens a camera and asks the OS for permissions, neither of which exists in a
  /// widget test — `hardware_gate_test.dart` covers that screen directly. The
  /// default reports "verified", which is what these routing tests are not about.
  Widget portal({
    required ExamPageBuilder builder,
    String? name = 'Aisha Bello',
    HardwareGateRequest? gate,
  }) => ProviderScope(
    overrides: [
      profileRepositoryProvider.overrideWithValue(profiles),
      examRepositoryProvider.overrideWithValue(exams),
    ],
    child: MaterialApp(
      home: StudentExamPortalPage(
        studentName: name,
        examPageBuilder: builder,
        hardwareGate: gate ?? (_, _) async => true,
      ),
    ),
  );

  Future<void> letSnackBarExpire(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(seconds: 7));

  group('student role', () {
    testWidgets('lands on the Student Exam Portal with the published exams', (
      tester,
    ) async {
      await tester.pumpWidget(gateUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Student Exam Portal'), findsOneWidget);
      expect(find.textContaining('Welcome, Aisha Bello'), findsOneWidget);
      expect(find.text('CS101: Computer Science Fundamentals'), findsOneWidget);
      expect(find.text('MAT201: Calculus Quiz'), findsOneWidget);
      expect(find.text('60 minutes'), findsOneWidget);
      expect(find.text('45 minutes'), findsOneWidget);
      expect(
        profiles.lastUserId,
        aishaId,
        reason: 'the role came from profiles.id = auth uid',
      );
    });

    testWidgets('an ongoing attempt opens the session with both ids', (
      tester,
    ) async {
      exams.submissions[mat201Id] = const Submission(
        id: 'sub-mat',
        studentId: aishaId,
        examId: mat201Id,
        answers: <String, dynamic>{},
        status: SubmissionStatus.ongoing,
      );
      (String, String)? pushed;

      await tester.pumpWidget(
        portal(
          builder: (examId, submissionId) {
            pushed = (examId, submissionId);
            return const Scaffold(body: Text('session placeholder'));
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$mat201Id')));
      await tester.pumpAndSettle();

      expect(pushed, (mat201Id, 'sub-mat'));
      expect(find.text('session placeholder'), findsOneWidget);
      expect(exams.startCalls, 1);
    });

    testWidgets('a disqualified attempt is reported, not reopened', (
      tester,
    ) async {
      exams.submissions[cs101Id] = const Submission(
        id: 'sub-cs',
        studentId: aishaId,
        examId: cs101Id,
        answers: <String, dynamic>{},
        status: SubmissionStatus.disqualified,
      );
      var opened = 0;

      await tester.pumpWidget(
        portal(
          builder: (_, _) {
            opened++;
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$cs101Id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('was disqualified'), findsOneWidget);
      expect(opened, 0, reason: 'the server owns that state');
      await letSnackBarExpire(tester);
    });

    testWidgets('a failed submission start is surfaced, not swallowed', (
      tester,
    ) async {
      exams.startError = Exception('offline');
      var opened = 0;

      await tester.pumpWidget(
        portal(
          builder: (_, _) {
            opened++;
            return const SizedBox.shrink();
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$mat201Id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Could not start'), findsOneWidget);
      expect(opened, 0);
      await letSnackBarExpire(tester);
    });

    testWidgets('a refused hardware gate blocks the exam and writes nothing', (
      tester,
    ) async {
      var opened = 0;

      await tester.pumpWidget(
        portal(
          builder: (_, _) {
            opened++;
            return const SizedBox.shrink();
          },
          // What ExamHardwareGatePage reports when the camera or the microphone
          // could not be verified.
          gate: (_, _) async => false,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$mat201Id')));
      await tester.pumpAndSettle();

      expect(opened, 0, reason: 'the session screen must not open');
      expect(
        exams.startCalls,
        0,
        reason:
            'no submission is created before the gate passes, so there is '
            'no orphaned ongoing attempt to resume',
      );
      // Still on the list, free to try again once the device is fixed.
      expect(find.text('Student Exam Portal'), findsOneWidget);
    });
  });

  group('loading and failure', () {
    testWidgets('a spinner shows while the profile is being read', (
      tester,
    ) async {
      final pending = Completer<UserProfile>();
      profiles.behaviour = () => pending.future;

      await tester.pumpWidget(gateUnderTest());
      await tester.pump();

      expect(find.text('Loading your profile…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      pending.complete(aisha);
      await tester.pumpAndSettle();

      expect(find.text('Student Exam Portal'), findsOneWidget);
    });

    testWidgets('a failed role lookup is retryable', (tester) async {
      profiles.behaviour = () => Future<UserProfile>.error(
        const ProfileLookupException(
          'Could not load your profile. Check your connection and try again.',
        ),
      );

      await tester.pumpWidget(gateUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('We could not load your profile'), findsOneWidget);
      expect(find.textContaining('Check your connection'), findsOneWidget);

      // Backend recovers -> retry re-reads the profile row, not the old error.
      profiles.behaviour = () => Future<UserProfile>.value(aisha);
      await tester.tap(find.byKey(const Key('profile-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Student Exam Portal'), findsOneWidget);
    });

    testWidgets('the error state offers a sign-out that reports failures', (
      tester,
    ) async {
      profiles.behaviour = () =>
          Future<UserProfile>.error(const ProfileLookupException('no row'));

      await tester.pumpWidget(
        gateUnderTest(
          signOut: () async => const AuthOutcome.failure('Network down'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile-sign-out')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Network down'), findsOneWidget);
      await letSnackBarExpire(tester);
    });
  });

  group('supervisor role', () {
    testWidgets('lands on the supervisor console', (tester) async {
      profiles.behaviour = () => Future<UserProfile>.value(ada);

      await tester.pumpWidget(gateUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Supervisor Console'), findsOneWidget);
      expect(find.textContaining('Welcome, Dr. Ada Nwosu'), findsOneWidget);
      expect(
        find.text('Pick an exam to open its live monitor.'),
        findsOneWidget,
      );
      expect(find.text('Student Exam Portal'), findsNothing);
      // The console's own Home control, present on every screen it opens (see
      // `HomeButton`); on the landing page itself there is nothing to pop.
      expect(find.byKey(const Key('supervisor-home')), findsOneWidget);
    });
  });

  group('lecturer role', () {
    testWidgets('shares the staff console with the supervisor', (tester) async {
      profiles.behaviour = () => Future<UserProfile>.value(musa);

      await tester.pumpWidget(gateUnderTest());
      await tester.pumpAndSettle();

      // `is_staff()` treats the two alike in the database, so the app does not
      // invent a second console for a lecturer.
      expect(find.text('Supervisor Console'), findsOneWidget);
      expect(find.textContaining('Welcome, Musa Ibrahim'), findsOneWidget);
      expect(find.text('Student Exam Portal'), findsNothing);
      // Same console, so the same Home control.
      expect(find.byKey(const Key('supervisor-home')), findsOneWidget);
    });
  });

  group('admin role', () {
    /// Desktop-width surface: at 900+ logical px the page lays the roster out in
    /// its own column (Breakpoints.expanded), where every tile is built — a
    /// phone-width `ListView` would only build the tiles that fit the viewport.
    void useDesktopSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }

    testWidgets('lands on the admin dashboard, not the staff console', (
      tester,
    ) async {
      useDesktopSurface(tester);
      profiles.behaviour = () => Future<UserProfile>.value(rootAdmin);

      await tester.pumpWidget(gateUnderTest(userId: rootAdmin.id));
      await tester.pumpAndSettle();

      expect(find.text('Admin Dashboard'), findsOneWidget);
      expect(find.textContaining('Welcome, Root Admin'), findsOneWidget);
      expect(find.text('Supervisor Console'), findsNothing);
      expect(find.text('Student Exam Portal'), findsNothing);
      // The admin console's Home control, in the same place on every screen it
      // opens - including the exam monitor, which is pushed on top of this one.
      expect(find.byKey(const Key('admin-home')), findsOneWidget);

      // The roster came from the injected repository, not from a backend.
      expect(find.text('Aisha Bello'), findsOneWidget);
      expect(find.text('manager@proctor.test'), findsOneWidget);
      expect(admin.listCalls, 1);
    });

    testWidgets('the signed-in admin is listed but cannot re-role themselves', (
      tester,
    ) async {
      useDesktopSurface(tester);
      profiles.behaviour = () => Future<UserProfile>.value(rootAdmin);

      await tester.pumpWidget(gateUnderTest(userId: rootAdmin.id));
      await tester.pumpAndSettle();

      // Their own row: labelled "(you)" and with no picker at all.
      expect(find.text('Admin (you)'), findsOneWidget);
      expect(find.byKey(Key('admin-role-${rootAdmin.id}')), findsNothing);
      // Everybody else keeps theirs.
      expect(find.byKey(const Key('admin-role-$aishaId')), findsOneWidget);
    });

    testWidgets('re-roling a row goes through the repository', (tester) async {
      useDesktopSurface(tester);
      profiles.behaviour = () => Future<UserProfile>.value(rootAdmin);

      await tester.pumpWidget(gateUnderTest(userId: rootAdmin.id));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin-role-$aishaId')));
      await tester.pumpAndSettle();

      // The menu item, not the "Supervisor" chip on the other row.
      await tester.tap(
        find.descendant(
          of: find.byType(PopupMenuItem<UserRole>),
          matching: find.text('Supervisor'),
        ),
      );
      await tester.pumpAndSettle();

      expect(admin.roleUpdates, <(String, UserRole)>[
        (aishaId, UserRole.supervisor),
      ]);
      expect(find.textContaining('is now a supervisor'), findsOneWidget);
      await letSnackBarExpire(tester);
    });

    testWidgets('a refused roster is reported with a retry', (tester) async {
      useDesktopSurface(tester);
      profiles.behaviour = () => Future<UserProfile>.value(rootAdmin);
      admin.listError = const AdminAccountException('Only an administrator.');

      await tester.pumpWidget(gateUnderTest(userId: rootAdmin.id));
      await tester.pumpAndSettle();

      expect(find.text('Only an administrator.'), findsOneWidget);

      // Recovering and reloading replaces the error with the roster.
      admin.listError = null;
      await tester.tap(find.byKey(const Key('admin-reload-accounts')));
      await tester.pumpAndSettle();

      expect(find.text('Only an administrator.'), findsNothing);
      expect(find.text('Aisha Bello'), findsOneWidget);
    });

    testWidgets('deleting an account requires confirmation and refreshes the roster',
        (tester) async {
      useDesktopSurface(tester);
      profiles.behaviour = () => Future<UserProfile>.value(rootAdmin);

      await tester.pumpWidget(gateUnderTest(userId: rootAdmin.id));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin-delete-$aishaId')));
      await tester.pumpAndSettle();
      expect(find.text('Delete Aisha Bello?'), findsOneWidget);
      expect(admin.deletedIds, isEmpty);

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();

      expect(admin.deletedIds, <String>[aishaId]);
      expect(find.text('Aisha Bello'), findsNothing);
      expect(find.textContaining('Deleted Aisha Bello'), findsOneWidget);
      await letSnackBarExpire(tester);
    });
  });
}

/// Stands in for `AdminUserRepositoryImpl`, so the admin dashboard can be driven
/// without an Edge Function, an auth server or a `profiles` table.
class _FakeAdminUserRepository implements AdminUserRepository {
  _FakeAdminUserRepository({List<ManagedAccount>? accounts})
    : accounts =
          accounts ??
          <ManagedAccount>[
            const ManagedAccount(
              id: '44444444-4444-4444-8444-444444444444',
              email: 'admin@proctor.test',
              fullName: 'Root Admin',
              role: UserRole.admin,
            ),
            const ManagedAccount(
              id: '22222222-2222-4222-8222-222222222222',
              email: 'aisha.bello@proctor.test',
              fullName: 'Aisha Bello',
              role: UserRole.student,
            ),
            const ManagedAccount(
              id: '33333333-3333-4333-8333-333333333333',
              email: 'manager@proctor.test',
              fullName: '',
              role: UserRole.supervisor,
            ),
          ];

  List<ManagedAccount> accounts;
  final List<(String, UserRole)> roleUpdates = <(String, UserRole)>[];
  int listCalls = 0;
  Object? listError;
  final List<String> deletedIds = <String>[];

  @override
  Future<ManagedAccount> createAccount({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
  }) async => ManagedAccount(
    id: 'new-${accounts.length}',
    email: email,
    fullName: fullName,
    role: role,
  );

  @override
  Future<List<ManagedAccount>> listAccounts() async {
    listCalls++;
    final failure = listError;
    if (failure != null) throw failure;
    return List<ManagedAccount>.of(accounts);
  }

  @override
  Future<void> updateRole({
    required String userId,
    required UserRole role,
  }) async {
    roleUpdates.add((userId, role));
  }

  @override
  Future<void> deleteAccount({required String userId}) async {
    deletedIds.add(userId);
    accounts.removeWhere((account) => account.id == userId);
  }
}

/// Stands in for `ProfileRepositoryImpl`: a swappable [behaviour] so a test can
/// answer with a value, a pending future, or a [ProfileLookupException].
class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({required UserProfile profile})
    : behaviour = (() => Future<UserProfile>.value(profile));

  Future<UserProfile> Function() behaviour;

  /// Last id passed in, so a test can prove the gate queried `profiles.id`.
  String? lastUserId;

  @override
  Future<UserProfile> getProfile(String userId) {
    lastUserId = userId;
    return behaviour();
  }
}

/// Stands in for `ExamRepositoryImpl`: published exams plus a submission per exam
/// id (absent = a fresh `ongoing` one is returned), with an injectable failure.
class _FakeExamRepository implements ExamRepository {
  _FakeExamRepository({this.exams = const <Exam>[]});

  List<Exam> exams;
  final Map<String, Submission> submissions = <String, Submission>{};
  Object? startError;
  int startCalls = 0;

  @override
  Future<List<Exam>> getPublishedExams() async => exams;

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) async {
    startCalls++;
    final failure = startError;
    if (failure != null) throw failure;

    return submissions[examId] ??
        Submission(
          id: 'sub-$examId',
          studentId: 'student-1',
          examId: examId,
          answers: const <String, dynamic>{},
          status: SubmissionStatus.ongoing,
        );
  }

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {}

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {}

  @override
  Future<void> submitExam(String submissionId) async {}

  @override
  Future<void> markDisqualified(String submissionId) async {}
}

const adaUserId = '11111111-1111-4111-8111-111111111111';
