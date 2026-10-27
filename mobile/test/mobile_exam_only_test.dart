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

/// The rule that decides where a proctored exam may be sat, in the two places it
/// is applied: the exam list (the call site that creates the attempt) and the
/// refusal screen/dialog themselves.
///
/// Three hosts, three answers. The Android app is the product. A desktop browser
/// (Windows, macOS, Linux) is a supported exam host: it has a real camera, the
/// browser guards and the shipped face detector, and the hardware gate says so
/// before the paper opens. A phone or tablet browser is refused — no kiosk pin, no
/// OS-level integrity probe, and a screen the student leaves with a gesture — and
/// an attempt started there would be recorded as proctored while being
/// unproctored in fact.
///
/// The user agents below are the ones the browsers actually send, not strings
/// invented to pass the rule.
const String iphoneSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 '
    'Safari/604.1';
const String androidChrome =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
const String ipadSafari =
    'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

/// An iPad in "desktop" mode: a Macintosh-looking agent, and multi-touch.
const String ipadDesktopSafari =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.5 Safari/605.1.15';
const String windowsChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/126.0.0.0 Safari/537.36';
const String macOSChrome =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, '
    'like Gecko) Chrome/126.0.0.0 Safari/537.36';
const String linuxFirefox =
    'Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0';

void main() {
  group('examRunsOnPlatform', () {
    test('the app itself always sits the exam', () {
      // The default is the platform's own answer, not a constant: a VM test is
      // not a browser, so it inherits "yes".
      expect(examRunsOnPlatform(), isTrue);
      expect(examRunsOnPlatform(isWeb: false), isTrue);
    });

    test('a desktop browser sits it too', () {
      for (final agent in <String>[windowsChrome, macOSChrome, linuxFirefox]) {
        expect(
          examRunsOnPlatform(isWeb: true, userAgent: agent),
          isTrue,
          reason: 'a computer is where a student without an Android phone sits '
              'the paper',
        );
      }
    });

    test('a phone or tablet browser is refused', () {
      for (final agent in <String>[iphoneSafari, androidChrome, ipadSafari]) {
        expect(
          examRunsOnPlatform(isWeb: true, userAgent: agent),
          isFalse,
          reason: 'nothing about a touch-sized browser can be proctored',
        );
      }
    });

    test('an iPad in desktop mode is still a tablet', () {
      // Safari on iPadOS can present a Macintosh agent and a landscape viewport;
      // the multi-touch count is what separates the tablet from the laptop.
      expect(
        examRunsOnPlatform(
          isWeb: true,
          userAgent: ipadDesktopSafari,
          browserPlatform: 'MacIntel',
          maxTouchPoints: 5,
        ),
        isFalse,
      );
      // The same agent on the same platform with a mouse attached is a Mac.
      expect(
        examRunsOnPlatform(
          isWeb: true,
          userAgent: ipadDesktopSafari,
          browserPlatform: 'MacIntel',
          maxTouchPoints: 0,
        ),
        isTrue,
      );
    });

    test('a browser that says nothing about itself is allowed', () {
      // An empty agent is not evidence of a phone, and the exam rule does not look
      // at the window: the 768 px limit belongs to the administrative console
      // (`blocksWebVisit`), and a desktop browser dragged narrow is still a
      // desktop. Only the app-wide guard may refuse on width.
      expect(examRunsOnPlatform(isWeb: true), isTrue);
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
      // One way out, and it is the way the rule allows: the app, or a computer.
      expect(examMobileOnlyHint, contains('Android'));
      expect(examMobileOnlyHint, contains('desktop browser'));

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
    Future<void> open(
      WidgetTester tester, {
      bool? isWeb,
      String? userAgent,
      String? browserPlatform,
      int? maxTouchPoints,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showMobileExamOnlyDialog(
                    context,
                    isWeb: isWeb,
                    userAgent: userAgent,
                    browserPlatform: browserPlatform,
                    maxTouchPoints: maxTouchPoints,
                  ),
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

    testWidgets('the app is never interrupted by it', (tester) async {
      await open(tester, isWeb: false);

      // The same call on the platform the exam is meant for changes nothing on
      // screen, which is what makes it safe to call before every attempt.
      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsNothing);
    });

    testWidgets('a desktop browser is never interrupted by it', (tester) async {
      await open(tester, isWeb: true, userAgent: windowsChrome);

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsNothing);
    });

    testWidgets('a phone browser is told to use the app', (tester) async {
      await open(tester, isWeb: true, userAgent: androidChrome);

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

    Widget portal({
      bool? isWeb,
      String? userAgent,
      String? browserPlatform,
      int? maxTouchPoints,
    }) =>
        ProviderScope(
          overrides: [examRepositoryProvider.overrideWithValue(exams)],
          child: MaterialApp(
            home: StudentExamPortalPage(
              isWeb: isWeb,
              browserUserAgent: userAgent,
              browserPlatform: browserPlatform,
              maxTouchPoints: maxTouchPoints,
              // A session screen with a camera is `exam_taking_page_test.dart`'s
              // subject; this file only cares whether the attempt was created.
              examPageBuilder: (examId, submissionId) =>
                  const Scaffold(body: Text('session screen')),
              hardwareGate: (context, exam) async => true,
            ),
          ),
        );

    testWidgets('a phone browser is refused before an attempt row is created',
        (tester) async {
      await tester.pumpWidget(portal(isWeb: true, userAgent: iphoneSafari));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsOneWidget);
      // The reason the refusal lives here and not only on the session screen: an
      // `ongoing` row for that browser would sit on the supervisor's dashboard for
      // a paper the student was then told to sit in the app.
      expect(exams.started, isEmpty);
      expect(find.text('session screen'), findsNothing);
    });

    testWidgets('a desktop browser starts the attempt', (tester) async {
      await tester.pumpWidget(portal(isWeb: true, userAgent: windowsChrome));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only-dialog')), findsNothing);
      expect(exams.started, <String>['exam-1']);
      expect(find.text('session screen'), findsOneWidget);
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
