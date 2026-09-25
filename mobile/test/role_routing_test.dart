import 'dart:async';

import 'package:exam_proctor/core/services/supabase_service.dart';
import 'package:exam_proctor/features/auth/domain/entities/user_profile.dart';
import 'package:exam_proctor/features/auth/domain/repositories/profile_repository.dart';
import 'package:exam_proctor/features/auth/presentation/providers/profile_provider.dart';
import 'package:exam_proctor/features/auth/presentation/widgets/role_gate.dart';
import 'package:exam_proctor/features/exam/domain/entities/exam.dart';
import 'package:exam_proctor/features/exam/domain/entities/question.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/exam/domain/repositories/exam_repository.dart';
import 'package:exam_proctor/features/exam/presentation/pages/student_exam_portal_page.dart';
import 'package:exam_proctor/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Post-login routing: `users.role` decides between the student portal and the
/// supervisor console, with the loading and failure states around it.
///
/// Everything is injected (auth stream, user id, repositories, sign-out), so no
/// Supabase project, no camera and no platform channel is involved.
void main() {
  // Ids straight out of supabase/seed.sql.
  const aishaId = '22222222-2222-4222-8222-222222222222';
  const aisha = UserProfile(
    id: aishaId,
    role: UserRole.student,
    name: 'Aisha Bello',
    email: 'aisha.bello@proctor.test',
  );
  const ada = UserProfile(
    id: '11111111-1111-4111-8111-111111111111',
    role: UserRole.supervisor,
    name: 'Dr. Ada Nwosu',
    email: 'supervisor@proctor.test',
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

  Widget gateUnderTest({
    String userId = aishaId,
    Future<AuthOutcome> Function()? signOut,
  }) =>
      ProviderScope(
        overrides: [
          profileRepositoryProvider.overrideWithValue(profiles),
          examRepositoryProvider.overrideWithValue(exams),
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
  });

  group('users.role parsing', () {
    test('maps the two allowed values', () {
      expect(UserRole.fromDb('student'), UserRole.student);
      expect(UserRole.fromDb('supervisor'), UserRole.supervisor);
      expect(UserRole.student.dbValue, 'student');
    });

    test('rejects an unknown role instead of guessing', () {
      expect(() => UserRole.fromDb('admin'), throwsArgumentError);
    });

    test('falls back to the email when the row has no name', () {
      final profile = UserProfile.fromMap(<String, dynamic>{
        'id': aishaId,
        'role': 'student',
        'name': '   ',
        'email': 'aisha.bello@proctor.test',
      });
      expect(profile.displayName, 'aisha.bello@proctor.test');
      expect(profile.isStudent, isTrue);
    });
  });

  /// The portal on its own, with a stub session screen so the routing contract
  /// can be asserted without a camera.
  Widget portal({required ExamPageBuilder builder, String? name = 'Aisha Bello'}) =>
      ProviderScope(
        overrides: [
          profileRepositoryProvider.overrideWithValue(profiles),
          examRepositoryProvider.overrideWithValue(exams),
        ],
        child: MaterialApp(
          home: StudentExamPortalPage(
            studentName: name,
            examPageBuilder: builder,
          ),
        ),
      );

  Future<void> letSnackBarExpire(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(seconds: 7));

  group('student role', () {
    testWidgets('lands on the Student Exam Portal with the published exams',
        (tester) async {
      await tester.pumpWidget(gateUnderTest());
      await tester.pumpAndSettle();

      expect(find.text('Student Exam Portal'), findsOneWidget);
      expect(find.textContaining('Welcome, Aisha Bello'), findsOneWidget);
      expect(find.text('CS101: Computer Science Fundamentals'), findsOneWidget);
      expect(find.text('MAT201: Calculus Quiz'), findsOneWidget);
      expect(find.text('60 minutes'), findsOneWidget);
      expect(find.text('45 minutes'), findsOneWidget);
      expect(profiles.lastUserId, aishaId,
          reason: 'the role came from users.id = auth uid');
    });

    testWidgets('an ongoing attempt opens the session with both ids',
        (tester) async {
      exams.submissions[mat201Id] = const Submission(
        id: 'sub-mat',
        studentId: aishaId,
        examId: mat201Id,
        answers: <String, dynamic>{},
        status: SubmissionStatus.ongoing,
      );
      (String, String)? pushed;

      await tester.pumpWidget(portal(
        builder: (examId, submissionId) {
          pushed = (examId, submissionId);
          return const Scaffold(body: Text('session placeholder'));
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$mat201Id')));
      await tester.pumpAndSettle();

      expect(pushed, (mat201Id, 'sub-mat'));
      expect(find.text('session placeholder'), findsOneWidget);
      expect(exams.startCalls, 1);
    });

    testWidgets('a disqualified attempt is reported, not reopened',
        (tester) async {
      exams.submissions[cs101Id] = const Submission(
        id: 'sub-cs',
        studentId: aishaId,
        examId: cs101Id,
        answers: <String, dynamic>{},
        status: SubmissionStatus.disqualified,
      );
      var opened = 0;

      await tester.pumpWidget(portal(
        builder: (_, _) {
          opened++;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$cs101Id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('was disqualified'), findsOneWidget);
      expect(opened, 0, reason: 'the server owns that state');
      await letSnackBarExpire(tester);
    });

    testWidgets('a failed submission start is surfaced, not swallowed',
        (tester) async {
      exams.startError = Exception('offline');
      var opened = 0;

      await tester.pumpWidget(portal(
        builder: (_, _) {
          opened++;
          return const SizedBox.shrink();
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-$mat201Id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('Could not start'), findsOneWidget);
      expect(opened, 0);
      await letSnackBarExpire(tester);
    });
  });

  group('loading and failure', () {
    testWidgets('a spinner shows while the profile is being read',
        (tester) async {
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

      // Backend recovers -> retry re-reads users instead of showing the old error.
      profiles.behaviour = () => Future<UserProfile>.value(aisha);
      await tester.tap(find.byKey(const Key('profile-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Student Exam Portal'), findsOneWidget);
    });

    testWidgets('the error state offers a sign-out that reports failures',
        (tester) async {
      profiles.behaviour = () =>
          Future<UserProfile>.error(const ProfileLookupException('no row'));

      await tester.pumpWidget(gateUnderTest(
        signOut: () async => const AuthOutcome.failure('Network down'),
      ));
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
    });
  });

}

/// Stands in for `ProfileRepositoryImpl`: a swappable [behaviour] so a test can
/// answer with a value, a pending future, or a [ProfileLookupException].
class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository({required UserProfile profile})
      : behaviour = (() => Future<UserProfile>.value(profile));

  Future<UserProfile> Function() behaviour;

  /// Last id passed in, so a test can prove the gate queried `users.id`.
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
