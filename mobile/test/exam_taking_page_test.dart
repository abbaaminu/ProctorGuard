import 'dart:async';
import 'dart:convert';

import 'package:proctorguard/core/services/audio_monitor.dart';
import 'package:proctorguard/core/services/key_value_store.dart';
import 'package:proctorguard/core/services/kiosk_service.dart';
import 'package:proctorguard/core/services/web_face_signal_source.dart';
import 'package:proctorguard/core/services/web_guards.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/pages/exam_taking_page.dart';
import 'package:proctorguard/features/exam/presentation/widgets/exam_session_widgets.dart';
import 'package:proctorguard/features/exam/presentation/widgets/mobile_exam_only.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/audio_monitoring_provider.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:proctorguard/features/proctoring/presentation/widgets/equipment_block_overlay.dart';
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
///    unplugged microphone blocks the paper (an unanswerable prompt would leave a
///    silent gap in proctoring) while still leaving the student a way out.
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
/// The user agents the platform rule reads, as the browsers actually send them
/// (see `examRunsOnPlatform` in `mobile_exam_only.dart`).
const String iphoneSafari =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 '
    'Safari/604.1';
const String windowsChrome =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like '
    'Gecko) Chrome/126.0.0.0 Safari/537.36';

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
  ///
  /// [onPopped] is handed whatever the session screen popped with — the instant
  /// result the portal then shows the student (see [ExamSubmitResult]).
  Widget pageUnderTest({
    bool mockCamera = true,
    WebGuards? webGuards,
    DateTime Function()? clock,
    /// The attempt's clock: `exams.duration_minutes`, the submission's
    /// `started_at` and the paper's `ends_at` (`ExamTakingPage` passes exactly
    /// these three in production). Null means "no countdown to enforce", which is
    /// what every test that is not about the clock wants.
    int? durationMinutes,
    DateTime? startedAt,
    DateTime? endsAt,
    AudioLevelSource? audioSource,
    WebFaceSignalSource? webFaceSignals,
    String? candidateName,
    String? examTitle,
    String? candidateEmail,
    void Function(Object? result)? onPopped,
    /// Overrides `kIsWeb` for the platform rule (see `examRunsOnPlatform`): a VM
    /// test cannot become a browser, so the browser's answer — the refusal and
    /// the desktop allowance alike — is asked for explicitly.
    bool? isWeb,
    String? userAgent,
    String? browserPlatform,
    int? maxTouchPoints,
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
                  onPressed: () async {
                    final popped = await Navigator.of(context)
                        .push<Object?>(MaterialPageRoute<Object?>(
                          builder: (_) => ExamTakingPage(
                            examId: 'exam-1',
                            submissionId: 'sub-1',
                            mockCamera: mockCamera,
                            webGuards: webGuards,
                            webFaceSignals: webFaceSignals,
                            clock: clock,
                            durationMinutes: durationMinutes,
                            startedAt: startedAt,
                            endsAt: endsAt,
                            candidateName: candidateName,
                            examTitle: examTitle,
                            candidateEmail: candidateEmail,
                            isWeb: isWeb,
                            browserUserAgent: userAgent,
                            browserPlatform: browserPlatform,
                            maxTouchPoints: maxTouchPoints,
                          ),
                        ));
                    onPopped?.call(popped);
                  },
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

  group('a resumed attempt whose time ran out', () {
    /// The attempt starts at 09:00 and the paper gives an hour, so the deadline is
    /// 10:00; this is how far past the start the clock reads.
    late int minutesPastStart;

    DateTime attemptClock() =>
        DateTime(2026, 1, 5, 9).add(Duration(minutes: minutesPastStart));

    /// Bounded pumps, for the same reason the offline group uses them: an attempt
    /// held open by a queue that cannot drain is *supposed* to keep retrying, so
    /// "settled" is not a state this screen reaches and `pumpAndSettle` would spin.
    Future<void> pumpAttempt(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Widget resumedAt({int minutes = 90}) {
      minutesPastStart = minutes;
      return pageUnderTest(
        clock: attemptClock,
        durationMinutes: 60,
        startedAt: DateTime(2026, 1, 5, 9),
      );
    }

    testWidgets('is not submitted behind the student\'s back', (tester) async {
      // A reload at 10:30 of a 09:00-10:00 attempt. The old behaviour was to fire
      // the clock's time-up on the very first tick, which submitted immediately -
      // before the cached answers and the offline queue had been replayed - and
      // closed the attempt with a zero the student never saw happen.
      await tester.pumpWidget(resumedAt());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(exams.submitted, isEmpty);
      expect(find.byKey(const Key('exam-expired-on-load')), findsOneWidget);
      expect(find.text('Time is up'), findsOneWidget);
      expect(find.text('Hand in my answers'), findsOneWidget);
      // A blocking screen like any other: no spinner left behind, one action and
      // one way out.
      expectBlockingState();
      // The paper is not put in front of them either: there is nothing to answer.
      expect(find.text('Question 1 of 2'), findsNothing);
    });

    testWidgets('hands the saved answers in when the student asks',
        (tester) async {
      await tester.pumpWidget(resumedAt());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-retry')));
      await tester.pumpAndSettle();

      // Exactly one submit, and the session screen has closed itself.
      expect(exams.submitted, <String>['sub-1']);
      expect(find.text('open exam'), findsOneWidget);
    });

    testWidgets('an answer the queue still owes keeps the attempt open',
        (tester) async {
      // The device holds an answer the server never received. Closing the attempt
      // now would have it graded without that answer, so the hand-in has to wait -
      // the same gate as a live time-up, not a bypass for the expiry panel.
      exams.online = false;
      store = InMemoryKeyValueStore(values: <String, String>{
        'queue.answers': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'submission_id': 'sub-1',
            'question_id': 'q-1',
            'selected_option': 1,
            'updated_at':
                DateTime(2026, 1, 5, 9, 5).toUtc().toIso8601String(),
          },
        ]),
      });

      await tester.pumpWidget(resumedAt());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-retry')));
      await pumpAttempt(tester);

      expect(exams.submitted, isEmpty);
      expect(find.byKey(const Key('exam-time-up')), findsOneWidget);
      // Leaving is still possible, and the attempt stays `ongoing` for later.
      expect(find.byKey(const Key('exam-leave')), findsOneWidget);
    });

    testWidgets('a clock that runs out on screen still submits on its own',
        (tester) async {
      // The other half of the rule this group pins: when the student is sitting the
      // paper and the clock reaches zero in front of them, the attempt is handed in
      // without a dialog. Only the *resumed-past-the-deadline* case waits.
      await tester.pumpWidget(resumedAt(minutes: 59));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
      expect(find.text('Question 1 of 2'), findsOneWidget);
      expect(exams.submitted, isEmpty);

      minutesPastStart = 61; // the deadline has gone by
      await tester.pump(const Duration(seconds: 1)); // the countdown's next tick
      await tester.pumpAndSettle();

      expect(exams.submitted, <String>['sub-1']);
      expect(find.text('open exam'), findsOneWidget);
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

  group('the browser face bridge (requirement 2, web)', () {
    late _FakeFaceSource faces;
    late DateTime now;

    setUp(() {
      faces = _FakeFaceSource();
      now = DateTime.utc(2026, 6, 1, 9);
    });

    /// Opens the attempt and moves past the bridge's 5s start-up grace, so a
    /// detection below is a real one rather than a student adjusting the camera.
    ///
    /// The clock is moved by hand for the same reason as the fullscreen group:
    /// the grace is measured on the injected wall clock, not on the fake time a
    /// widget test advances.
    Future<void> openPastGrace(WidgetTester tester) async {
      await tester.pumpWidget(
        pageUnderTest(webFaceSignals: faces, clock: () => now),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
      now = now.add(const Duration(seconds: 6));
    }

    testWidgets('a held look away is one looking_away strike', (tester) async {
      await openPastGrace(tester);

      faces.emit('looking_away');
      await tester.pump();
      await tester.pump();
      expect(
        proctoring.violations,
        isEmpty,
        reason: 'a glance at the keyboard is not a violation',
      );

      now = now.add(const Duration(milliseconds: 1300));
      faces.emit('LOOKING_AWAY');
      await tester.pump();
      await tester.pump();

      expect(proctoring.violations.single.type.dbValue, 'looking_away');
      expect(find.text('Warning 1 / 3'), findsOneWidget);
    });

    testWidgets('a near-sideways head is one looking_away strike on sight',
        (tester) async {
      await openPastGrace(tester);

      // The page measured the head, and 70 deg is past the point where anything
      // on the screen could still be read - so the strike does not wait out a
      // sustain the way a glance at 40 deg would.
      faces.emit('pose:70,0');
      await tester.pump();
      await tester.pump();

      expect(proctoring.violations.single.type.dbValue, 'looking_away');
      expect(find.text('Warning 1 / 3'), findsOneWidget);

      // Still held: the same episode is not a second strike.
      now = now.add(const Duration(seconds: 2));
      faces.emit('pose:70,5');
      await tester.pump();
      await tester.pump();
      expect(proctoring.violations, hasLength(1));
    });

    testWidgets('a second person is reported as soon as the page sees them',
        (tester) async {
      await openPastGrace(tester);

      // No sustain to wait out: two faces need no measuring.
      faces.emit('multiple_faces');
      await tester.pump();
      await tester.pump();

      expect(proctoring.violations.single.type.dbValue, 'multiple_faces');
    });

    testWidgets('a covered camera is a no_face strike once it is held',
        (tester) async {
      await openPastGrace(tester);

      // `web/proctor_face_detector.js` re-sends `no_face` on every 350 ms tick it
      // holds, which is what this is: the first verdict is one dropped frame, the
      // second - one tick inside the monitor's sustain - is a covered lens.
      faces.emit('no_face');
      await tester.pump();
      await tester.pump();
      expect(
        proctoring.violations,
        isEmpty,
        reason: 'a single no_face is a camera that blinked, not a student hiding',
      );

      now = now.add(const Duration(milliseconds: 350));
      faces.emit('no_face');
      await tester.pump();
      await tester.pump();

      expect(proctoring.violations.single.type.dbValue, 'no_face');
      expect(find.text('Warning 1 / 3'), findsOneWidget);
    });

    testWidgets('no_face holds the paper shut until a face is reported again',
        (tester) async {
      await openPastGrace(tester);

      // The student leans out of frame and stays out: two detections 350ms apart
      // are past the monitor's sustain, so this is a covered lens rather than a
      // blink.
      faces.emit('no_face');
      await tester.pump();
      faces.emit('no_face');
      now = now.add(const Duration(milliseconds: 350));
      await tester.pump();
      await tester.pumpAndSettle();

      // The strike is logged (it is an event) *and* the paper is covered (it is
      // also the current state of the camera). A warning alone would let the
      // student read on with nobody visibly sitting the exam.
      expect(proctoring.violations.single.type.dbValue, 'no_face');
      expect(find.text('Warning 1 / 3'), findsOneWidget);
      expect(find.byKey(const Key('equipment-block-face')), findsOneWidget);
      // Which means the warning's own dismiss button is behind an opaque barrier:
      // a student cannot click their way back to an unproctored paper.
      expect(
        find.descendant(
          of: find.byKey(const Key('equipment-block-face')),
          matching: find.text('I understand, continue'),
        ),
        findsNothing,
      );

      // A face comes back, and the paper comes back with it - no tap needed.
      faces.emit('centered');
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('equipment-block-face')), findsNothing);
    });

    testWidgets('nothing is judged while the page has no detector', (tester) async {
      // Android, iOS, desktop, and a browser whose host page ships no detector:
      // the source says so, the page releases it, and the attempt is proctored
      // exactly as it was before the bridge existed.
      faces = _FakeFaceSource(supported: false);
      await tester.pumpWidget(
        pageUnderTest(webFaceSignals: faces, clock: () => now),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(faces.disposed, isTrue, reason: 'an unsupported source is let go');

      now = now.add(const Duration(seconds: 10));
      faces.emit('looking_away');
      faces.emit('multiple_faces');
      await tester.pump();
      await tester.pump();
      expect(proctoring.violations, isEmpty);
    });

    testWidgets('leaving the attempt uninstalls the hook', (tester) async {
      await openPastGrace(tester);
      expect(faces.disposed, isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(
        faces.disposed,
        isTrue,
        reason: 'the page must not keep a detector reporting into a closed '
            'attempt',
      );

      // Late calls from a page that has not unloaded yet are ignored.
      faces.emit('multiple_faces');
      await tester.pump();
      await tester.pump();
      expect(proctoring.violations, isEmpty);
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

  /// What a strike looks like to the student.
  ///
  /// Two things used to be wrong here. The warning overlays were built into the
  /// question branch of `build()` alone, so a strike taken while the screen was
  /// blocked or loading was logged and counted — three of them disqualify — with
  /// nothing on screen ever showing one. And the count itself disappeared with the
  /// overlay, leaving a student one strike from disqualification with no way to
  /// know it.
  group('warnings the student can see', () {
    /// The notifier this page is watching, reached the way the page reaches it.
    ProctoringNotifier notifierOf(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(ExamTakingPage)))
            .read(proctoringProvider('sub-1').notifier);

    /// A strike, and the two pumps its optimistic write needs.
    Future<void> strike(WidgetTester tester) async {
      notifierOf(tester).reportAppMinimized();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a strike taken behind a blocking state is still shown',
        (tester) async {
      await tester.pumpWidget(pageUnderTest(mockCamera: false));
      await tester.tap(find.text('open exam'));
      await pumpBootstrap(tester);
      expectBlockingState();

      // The OS reports an app switch whatever is on screen, and the AFK watcher
      // runs off the same lifecycle, so a strike can land on "Camera unavailable".
      await strike(tester);

      expect(find.text('Warning 1 / 3'), findsOneWidget);
      // Still blocked underneath: acknowledging the warning returns the student to
      // the retry, not to a paper with no camera behind it.
      expect(find.byKey(const Key('exam-retry')), findsOneWidget);

      await tester.tap(find.text('I understand, continue'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Warning 1 / 3'), findsNothing);
      expectBlockingState();
    });

    testWidgets('the count stays on the paper once the warning is acknowledged',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
      expect(find.text('1 of 3 warnings'), findsNothing);

      await strike(tester);
      expect(find.text('Warning 1 / 3'), findsOneWidget);

      await tester.tap(find.text('I understand, continue'));
      await tester.pumpAndSettle();

      // The overlay is gone, the strike is not: the third one ends the attempt, so
      // the count has to outlive the dialog that announced it.
      expect(find.text('Warning 1 / 3'), findsNothing);
      expect(find.text('1 of 3 warnings'), findsOneWidget);
    });

    testWidgets('back acknowledges the warning instead of abandoning the attempt',
        (tester) async {
      await tester.pumpWidget(pageUnderTest());
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      await strike(tester);
      expect(find.text('Warning 1 / 3'), findsOneWidget);

      // A hardware/gesture back on Android reaches the route as `popRoute`, which
      // is `Navigator.maybePop` — the call that used to pop the session out from
      // under a warning the student had not read.
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Warning 1 / 3'), findsNothing);
      expect(find.text('Question 1 of 2'), findsOneWidget);
      // Acknowledged, not undone: the strike stays the attempt's first.
      expect(proctoring.violations.single.type.dbValue, 'app_minimized');
    });
  });

  /// The platform rule (see `examRunsOnPlatform` in `mobile_exam_only.dart`).
  ///
  /// This screen is the backstop: the route can be built without going through the
  /// exam list at all (a resumed attempt, a restored navigator stack, a shared
  /// link), so the rule has to hold here whatever navigated in — the refusal for a
  /// phone or tablet browser, and the paper itself in the app and in a desktop
  /// browser.
  group('where the exam may be sat', () {
    late _FakeWebGuards guards;

    setUp(() => guards = _FakeWebGuards());

    testWidgets('a phone browser is refused before the session starts anything',
        (tester) async {
      await tester.pumpWidget(
        pageUnderTest(webGuards: guards, isWeb: true, userAgent: iphoneSafari),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only')), findsOneWidget);
      expect(find.text(examMobileOnlyTitle), findsOneWidget);
      // No paper, no question counter, no camera pane behind it.
      expect(find.text('Question 1 of 2'), findsNothing);

      // Nothing ran: no DOM lockdown to release, no question read, no strike
      // recorded against an attempt the student was just told would not run here.
      expect(guards.lockdownStarts, 0);
      expect(exams.optionAnswers, isEmpty);
      expect(exams.textAnswers, isEmpty);
      expect(proctoring.violations, isEmpty);

      // And the refusal is not a dead end.
      await tester.tap(find.text('Back to my exams'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only')), findsNothing);
      expect(find.text('open exam'), findsOneWidget);
    });

    testWidgets('a desktop browser gets the paper', (tester) async {
      // A computer is a supported exam host: the rule refuses the *device* that
      // cannot be proctored, not the web build. The guards here are the VM stubs
      // (`kIsWeb` is compile-time false in a Dart VM test), which is exactly what
      // the page falls back to when a caller injects none.
      await tester.pumpWidget(
        pageUnderTest(isWeb: true, userAgent: windowsChrome),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-mobile-only')), findsNothing);
      expect(find.text('Question 1 of 2'), findsOneWidget);
    });

    testWidgets('a phone still gets the paper', (tester) async {
      await tester.pumpWidget(pageUnderTest(isWeb: false));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // The rule refuses a phone *browser*, not the platform it cannot see: every
      // other test in this file is a VM build, and they all sit the exam.
      expect(find.byKey(const Key('exam-mobile-only')), findsNothing);
      expect(find.text('Question 1 of 2'), findsOneWidget);
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

    testWidgets('submitting hands back the mark, the total and the paper shape',
        (tester) async {
      // Two marks of one point each, both graded automatically: `submit_exam`
      // answers with the score it computed and this screen adds the total, so the
      // portal can print "1 of 2" without grading anything itself.
      exams = _StubExamRepository(
        questions: const <Question>[multipleChoice, fillInTheBlank],
        grading: const ExamSubmitResult(
          status: SubmissionStatus.submitted,
          score: 1,
        ),
      );
      Object? popped;

      await tester.pumpWidget(
        pageUnderTest(onPopped: (result) => popped = result),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // Submit lives on the last question, so walk to it first.
      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit-confirm')));
      await tester.pumpAndSettle();

      expect(
        popped,
        const ExamSubmitResult(
          status: SubmissionStatus.submitted,
          score: 1,
          maxScore: 2,
          // Nothing on this paper needs a lecturer, so the result is final the
          // moment the server answered.
          awaitingMarking: false,
        ),
      );
    });

    testWidgets('a paper with an essay is handed back as still to be marked',
        (tester) async {
      // The score `submit_exam` returns here is only the automatic half: the
      // essay is marked later by the paper's owner, and the portal must say so
      // rather than present a partial number as the final mark.
      exams = _StubExamRepository(
        questions: const <Question>[multipleChoice, subjective],
        grading: const ExamSubmitResult(
          status: SubmissionStatus.submitted,
          score: 1,
        ),
      );
      Object? popped;

      await tester.pumpWidget(
        pageUnderTest(onPopped: (result) => popped = result),
      );
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      // The essay is the second question, and submit lives on the last one.
      await tester.tap(find.byKey(const Key('exam-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('exam-submit-confirm')));
      await tester.pumpAndSettle();

      expect(
        popped,
        const ExamSubmitResult(
          status: SubmissionStatus.submitted,
          score: 1,
          maxScore: 2,
          awaitingMarking: true,
        ),
      );
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
    /// A taller-than-default surface, so the blocking overlay's three actions fit
    /// without scrolling: `tap` refuses to hit a button scrolled out of view.
    void useTallSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
      // Nothing is blocked while the microphone is doing its job.
      expect(find.byType(EquipmentBlockOverlay), findsNothing);
    });

    testWidgets('a lost microphone blocks the paper until it is back',
        (tester) async {
      useTallSurface(tester);
      final source = _FakeAudioSource();

      await tester.pumpWidget(pageUnderTest(audioSource: source));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();
      expect(find.text('Mic live'), findsOneWidget);

      // The headset is unplugged, or the OS revokes the grant mid-session.
      source.fail();
      await tester.pumpAndSettle();

      // Not a toast the student can ignore their way past: an unproctored attempt
      // is not one they get to continue. The block is opaque, so the question is
      // covered rather than merely commented on.
      final block = find.byKey(const Key('equipment-block-microphone'));
      expect(block, findsOneWidget);
      expect(find.text('Mic lost'), findsOneWidget, reason: 'the chip still says it');
      expect(
        find.descendant(of: block, matching: find.byType(Scaffold)),
        findsNothing,
        reason: 'the block is a barrier, not a screen of its own',
      );

      // The block's action re-opens the session, and the paper comes back with it.
      await tester.tap(find.byKey(const Key('equipment-block-action')));
      await tester.pumpAndSettle();

      expect(source.begins, 2);
      expect(find.text('Mic live'), findsOneWidget);
      expect(block, findsNothing);
      // A microphone that went away is not itself a strike - it is an unproctored
      // gap the student is made to close.
      expect(proctoring.violations, isEmpty);
    });

    testWidgets('a refused microphone blocks the paper and offers settings',
        (tester) async {
      useTallSurface(tester);
      final source = _FakeAudioSource(granted: false);

      await tester.pumpWidget(pageUnderTest(audioSource: source));
      await tester.tap(find.text('open exam'));
      await tester.pumpAndSettle();

      expect(find.text('Mic blocked'), findsOneWidget);
      final block = find.byKey(const Key('equipment-block-microphone'));
      expect(block, findsOneWidget);
      // Re-asking cannot help after two "don't allow"s, so the block offers the
      // settings page - the only fix a refusal has - beside the retry, and keeps
      // the chip's own settings action for when the block is gone.
      expect(
        find.descendant(
          of: block,
          matching: find.byKey(const Key('equipment-block-settings')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: block,
          matching: find.byKey(const Key('equipment-block-action')),
        ),
        findsOneWidget,
      );
      // Leaving is still possible: a block holds the paper shut, not the student.
      expect(find.byKey(const Key('equipment-block-leave')), findsOneWidget);
      expect(source.begins, 0);

      // The settings action asks the OS to open this app's permission page (a no-op
      // on the test VM, where PermissionService swallows the missing plugin): the
      // point is that a refusal is offered the only fix it has.
      await tester.tap(find.byKey(const Key('equipment-block-settings')));
      await tester.pumpAndSettle();

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
/// assert what the server was told.
///
/// [online] is the flaky-network switch: with it off every write throws, which is
/// exactly what the offline queue has to absorb (the first guarantee in the
/// `OfflineSyncService` contract).
class _StubExamRepository implements ExamRepository {
  _StubExamRepository(
      {this.questions = const <Question>[],
      this.online = true,
      this.grading = const ExamSubmitResult(
        status: SubmissionStatus.submitted,
        score: 4,
      )});

  final List<Question> questions;
  bool online;

  /// What `submit_exam` answers with, so a test can assert the result the session
  /// screen hands back to the portal.
  final ExamSubmitResult grading;

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
  Future<ExamSubmitResult> submitExam(String submissionId) async {
    if (!online) throw const _NoNetwork();
    submitted.add(submissionId);
    return grading;
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

/// A host detector with no browser behind it, so the bridge's contract can be
/// exercised on the VM (where `flutter test` runs and no DOM exists).
///
/// It stands in for `window.proctorGuardFaceSignal` exactly as `_FakeWebGuards`
/// stands in for the DOM: the page under test is handed one, and each test states
/// what the host detector saw.
class _FakeFaceSource implements WebFaceSignalSource {
  _FakeFaceSource({this.supported = true});

  final bool supported;
  final StreamController<String> controller =
      StreamController<String>.broadcast();

  /// Whether the exam page released the hook. A source left installed is a
  /// detector still reporting into an attempt that has already ended.
  bool disposed = false;

  void emit(String message) {
    if (!controller.isClosed) controller.add(message);
  }

  @override
  bool get isSupported => supported;

  @override
  Stream<String> get messages => controller.stream;

  @override
  void dispose() {
    disposed = true;
    if (!controller.isClosed) controller.close();
  }
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
  /// Quiet by default: -60 dBFS cannot trip the noise detector, whose threshold
  /// never falls below -55 dBFS, so merely opening the microphone is never a strike.
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
