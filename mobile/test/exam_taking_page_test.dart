import 'dart:async';
import 'dart:convert';

import 'package:proctorguard/core/services/audio_monitor.dart';
import 'package:proctorguard/core/services/key_value_store.dart';
import 'package:proctorguard/core/services/kiosk_service.dart';
import 'package:proctorguard/core/services/web_guards.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/pages/exam_taking_page.dart';
import 'package:proctorguard/features/exam/presentation/widgets/exam_session_widgets.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/audio_monitoring_provider.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exam session screen, in three parts:
///
///  * **blocking states** — it deliberately has no back button, so every way it
///    can fail (permission refused, camera unavailable, questions unreachable)
///    has to end somewhere the student can leave from. A denied camera used to
///    throw out of `_bootstrap()` and leave the page on its loading spinner.
///  * **questions** — numbering ("Question 2 of 2"), multiple-choice tap targets,
///    the fill-in-the-blank text field, the rule that submitting flushes an
///    unsaved text answer first (grading reads the server copy), and an action
///    bar that holds three controls (mark for review + Previous + Next) on a
///    360 dp phone without overflowing.
///  * **audio proctoring** — the microphone chip, and the rule that a blocked or
///    unplugged microphone is a visible, answerable prompt rather than a silent
///    gap in proctoring.
///  * **review marker and candidate identity** — flagging a question for review
///    (local-only, per question, warned about at submit) and the header that says
///    who is sitting the exam, which is derived from the name because `profiles`
///    carries no photo or matric number to show instead.
///
/// The question half runs with `mockCamera: true`, which is the documented "no
/// camera here" path (emulators, desktop, CI) and keeps the camera plugin out of
/// the test. The microphone is always injected ([_FakeAudioSource]) for the same
/// reason: a Dart VM test has no audio plugin, and this screen opens a capture
/// session as part of its bootstrap.
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
  const trueFalse = Question(
    id: 'q-tf',
    examId: 'exam-1',
    questionText: 'A pull request may be merged before its checks pass.',
    questionType: QuestionType.trueFalse,
  );
  const subjective = Question(
    id: 'q-essay',
    examId: 'exam-1',
    questionText: 'Describe how you would review a change to authentication.',
    questionType: QuestionType.subjective,
  );

  late _StubExamRepository exams;
  late _SilentProctoringRepository proctoring;
  late InMemoryKeyValueStore store;

  /// The session screen behind a launcher route, so submitting can actually pop
  /// back (popping the *root* route is not what production does).
  Widget pageUnderTest({
    bool mockCamera = true,
    WebGuards? webGuards,
    DateTime Function()? clock,
    AudioLevelSource? audioSource,
    String? candidateName,
    String? examTitle,
    String? candidateEmail,
  }) =>
      ProviderScope(
        overrides: [
          examRepositoryProvider.overrideWithValue(exams),
          proctoringRepositoryProvider.overrideWithValue(proctoring),
          // In memory, so a test decides exactly what is already "on the device"
          // (see the resume test) and so the offline queue never touches a real
          // SharedPreferences, which a VM test binding has no plugin for.
          keyValueStoreProvider.overrideWithValue(store),
          // The microphone has no plugin behind it on the Dart VM, and this screen
          // starts a capture session as part of its bootstrap
          // (`_startAudioMonitoring`), so the source is injected the same way the
          // browser guards are: each test states what the microphone does rather
          // than inheriting "unavailable" from a missing plugin.
          audioLevelSourceProvider.overrideWithValue(
            audioSource ?? _FakeAudioSource(),
          ),
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
                        webGuards: webGuards,
                        clock: clock,
                        candidateName: candidateName,
                        examTitle: examTitle,
                        candidateEmail: candidateEmail,
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
    proctoring = _SilentProctoringRepository();
    store = InMemoryKeyValueStore();

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

  group('offline resilience (requirement 1)', () {
    /// Bounded pumps instead of `pumpAndSettle`: while the queue has work and the
    /// network is down, a retry loop is *supposed* to keep running, so "settled" is
    /// not a state this screen reaches (and a dead connection must not be able to
    /// spin a test, or a device, forever).
    Future<void> pumpNetwork(WidgetTester tester, Duration time) async {
      await tester.pump();
      await tester.pump(time);
      await tester.pump();
    }

    testWidgets('an offline save is kept, announced, and synced on recovery',
        (tester) async {
      exams.online = false;

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('option-1')));
      await pumpNetwork(tester, const Duration(milliseconds: 100));

      // The answer is on the device, so the session carries on...
      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('1 of 2 answered'), findsOneWidget);
      // ...the student is told exactly where it is...
      expect(find.byKey(const Key('exam-sync-banner')), findsOneWidget);
      expect(find.textContaining('Offline - syncing locally'), findsOneWidget);
      // ...and the server was never reached.
      expect(exams.optionAnswers, isEmpty);

      // The connection comes back: the queue drains itself, with no user action.
      exams.online = true;
      await pumpNetwork(tester, const Duration(seconds: 3));

      expect(exams.optionAnswers, <String>['q-1=1']);
      expect(find.byKey(const Key('exam-sync-banner')), findsNothing);
    });

    testWidgets('a typed answer survives the trip and the queue',
        (tester) async {
      // Two questions, so the text one is not the last: "Save & next" only exists
      // while there is somewhere to advance to.
      exams = _StubExamRepository(
        questions: const <Question>[fillInTheBlank, multipleChoice],
        online: false,
      );

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('exam-text-answer')), 'HTTP');
      await tester.tap(find.byKey(const Key('exam-save-text')));
      await pumpNetwork(tester, const Duration(milliseconds: 100));

      expect(exams.textAnswers, isEmpty);
      expect(find.textContaining('Offline - syncing locally'), findsOneWidget);

      exams.online = true;
      await pumpNetwork(tester, const Duration(seconds: 3));

      expect(exams.textAnswers, <String>['q-2=HTTP']);
    });

    testWidgets('a resumed attempt paints what the device already holds',
        (tester) async {
      // What a previous (killed) session left behind: the drafts, plus the queue
      // row that says the server still owes the student an answer.
      store = InMemoryKeyValueStore(values: <String, String>{
        'draft.choices': jsonEncode(<String, dynamic>{
          'sub-1': <String, dynamic>{'q-1': 2},
        }),
        'draft.text': jsonEncode(<String, dynamic>{
          'sub-1': <String, dynamic>{'q-2': 'HyperText Transfer Protocol'},
        }),
      });

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // Both shapes come back from the device, and the "answered" counter knows
      // it before the server is asked anything.
      expect(find.text('2 of 2 answered'), findsOneWidget);
      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('exam-text-answer')),
      );
      expect(field.controller?.text, 'HyperText Transfer Protocol');
      expect(find.text('Answer saved'), findsOneWidget);
    });
  });

  group('fullscreen enforcement (requirement 3)', () {
    late _FakeWebGuards guards;
    late DateTime now;

    setUp(() {
      guards = _FakeWebGuards();
      now = DateTime.utc(2026, 6, 1, 9);
    });

    /// Opens the session and moves the clock past the guards' 5s start-up grace,
    /// so an emitted fullscreen exit is a real event rather than start-up noise.
    ///
    /// The clock has to be moved by hand: a widget test advances *fake* time, and
    /// the guard's grace window reads the wall clock (the same clock a real exam
    /// uses to decide that two minutes in the background is not a start-up blip).
    Future<void> openPastStartupGrace(WidgetTester tester) async {
      await tester.pumpWidget(
        pageUnderTest(webGuards: guards, clock: () => now),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 6));
      await tester.pump();
    }

    testWidgets('leaving fullscreen counts down instead of logging at once',
        (tester) async {
      await openPastStartupGrace(tester);
      expect(find.text('Fullscreen required'), findsNothing);

      guards.emit(WebGuardEvent.fullscreenExited);
      await tester.pump();
      await tester.pump();

      // Blocking overlay with the countdown, and no strike yet.
      expect(find.text('Fullscreen required'), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-countdown')), findsOneWidget);
      expect(find.byKey(const Key('fullscreen-return')), findsOneWidget);
      expect(proctoring.violations, isEmpty);

      // Coming back inside the window (what the button or the browser does) is
      // not a violation.
      guards.emit(WebGuardEvent.fullscreenEntered);
      await tester.pump();
      await tester.pump();

      expect(find.text('Fullscreen required'), findsNothing);
      expect(proctoring.violations, isEmpty);
    });

    testWidgets('staying out of fullscreen costs exactly one strike',
        (tester) async {
      await openPastStartupGrace(tester);

      guards.emit(WebGuardEvent.fullscreenExited);
      await tester.pump();
      expect(proctoring.violations, isEmpty);

      // Past the 5s window: the visible countdown reaches zero and the page hands
      // the expired window to the guard, which logs the strike once.
      now = now.add(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(proctoring.violations.single.type.dbValue, 'app_minimized');
      expect(find.text('Warning 1 / 3'), findsOneWidget);
      expect(find.text('Fullscreen required'), findsNothing);
    });
  });

  group('browser lockdown (requirement 4)', () {
    late _FakeWebGuards guards;

    setUp(() => guards = _FakeWebGuards());

    Future<void> openSession(WidgetTester tester) async {
      await tester.pumpWidget(pageUnderTest(webGuards: guards));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
    }

    testWidgets('the attempt runs with the DOM lockdown armed', (tester) async {
      await openSession(tester);

      expect(guards.lockdownActive, isTrue);
      expect(guards.lockdownStarts, 1);

      // Leaving the session has to release it: a student whose exam ended (or
      // whose bootstrap failed) must get their browser back.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(guards.lockdownStops, 1);
      expect(guards.lockdownActive, isFalse);
    });

    testWidgets('a blocked copy is logged as copy_paste_attempt',
        (tester) async {
      await openSession(tester);

      guards.emit(WebGuardEvent.copyBlocked);
      await tester.pump();
      await tester.pump();

      expect(proctoring.violations.single.type.dbValue, 'copy_paste_attempt');
      expect(find.text('Warning 1 / 3'), findsOneWidget);
    });

    testWidgets('a suppressed menu and a devtools panel are separate strikes',
        (tester) async {
      await openSession(tester);

      guards.emit(WebGuardEvent.contextMenuBlocked);
      await tester.pump();
      await tester.pump();
      guards.emit(WebGuardEvent.devtoolsDetected);
      await tester.pump();
      await tester.pump();

      expect(
        proctoring.violations.map((violation) => violation.type.dbValue),
        <String>['right_click_blocked', 'devtools_detected'],
      );
      expect(find.text('Warning 2 / 3'), findsOneWidget);
    });

    testWidgets('a log the server refuses cannot hold the attempt open',
        (tester) async {
      proctoring.online = false; // evidence is refused, the answers are not
      await openSession(tester);

      // A strike the server will not take: it goes to the durable queue instead
      // of being lost, and the banner says so.
      guards.emit(WebGuardEvent.copyBlocked);
      await tester.pump();
      await tester.pump();

      expect(proctoring.violations, isEmpty);
      expect(find.byKey(const Key('exam-sync-banner')), findsOneWidget);

      // The strike is announced over the session, so acknowledge it first: the
      // overlay is modal on purpose (a warning has to be seen). Any message the
      // page put behind it (a SnackBar) shares the bottom of the screen with the
      // action bar, so it is cleared too.
      await tester.tap(find.text('I understand, continue'));
      await tester.pumpAndSettle();
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).last),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();

      // Submitting is about the *answers*: they are the copy grading reads, and
      // they have all reached the server. The queued strike still counts after
      // the attempt closes (`register_violation` takes the final state of a
      // closed attempt), so it is no reason to strand a finished student on a
      // "waiting for a connection" screen. (Submit lives on the last question.)
      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit-confirm')));
      await tester.pumpAndSettle();

      expect(exams.submitted, <String>['sub-1']);
      expect(find.byKey(const Key('exam-offline-submit')), findsNothing);

      // And the evidence was only late, never dropped: the backoff delivers it
      // once the server is taking writes again. A minute is past `maxRetryDelay`,
      // so whatever delay the failed passes had backed off to has elapsed.
      proctoring.online = true;
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      expect(
        proctoring.violations.map((violation) => violation.type.dbValue),
        contains('copy_paste_attempt'),
      );
    });
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

    testWidgets('Next and Previous move between questions without scrolling',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // First question: Next is available, and Previous is on screen but inert -
      // the way back is visible from the first question, it is just not usable
      // until there is somewhere to go.
      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(find.byKey(const Key('exam-next')), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('exam-previous')))
            .onPressed,
        isNull,
        reason: 'no previous question to go to yet',
      );

      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();

      expect(find.text('Question 2 of 2'), findsOneWidget);
      // Last question replaces Next with Submit, and offers Previous.
      expect(find.byKey(const Key('exam-next')), findsNothing);
      expect(find.byKey(const Key('exam-submit')), findsOneWidget);
      expect(find.byKey(const Key('exam-previous')), findsOneWidget);

      await tester.tap(find.byKey(const Key('exam-previous')));
      await tester.pumpAndSettle();

      expect(find.text('Question 1 of 2'), findsOneWidget);
    });

    testWidgets('the review grid marks answered and unattempted questions',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // Nothing answered yet: one tile per question, both in the neutral state,
      // and the summary says how much is left.
      expect(find.byKey(const Key('exam-palette')), findsOneWidget);
      expect(find.byKey(const Key('exam-palette-0')), findsOneWidget);
      expect(find.byKey(const Key('exam-palette-1')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('exam-palette-summary'))).data,
        '0 answered • 2 not answered',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('exam-palette-0')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
        reason: 'an unattempted question carries no completed marker',
      );
      // The legend spells the two states out rather than leaving them to colour.
      expect(find.text('Answered'), findsOneWidget);
      expect(find.text('Not answered'), findsOneWidget);

      // Answering question 1 (a tap saves *and* advances) flips its tile to the
      // completed state.
      await tester.tap(find.byKey(const Key('option-1')));
      await tester.pumpAndSettle();
      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('exam-palette-summary'))).data,
        '1 answered • 1 not answered',
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('exam-palette-0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('exam-palette-1')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );

      // And the grid navigates: tapping question 1 goes back to it.
      await tester.tap(find.byKey(const Key('exam-palette-0')));
      await tester.pumpAndSettle();
      expect(find.text('Question 1 of 2'), findsOneWidget);
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

    testWidgets('a true/false statement is two taps, and the word is stored',
        (tester) async {
      exams = _StubExamRepository(
        questions: const <Question>[trueFalse, fillInTheBlank],
      );

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('True'), findsOneWidget);
      expect(find.text('False'), findsOneWidget);
      // A tapped statement is not a typed one.
      expect(find.byKey(const Key('exam-text-answer')), findsNothing);

      // The two statements sit below the palette and the question on a phone, so
      // the tap has to be brought into view first (as a student would scroll).
      await tester.ensureVisible(find.byKey(const Key('exam-answer-false')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-answer-false')));
      await tester.pumpAndSettle();

      // The *word* travels, not an option index: `submit_exam()` compares it
      // (case-insensitively) with the row's `correct_text_answer`.
      expect(exams.textAnswers, <String>['q-tf=false']);
      expect(exams.optionAnswers, isEmpty);
      // And it advances like a multiple-choice tap.
      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('1 of 2 answered'), findsOneWidget);
    });

    testWidgets(
        'an essay is typed into its own box and saved through the queue',
        (tester) async {
      exams = _StubExamRepository(
        questions: const <Question>[subjective, multipleChoice],
      );

      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-essay-answer')), findsOneWidget);
      // The screen says what happens to an essay, because nothing here scores it.
      expect(
        find.textContaining('nothing is scored as you type'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('exam-essay-answer')),
        'I would read the diff for anything that stores or compares a secret.',
      );
      await tester.tap(find.byKey(const Key('exam-save-text')));
      await tester.pumpAndSettle();

      expect(exams.textAnswers, <String>[
        'q-essay=I would read the diff for anything that stores or compares a '
            'secret.',
      ]);
      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('1 of 2 answered'), findsOneWidget);
      // The essay's own field is gone with its question: no leaked text box.
      expect(find.byKey(const Key('exam-essay-answer')), findsNothing);
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
      // The bar holds three controls (mark toggle + Previous + Next), and the
      // labels give before the row does: the nav pair stays ordered and inside
      // the viewport instead of ending in a stripe of overflow.
      final toggle = tester.getRect(find.byKey(const Key('exam-mark-review')));
      final previous = tester.getRect(find.byKey(const Key('exam-previous')));
      final next = tester.getRect(find.byKey(const Key('exam-next')));
      expect(previous.left, greaterThanOrEqualTo(toggle.right));
      expect(next.left, greaterThanOrEqualTo(previous.right));
      expect(next.right, lessThanOrEqualTo(360));
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

  group('review marker and candidate identity', () {
    testWidgets(
        'a mark for review shows in the grid, the legend and the toggle',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // The palette legend documents all three tile states whether or not a
      // question is in them (that is its job: it is the key, not a status line),
      // so the proof that nothing is marked is in the tiles themselves: neither
      // one carries the flag yet.
      expect(find.text('Marked for review'), findsOneWidget);
      for (final index in [0, 1]) {
        expect(
          find.descendant(
            of: find.byKey(Key('exam-palette-$index')),
            matching: find.byIcon(Icons.flag),
          ),
          findsNothing,
          reason: 'question ${index + 1} has not been marked',
        );
      }
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('exam-mark-review')))
            .tooltip,
        'Mark for review',
      );

      await tester.tap(find.byKey(const Key('exam-mark-review')));
      await tester.pumpAndSettle();

      // The tile carries a flag, the legend explains it, and the toggle reads as
      // pressed - the flag is not a mode, so the footer has to say which question
      // it is about right now.
      expect(
        find.descendant(
          of: find.byKey(const Key('exam-palette-0')),
          matching: find.byIcon(Icons.flag),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Marked for review'),
        findsOneWidget,
        reason: 'the legend is one key, not a line per marked question',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('exam-mark-review')))
            .tooltip,
        'Marked for review',
      );
      // Question 2 was not marked by marking question 1.
      expect(
        find.descendant(
          of: find.byKey(const Key('exam-palette-1')),
          matching: find.byIcon(Icons.flag),
        ),
        findsNothing,
      );

      // It survives the trip to the next question and back, which is the whole
      // point of flagging one: coming back to it later.
      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('exam-mark-review')))
            .tooltip,
        'Mark for review',
        reason: 'the mark belongs to question 1, not to the session',
      );

      await tester.tap(find.byKey(const Key('exam-previous')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('exam-mark-review')))
            .tooltip,
        'Marked for review',
      );
    });
    testWidgets('the submit dialog warns about what is still marked',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // Flag question 1, then go to the last question and submit from there.
      await tester.tap(find.byKey(const Key('exam-mark-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Submit your exam?'), findsOneWidget);
      // The flag is the last reminder the student gets, so the dialog counts what
      // is still waiting for them beside what is answered.
      expect(find.textContaining('1 question is still marked'), findsOneWidget);

      await tester.tap(find.text('Keep working'));
      await tester.pumpAndSettle();
      // Cancelling leaves the attempt open and the mark intact.
      expect(find.text('Question 2 of 2'), findsOneWidget);
      expect(find.text('Marked for review'), findsOneWidget);
    });

    testWidgets(
        'the submit dialog says nothing about marks when there are none',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit')));
      await tester.pumpAndSettle();

      expect(find.text('Submit your exam?'), findsOneWidget);
      expect(find.textContaining('marked'), findsNothing);

      await tester.tap(find.text('Keep working'));
      await tester.pumpAndSettle();
    });

    testWidgets('names the candidate when the caller knows who is sitting it',
        (tester) async {
      await tester.pumpWidget(
        pageUnderTest(
          candidateName: 'Aisha Bello',
          examTitle: 'CS101 Midterm',
          candidateEmail: 'aisha.bello@university.edu',
        ),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-candidate-header')), findsOneWidget);
      expect(find.text('Aisha Bello'), findsOneWidget);
      expect(find.text('CS101 Midterm'), findsOneWidget);
      expect(find.text('aisha.bello@university.edu'), findsOneWidget);
      // The avatar is derived from the name, not stored: `profiles` has no photo.
      expect(find.text('AB'), findsOneWidget);
    });

    testWidgets('prints no header at all when the caller knows nothing',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // An empty header row would be worse than none: it costs height on a small
      // phone and says nothing.
      expect(find.byKey(const Key('exam-candidate-header')), findsNothing);
    });

    test('initials come from the name, and never crash on an odd one', () {
      expect(ExamCandidateHeader.initialsOf('Aisha Bello'), 'AB');
      expect(ExamCandidateHeader.initialsOf('Aisha Bello-Okonkwo'), 'AO');
      expect(ExamCandidateHeader.initialsOf('Bello'), 'B');
      // Not a case the portal produces, but the avatar must not throw if a name
      // ever arrives blank.
      expect(ExamCandidateHeader.initialsOf('   '), '?');
    });
  });

  group('audio proctoring', () {
    /// A taller-than-default surface for the tests that read the prompt.
    ///
    /// The prompt is a snack bar pinned to the bottom of the Scaffold, and this
    /// screen is dense enough that the default 800x600 test viewport leaves it
    /// below the root render tree - where `tap` refuses to hit it.
    void useTallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    /// Drops the current prompt and lets its dismiss animation finish.
    ///
    /// The prompt stays up for 8s, and a timer that outlives the test is a failure
    /// ("A Timer is still pending..."), so a test that reads a prompt it does not
    /// dismiss through its action closes it here.
    Future<void> dismissPrompt(WidgetTester tester) async {
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).last),
      ).hideCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    testWidgets('the microphone state is always on screen', (tester) async {
      final source = _FakeAudioSource();

      await tester.pumpWidget(pageUnderTest(audioSource: source));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // The chip is part of the exam's chrome rather than an optional extra...
      expect(find.byKey(const Key('audio-indicator')), findsOneWidget);
      // ...and it says the session really holds the microphone, with the live meter.
      expect(find.text('Mic live'), findsOneWidget);
      expect(find.byKey(const Key('audio-indicator-meter')), findsOneWidget);
      expect(source.begins, 1);
      // A quiet room is not a violation: audio proctoring must not strike just
      // because it started listening.
      expect(proctoring.violations, isEmpty);
    });

    testWidgets('a lost microphone prompts to reconnect instead of going quiet',
        (tester) async {
      useTallSurface(tester);
      final source = _FakeAudioSource();

      await tester.pumpWidget(pageUnderTest(audioSource: source));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
      expect(find.text('Mic live'), findsOneWidget);

      // The headset is unplugged, or the OS revokes the grant mid-session.
      source.fail();
      // Settled, not merely pumped: the prompt slides in, and a snack bar caught
      // mid-entrance is not where the tap lands.
      await tester.pumpAndSettle();

      expect(find.text('Mic lost'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);

      // The prompt's action re-opens the session. Tapping it also closes the
      // snack bar, so no timer is left behind.
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();

      expect(source.begins, 2);
      expect(find.text('Mic live'), findsOneWidget);
      // A microphone that went away is not itself a strike - it is an unproctored
      // gap the student is asked to close.
      expect(proctoring.violations, isEmpty);
    });

    testWidgets('tapping a lost microphone reopens it', (tester) async {
      useTallSurface(tester);
      final source = _FakeAudioSource();

      await tester.pumpWidget(pageUnderTest(audioSource: source));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      source.fail();
      await tester.pump();
      await tester.pump();
      await dismissPrompt(tester);

      await tester.tap(find.byKey(const Key('audio-indicator-retry')));
      await tester.pumpAndSettle();

      expect(source.begins, 2);
      expect(find.text('Mic live'), findsOneWidget);
      // Nothing to retry while levels are flowing: the chip is not a button then,
      // so a stray tap cannot throw the room calibration away.
      expect(find.byKey(const Key('audio-indicator-retry')), findsNothing);
    });

    testWidgets('a refused microphone offers the OS settings page',
        (tester) async {
      useTallSurface(tester);
      final source = _FakeAudioSource(granted: false);

      await tester.pumpWidget(pageUnderTest(audioSource: source));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('Mic blocked'), findsOneWidget);
      // Re-asking cannot help after two "don't allow"s, so the fix is the settings
      // page - offered on the chip and again in the prompt.
      expect(find.byKey(const Key('audio-indicator-settings')), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(source.begins, 0);

      // The settings action asks the OS to open this app's permission page (a no-op
      // on the test VM, where PermissionService swallows the missing plugin): the
      // point is that a refusal is offered the only fix it has.
      await tester.tap(find.byKey(const Key('audio-indicator-settings')));
      await tester.pumpAndSettle();

      await dismissPrompt(tester);
      expect(proctoring.violations, isEmpty);
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
/// Serves a fixed question list and records every answer write, so a test can
/// assert what the server was told.
///
/// [online] is the flaky-network switch: with it off every write throws, which is
/// exactly what the offline queue has to absorb (the first guarantee in the
/// `OfflineSyncService` contract).
class _StubExamRepository implements ExamRepository {
  _StubExamRepository(
      {this.questions = const <Question>[], this.online = true});

  final List<Question> questions;
  bool online;
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
    if (!online) throw const _NoNetwork();
    optionAnswers.add('$questionId=$selectedOption');
  }

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {
    if (!online) throw const _NoNetwork();
    textAnswers.add('$questionId=$answer');
  }

  @override
  Future<void> submitExam(String submissionId) async {
    if (!online) throw const _NoNetwork();
    submitted.add(submissionId);
  }

  @override
  Future<void> markDisqualified(String submissionId) async {}
}

/// Accepts violations without a backend, with the flaky-network switch the submit
/// gate needs: a log the server refuses has to be queued, not lost.
class _SilentProctoringRepository implements ProctoringRepository {
  bool online = true;
  final List<Violation> violations = <Violation>[];

  @override
  Future<({int warningCount, bool disqualified})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async {
    if (!online) throw const _NoNetwork();
    violations.add(violation);
    return (
      warningCount: violations.length,
      disqualified: violations.length >= 3,
    );
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}

/// What an unreachable Supabase call looks like to the repository layer.
class _NoNetwork implements Exception {
  const _NoNetwork();

  @override
  String toString() => 'SocketException: network is unreachable';
}

/// Controllable stand-in for the DOM-backed browser guards, so the fullscreen
/// countdown can be driven from the VM (where no DOM exists at all).
class _FakeWebGuards implements WebGuards {
  final StreamController<WebGuardEvent> controller =
      StreamController<WebGuardEvent>.broadcast();

  bool inFullscreen = false;

  /// Whether the exam page armed the DOM lockdown at all, and how often it did:
  /// a session that never releases it would leave the student's browser blocked.
  bool lockdownActive = false;
  int lockdownStarts = 0;
  int lockdownStops = 0;

  void emit(WebGuardEvent event) => controller.add(event);

  @override
  bool get isSupported => true;

  @override
  bool get isFullscreen => inFullscreen;

  @override
  Stream<WebGuardEvent> get events => controller.stream;

  @override
  bool get supportsExamLockdown => true;

  @override
  void startExamLockdown() {
    lockdownStarts++;
    lockdownActive = true;
  }

  @override
  void stopExamLockdown() {
    lockdownStops++;
    lockdownActive = false;
  }

  @override
  Future<bool> enterFullscreen() async => inFullscreen = true;

  @override
  Future<void> exitFullscreen() async => inFullscreen = false;

  @override
  void dispose() {}
}

/// A microphone with no platform channel behind it, and enough controls to
/// reproduce every way the real one misbehaves.
///
/// It exists because `flutter test` runs on the Dart VM: the real
/// `RecordAudioLevelSource` would resolve straight to "unavailable" there, so the
/// exam screen's capture session is injected (see [audioLevelSourceProvider]) and
/// each test states what the microphone does.
class _FakeAudioSource implements AudioLevelSource {
  _FakeAudioSource({this.granted = true});

  /// What [requestAccess] answers. False is the "student tapped Don't allow" path.
  bool granted;

  /// What the capture session reports once someone is reading it.
  ///
  /// Quiet by default: -60 dBFS cannot trip the noise detector, whose threshold is
  /// clamped to at most -45 dBFS, so merely opening the microphone is never a strike.
  double level = -60;

  /// How many capture sessions were opened (the first start, plus every reconnect).
  int begins = 0;

  // The level is reported from `onListen`, not from `begin()`: the monitor
  // subscribes *after* begin() returns, and a broadcast controller drops events
  // with no listener - so a level sent from begin() would be lost and a working
  // microphone would look dead.
  late final StreamController<double> _levels =
      StreamController<double>.broadcast(onListen: _reportLevel);

  void _reportLevel() => scheduleMicrotask(() {
        if (!_levels.isClosed) _levels.add(level);
      });

  /// The headset being unplugged, the OS revoking the grant, another app taking the
  /// input device: an error on the capture stream, which the monitor reads as
  /// `interrupted` rather than as silence.
  void fail() {
    if (!_levels.isClosed) _levels.addError(StateError('device gone'));
  }

  @override
  bool get isSupported => true;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<bool> requestAccess() async => granted;

  @override
  Future<void> begin() async => begins++;

  @override
  Future<void> end() async {}

  @override
  void dispose() {
    if (!_levels.isClosed) _levels.close();
  }
}
