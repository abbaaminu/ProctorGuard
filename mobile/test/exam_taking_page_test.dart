import 'package:exam_proctor/core/services/kiosk_service.dart';
import 'package:exam_proctor/features/exam/domain/entities/exam.dart';
import 'package:exam_proctor/features/exam/domain/entities/question.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/exam/domain/repositories/exam_repository.dart';
import 'package:exam_proctor/features/exam/presentation/pages/exam_taking_page.dart';
import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
import 'package:exam_proctor/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:exam_proctor/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exam session screen, in two halves:
///
///  * **blocking states** — it deliberately has no back button, so every way it
///    can fail (permission refused, camera unavailable, questions unreachable)
///    has to end somewhere the student can leave from. A denied camera used to
///    throw out of `_bootstrap()` and leave the page on its loading spinner.
///  * **questions** — numbering ("Question 2 of 2"), multiple-choice tap targets,
///    the fill-in-the-blank text field, and the rule that submitting flushes an
///    unsaved text answer first (grading reads the server copy).
///
/// The question half runs with `mockCamera: true`, which is the documented "no
/// camera here" path (emulators, desktop, CI) and keeps the camera plugin out of
/// the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const multipleChoice = Question(
    id: 'q-1',
    examId: 'exam-1',
    questionText: 'Which data structure is FIFO?',
    options: <String>['Stack', 'Queue', 'Tree'],
  );
  const fillInTheBlank = Question(
    id: 'q-2',
    examId: 'exam-1',
    questionText: 'What does the acronym HTTP stand for?',
    questionType: QuestionType.fillInTheBlank,
  );

  late _StubExamRepository exams;

  /// The session screen behind a launcher route, so submitting can actually pop
  /// back (popping the *root* route is not what production does).
  Widget pageUnderTest({bool mockCamera = true}) => ProviderScope(
        overrides: [
          examRepositoryProvider.overrideWithValue(exams),
          proctoringRepositoryProvider
              .overrideWithValue(_SilentProctoringRepository()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ExamTakingPage(
                        examId: 'exam-1',
                        submissionId: 'sub-1',
                        mockCamera: mockCamera,
                      ),
                    ),
                  ),
                  child: const Text('open exam'),
                ),
              ),
            ),
          ),
        ),
      );

  setUp(() {
    exams = _StubExamRepository(
      questions: const <Question>[multipleChoice, fillInTheBlank],
    );

    // Neither channel has a plugin behind it in a test run, and inside the test
    // binding's fake-async zone a real platform reply never arrives — so both are
    // answered as "no implementation" (a null reply / MissingPluginException),
    // which is exactly the device-without-the-plugin path.
    messenger.setMockMethodCallHandler(
      const MethodChannel(KioskService.channelName),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/camera'),
      (call) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel(KioskService.channelName),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/camera'),
      null,
    );
  });

  group('blocking states', () {
    testWidgets('a session that cannot be proctored offers retry and leave',
        (tester) async {
      await tester.pumpWidget(pageUnderTest(mockCamera: false));
      await tester.tap(find.text('open exam'));
      await pumpBootstrap(tester);

      expectBlockingState();
    });

    testWidgets('retry re-runs the bootstrap and stays escapable',
        (tester) async {
      await tester.pumpWidget(pageUnderTest(mockCamera: false));
      await tester.tap(find.text('open exam'));
      await pumpBootstrap(tester);
      expectBlockingState();

      await tester.tap(find.byKey(const Key('exam-retry')));
      await pumpBootstrap(tester);

      expectBlockingState();
    });
  });

  group('questions', () {
    testWidgets('numbers every question and saves a tapped option',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.byKey(const Key('option-1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('option-1')));
      await tester.pumpAndSettle();

      expect(exams.optionAnswers, <String>['q-1=1']);
      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('1 of 2 answered'), findsOneWidget);
    });

    testWidgets('renders a text field for fill-in-the-blank and saves it',
        (tester) async {
      exams = _StubExamRepository(
        questions: const <Question>[fillInTheBlank, multipleChoice],
      );

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.byKey(const Key('exam-text-answer')), findsOneWidget);
      // A typed question has no option tiles.
      expect(find.byKey(const Key('option-0')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('exam-text-answer')),
        'HyperText Transfer Protocol',
      );
      expect(find.textContaining('Not saved yet'), findsOneWidget);

      // Pressing "done" on the keyboard saves without leaving the question.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(exams.textAnswers, <String>['q-2=HyperText Transfer Protocol']);
      expect(find.text('Answer saved'), findsOneWidget);
      expect(find.text('Question 1 of 2'), findsOneWidget);

      // "Save & next" persists and advances.
      await tester.tap(find.byKey(const Key('exam-save-text')));
      await tester.pumpAndSettle();

      expect(exams.textAnswers.last, 'q-2=HyperText Transfer Protocol');
      expect(find.text('Question 2 of 2'), findsOneWidget);
      // The multiple-choice question shows tap targets, not a text field.
      expect(find.byKey(const Key('exam-text-answer')), findsNothing);
      expect(find.byKey(const Key('option-1')), findsOneWidget);
    });

    testWidgets('submitting flushes an unsaved text answer first',
        (tester) async {
      exams = _StubExamRepository(questions: const <Question>[fillInTheBlank]);

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // Typed but never saved: closing the attempt must send it anyway, because
      // grading reads the server copy.
      await tester.enterText(find.byKey(const Key('exam-text-answer')), 'HTTP');
      await tester.tap(find.byKey(const Key('exam-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Submit your exam?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('exam-submit-confirm')));
      await tester.pumpAndSettle();

      expect(exams.textAnswers, <String>['q-2=HTTP']);
      expect(exams.submitted, <String>['sub-1']);
      // Back on the launcher: the session screen closed itself.
      expect(find.text('open exam'), findsOneWidget);
    });

    testWidgets('fits a small phone viewport without overflowing',
        (tester) async {
      // 360x640 dp: a common small Android phone. The options used to sit in a
      // non-scrollable Column with a Spacer, so the action row was pushed off
      // the bottom edge as soon as a question had a few options.
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.byKey(const Key('option-2')), findsOneWidget);
      // A RenderFlex overflow surfaces as an exception here.
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a desktop browser viewport', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.byKey(const Key('option-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// One assertion describing the whole blocking state, so a failure says what the
/// page was showing instead of just "no widget with that key".
void expectBlockingState() {
  final spinner = find.byType(CircularProgressIndicator).evaluate().length;
  final retry = find.byKey(const Key('exam-retry')).evaluate().length;
  final leave = find.byKey(const Key('exam-leave')).evaluate().length;

  expect(
    spinner == 0 && retry == 1 && leave == 1,
    isTrue,
    reason: 'spinner=$spinner retry=$retry leave=$leave '
        'texts=[${visibleText()}]',
  );
}

/// Every label currently on screen, for self-explaining failures.
String visibleText() => find
    .byType(Text)
    .evaluate()
    .map((element) => (element.widget as Text).data)
    .whereType<String>()
    .join(' / ');

/// Pumps a bounded amount of fake time instead of `pumpAndSettle` (the spinner
/// schedules frames forever, so "settled" is not a state this page reaches while
/// it is still booting). The budget covers the kiosk command timeout and the two
/// permission status timeouts with room to spare.
Future<void> pumpBootstrap(WidgetTester tester) async {
  for (var i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Serves a fixed question list and records every answer write, so a test can
/// assert what the server was told — and in which order.
class _StubExamRepository implements ExamRepository {
  _StubExamRepository({this.questions = const <Question>[]});

  final List<Question> questions;
  final List<String> optionAnswers = <String>[];
  final List<String> textAnswers = <String>[];
  final List<String> submitted = <String>[];

  @override
  Future<List<Exam>> getPublishedExams() async => <Exam>[];

  @override
  Future<List<Question>> getQuestions(String examId) async => questions;

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError('not used by the exam session screen');

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {
    optionAnswers.add('$questionId=$selectedOption');
  }

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {
    textAnswers.add('$questionId=$answer');
  }

  @override
  Future<void> submitExam(String submissionId) async {
    submitted.add(submissionId);
  }

  @override
  Future<void> markDisqualified(String submissionId) async {}
}

/// Accepts violations without a backend (nothing in these tests reaches it).
class _SilentProctoringRepository implements ProctoringRepository {
  @override
  Future<({int warningCount, bool disqualified})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async =>
      (warningCount: 1, disqualified: false);

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}