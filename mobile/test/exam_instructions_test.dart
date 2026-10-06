import 'package:proctorguard/core/services/hardware_verification_service.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/pages/exam_hardware_gate_page.dart';
import 'package:proctorguard/features/exam/presentation/pages/student_exam_portal_page.dart';
import 'package:proctorguard/features/exam/presentation/widgets/exam_instructions_dialog.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pre-exam instructions: what the dialog says, and that both of the screens
/// a student stands on *before* a session actually offer it.
///
/// The value of the feature is entirely in that second half — a rule explained
/// on a screen nothing links to is a rule nobody reads — so the wiring is pinned
/// here next to the copy.
void main() {
  // Plugin channels (camera, permission_handler) need a binding even when the
  // test never reaches them: the gate builds its verifier on the first frame.
  TestWidgetsFlutterBinding.ensureInitialized();

  const exam = Exam(
    id: 'exam-1',
    title: 'CS101: Computer Science Fundamentals',
    createdBy: 'lecturer-1',
    durationMinutes: 60,
    isPublished: true,
  );

  /// Opens the dialog from a button, so the test exercises the same call the two
  /// real screens make rather than constructing the widget by hand.
  Future<void> openDialog(WidgetTester tester, {Exam? paper}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showExamInstructions(context, exam: paper),
                child: const Text('open instructions'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open instructions'));
    await tester.pumpAndSettle();
  }

  group('the instructions dialog', () {
    testWidgets('opens on the proctor guide, with the exam rules one tab away',
        (tester) async {
      await openDialog(tester);

      expect(find.byKey(const Key('exam-instructions-dialog')), findsOneWidget);
      // Both halves are visible as tabs, so a student knows the marking rule is
      // in here before they go looking for it.
      expect(find.byKey(const Key('instructions-tab-proctor')), findsOneWidget);
      expect(find.byKey(const Key('instructions-tab-exam')), findsOneWidget);

      // The proctor half starts first: it describes what is about to start.
      expect(find.text('Your camera stays on'), findsOneWidget);
      expect(find.text('Your microphone stays on'), findsOneWidget);
    });

    testWidgets('the proctor tab names the camera, the noise floor and the kiosk',
        (tester) async {
      await openDialog(tester);

      // The three proctoring surfaces, each explained in the student's terms:
      // face detection on the device, audio above the room's own floor, and the
      // browser/kiosk rules that decide what an interruption is.
      expect(find.textContaining('snapshot is kept with any incident'),
          findsOneWidget);
      expect(find.textContaining("above the room's own level"), findsOneWidget);

      // The tab scrolls — four rules do not fit a phone-sized dialog — so the
      // kiosk rule is reached the way a student reaches it.
      await tester.scrollUntilVisible(
        find.textContaining('the screen is pinned'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.textContaining('the screen is pinned'), findsOneWidget);
    });

    testWidgets('the exam-rules tab answers when a mark appears', (tester) async {
      await openDialog(tester);

      await tester.tap(find.byKey(const Key('instructions-tab-exam')));
      await tester.pumpAndSettle();

      // The instant-result rule and its exception in one place: an objective
      // paper is final on submit, an essay paper waits for the lecturer.
      expect(find.text('The clock starts when you do'), findsOneWidget);
      expect(find.text('When you see your mark'), findsOneWidget);
      expect(
        find.textContaining('marked the instant you submit'),
        findsOneWidget,
      );
      expect(
        find.textContaining('your lecturer reads and marks those answers'),
        findsOneWidget,
      );
    });

    testWidgets("a paper's title heads the dialog when there is one",
        (tester) async {
      await openDialog(tester, paper: exam);

      expect(
        find.text('Before you start: CS101: Computer Science Fundamentals'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('exam-instructions-done')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exam-instructions-dialog')), findsNothing);
    });
  });

  group('both pre-exam screens offer the rules', () {
    testWidgets('the device check does, without leaving the checklist',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ExamHardwareGatePage(exam: exam, verifier: _VerifiedHardware()),
        ),
      );
      await tester.pumpAndSettle();

      // The button sits below the checklist on a phone-sized viewport.
      final button = find.byKey(const Key('gate-instructions'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-instructions-dialog')), findsOneWidget);
      expect(
        find.text('Before you start: CS101: Computer Science Fundamentals'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('exam-instructions-done')));
      await tester.pumpAndSettle();

      // Dismissing it leaves the gate exactly as it was: the check is still
      // passed, so "Start Exam" is still the next thing to do.
      expect(find.byKey(const Key('exam-instructions-dialog')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('gate-start-exam')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('the portal does, before any paper is chosen', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            examRepositoryProvider.overrideWithValue(_EmptyExamRepository()),
          ],
          child: const MaterialApp(
            home: StudentExamPortalPage(studentName: 'Aisha Bello'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('portal-instructions')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-instructions-dialog')), findsOneWidget);
      // No paper picked yet, so the title does not name one.
      expect(find.text('Before you start'), findsOneWidget);
    });
  });
}

/// A device probe that always reports both devices verified: the gate's own
/// checklist is `hardware_gate_test.dart`'s subject, and this file only needs to
/// get past it to reach the instructions button.
class _VerifiedHardware implements HardwareVerifier {
  @override
  Future<HardwareReport> verify() async => const HardwareReport(
        camera: DeviceProbe.verified(ProbeDevice.camera, message: 'Streaming.'),
        microphone:
            DeviceProbe.verified(ProbeDevice.microphone, message: 'Open.'),
      );

  @override
  Future<void> openSettings() async {}
}

/// An exam repository with nothing published: the portal's list is not this
/// file's subject, and an empty one keeps the app bar — where the instructions
/// button lives — in its normal state.
class _EmptyExamRepository implements ExamRepository {
  @override
  Future<List<Exam>> getPublishedExams() async => <Exam>[];

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) async =>
      throw UnimplementedError('not reached');

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async =>
      throw UnimplementedError('not reached');

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async =>
      throw UnimplementedError('not reached');

  @override
  Future<ExamSubmitResult> submitExam(String submissionId) async =>
      throw UnimplementedError('not reached');

  @override
  Future<void> markDisqualified(String submissionId) async =>
      throw UnimplementedError('not reached');
}
