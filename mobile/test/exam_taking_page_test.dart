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

/// The exam screen's *failure* paths.
///
/// It deliberately has no back button, so every way it can fail has to end
/// somewhere the student can leave from: a camera permission that is refused or
/// a camera that cannot be opened used to throw out of `_bootstrap()` and leave
/// the page on its loading spinner forever.
void main() {
  // The mock-messenger binding has to exist before `instance` is read.
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _StubExamRepository exams;

  Widget pageUnderTest() => ProviderScope(
        overrides: [
          examRepositoryProvider.overrideWithValue(exams),
          proctoringRepositoryProvider
              .overrideWithValue(_SilentProctoringRepository()),
        ],
        child: const MaterialApp(
          home: ExamTakingPage(examId: 'exam-1', submissionId: 'sub-1'),
        ),
      );

  setUp(() {
    exams = _StubExamRepository();

    // Neither channel has a plugin behind it in a test run, and inside the test
    // binding's fake-async zone a real platform reply never arrives — so both
    // are answered as "no implementation" (a null reply /
    // MissingPluginException), which is exactly the device-without-the-plugin
    // path under test.
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

  testWidgets('a session that cannot be proctored offers retry and leave',
      (tester) async {
    await tester.pumpWidget(pageUnderTest());
    await pumpBootstrap(tester);

    expectBlockingState();
  });

  testWidgets('retry re-runs the bootstrap and stays escapable',
      (tester) async {
    await tester.pumpWidget(pageUnderTest());
    await pumpBootstrap(tester);
    expectBlockingState();

    await tester.tap(find.byKey(const Key('exam-retry')));
    await pumpBootstrap(tester);

    // Still the blocking state (there is no camera in a test run) and still
    // escapable — a retry must not stack a second pin or lose the exit.
    expectBlockingState();
  });
}

/// One assertion describing the whole blocking state, so a failure says what
/// the page was showing instead of just "no widget with that key".
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

/// Returns no questions and never fails: the page gets past the repository as
/// far as the camera, which is where a VM test has to stop.
class _StubExamRepository implements ExamRepository {
  @override
  Future<List<Exam>> getPublishedExams() async => <Exam>[];

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError('not used by the exam session screen');

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {}

  @override
  Future<void> submitExam(String submissionId) async {}

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