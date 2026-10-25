import 'package:proctorguard/core/di/providers.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/pages/student_exam_portal_page.dart';
import 'package:proctorguard/features/exam/presentation/widgets/mobile_exam_only.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rule that keeps a proctored exam off a browser, in the two places it is
/// applied: the exam list (the call site that creates the attempt) and the
/// refusal screen/dialog themselves.
///
/// The rule matters because an attempt that runs in a browser is recorded as a
/// proctored one — the dashboard cannot tell them apart — while nothing on a
/// laptop can do the proctoring: no on-device face detector, no kiosk pin, no
/// second-display probe.
void main() {
  group('examRunsOnPlatform', () {
    test('refuses a browser and only a browser', () {
      // The default is the platform's own answer, not a constant: a VM test is
      // not a browser, so it inherits "yes".
      expect(examRunsOnPlatform(), isTrue);
      expect(examRunsOnPlatform(isWeb: false), isTrue);
      expect(examRunsOnPlatform(isWeb: true), isFalse);
    });
  });

  group('the refusal screen', () {
    testWidgets('says what happened, why, and what to do instead',
        (tester) async {
      var left = 0;

      await tester.pumpWidget(
        MaterialApp(home: MobileExamOnlyPage(onLeave: () => left++)),
      );

      expect(find.byKey(const Key('exam-mobile-only')), findsOneWidget);
      expect(find.text(examMobileOnlyTitle), findsOneWidget);
      expect(find.text(examMobileOnlyBody), findsOneWidget);
      expect(find.text(examMobileOnlyHint), findsOneWidget);
      // The sentence that keeps a student from believing they have been marked
      // absent, or that an attempt of theirs is open somewhere.
      expect(examMobileOnlyBody, contains('No attempt has been started here'));

      await tester.tap(find.text('Back to my exams'));
      expect(left, 1);
    });

    testWidgets('offers no way back when the route cannot pop', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MobileExamOnlyPage()));

      // A restored stack with nothing behind it: a "Back" button would pop the
      // app's only route out from under the student.
      expect(find.text('Back to my exams'), findsNothing);
      expect(find.text(examMobileOnlyTitle), findsOneWidget);
    });
  });

  group('the dialog', () {
    /// Opens the dialog the way the exam list does.
    Future<void> open(WidgetTester tester, {bool? isWeb}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () =>
                      showMobileExamOnlyDialog(context, isWeb: isWeb),
                  child: const Text('open exam'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
    }

    testWidgets('a phone is never interrupted by it', (tester) async {
      await open(tester, isWeb: false);

      // The same call on the platform the exam is meant for changes nothing on
      // screen, which is what makes it safe to call before every attempt.
      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsNothing);
    });

    testWidgets('a browser is told to use the phone app', (tester) async {
      await open(tester, isWeb: true);

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsOneWidget);
      expect(find.text(examMobileOnlyTitle), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsNothing);
    });
  });

  group('the exam list', () {
    late _RecordingExamRepository exams;

    setUp(() => exams = _RecordingExamRepository());

    Widget portal({bool? isWeb}) => ProviderScope(
          overrides: [examRepositoryProvider.overrideWithValue(exams)],
          child: MaterialApp(
            home: StudentExamPortalPage(
              isWeb: isWeb,
              // A session screen with a camera is `exam_taking_page_test.dart`'s
              // subject; this file only cares whether the attempt was created.
              examPageBuilder: (examId, submissionId) =>
                  const Scaffold(body: Text('session screen')),
              hardwareGate: (context, exam) async => true,
            ),
          ),
        );

    testWidgets('a browser is refused before an attempt row is created',
        (tester) async {
      await tester.pumpWidget(portal(isWeb: true));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsOneWidget);
      // The reason the refusal lives here and not only on the session screen: an
      // `ongoing` row for a browser would sit on the supervisor's dashboard for a
      // paper the student was then told to sit on their phone.
      expect(exams.started, isEmpty);
      expect(find.text('session screen'), findsNothing);
    });

    testWidgets('a phone starts the attempt as before', (tester) async {
      await tester.pumpWidget(portal(isWeb: false));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsNothing);
      expect(exams.started, <String>['exam-1']);
      expect(find.text('session screen'), findsOneWidget);
    });
  });
}

/// One published paper, and a record of every attempt the portal asked it to
/// create: the assertion this file needs is "the row was never written".
class _RecordingExamRepository implements ExamRepository {
  static const Exam paper = Exam(
    id: 'exam-1',
    title: 'CS101: Computer Science Fundamentals',
    createdBy: 'lecturer-1',
    durationMinutes: 60,
    isPublished: true,
  );

  final List<String> started = <String>[];

  @override
  Future<List<Exam>> getPublishedExams() async => const <Exam>[paper];

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) async {
    started.add(examId);
    return Submission(
      id: 'sub-1',
      studentId: 'student-1',
      examId: examId,
      answers: const <String, dynamic>{},
      status: SubmissionStatus.ongoing,
      startedAt: DateTime(2026, 10, 25, 9),
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
  Future<ExamSubmitResult> submitExam(String submissionId) async =>
      throw UnimplementedError('not reached');

  @override
  Future<void> markDisqualified(String submissionId) async {}
}
