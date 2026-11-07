import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/proctor_consent.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/consent_repository.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/pages/exam_consent_page.dart';
import 'package:proctorguard/features/exam/presentation/pages/student_exam_portal_page.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The proctoring consent notice: the words on it, the fact that the exam cannot
/// start without it, and the server's answer to "does this count?".
///
/// The value of the feature is spread across those three - a clear notice nobody
/// has to accept is a formality, and an acceptance the server does not count is
/// worse than none - so all three are pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const exam = Exam(
    id: 'exam-1',
    title: 'CS101: Computer Science Fundamentals',
    createdBy: 'lecturer-1',
    durationMinutes: 60,
    isPublished: true,
  );

  Widget host(Widget child) => ProviderScope(
        child: MaterialApp(home: child),
      );

  /// Pumps the consent screen with a stub backend.
  Future<_FakeConsentRepository> pumpConsent(
    WidgetTester tester, {
    String? serverVersion = ProctorConsentConfig.version,
    ConsentRecord? record,
    Object? throws,
  }) async {
    // A tall surface on purpose: the notice is six clauses long and sits in a
    // `ListView`, which does not build what is off-screen. These tests are about
    // what the screen *says*, not about how far a student has scrolled, so the
    // whole notice is given room to exist.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _FakeConsentRepository(
      serverVersion: serverVersion,
      record: record,
      throws: throws,
    );
    await tester.pumpWidget(host(ExamConsentPage(exam: exam, repository: repo)));
    await tester.pumpAndSettle();
    return repo;
  }

  /// Ticks the box and presses the button, scrolling to each first - the screen is
  /// a list, and a phone-sized viewport does not show both at once.
  Future<void> accept(WidgetTester tester) async {
    final checkbox = find.byKey(const Key('consent-accept-checkbox'));
    await tester.ensureVisible(checkbox);
    await tester.pumpAndSettle();
    await tester.tap(checkbox);
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('consent-accept-button'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  group('the notice', () {
    testWidgets('answers the five questions a notice has to answer',
        (tester) async {
      await pumpConsent(tester);

      expect(find.byKey(const Key('exam-consent-page')), findsOneWidget);
      expect(find.text(ProctorConsentConfig.title), findsOneWidget);
      // The paper it applies to, so the notice is never ambiguous.
      expect(find.text(exam.title), findsOneWidget);

      // Every clause is rendered - what is captured, the stills, who reads them,
      // how long they are kept, what they are used for, who to ask.
      for (final clause in ProctorConsentConfig.clauses) {
        expect(
          find.byKey(Key('consent-clause-${clause.id}')),
          findsOneWidget,
          reason: 'clause ${clause.id} is missing from the screen',
        );
      }
    });

    testWidgets('the retention clause quotes the config\'s own numbers',
        (tester) async {
      final retention =
          ProctorConsentConfig.clauses.firstWhere((c) => c.id == 'retention').body;

      // The promise and the purge cannot drift apart without this failing.
      expect(
        retention,
        contains('${ProctorConsentConfig.snapshotRetentionDays} days'),
      );
      expect(
        retention,
        contains('${ProctorConsentConfig.attemptRetentionDays} days'),
      );
    });

    testWidgets('shows the version it is asking the student to accept',
        (tester) async {
      await pumpConsent(tester);

      // The same string the database stores: an appeal can point at it.
      expect(
        find.text('Notice version ${ProctorConsentConfig.version}'),
        findsOneWidget,
      );
    });

    testWidgets('leaves the institution a marked place for its own wording',
        (tester) async {
      // The TODO markers are part of the deliverable, not a comment: a build that
      // ships the placeholder contact details has to look like one.
      expect(ProctorConsentConfig.contactName, contains('TODO(institution)'));
      expect(ProctorConsentConfig.contactEmail, contains('TODO(institution)'));
      expect(
        ProctorConsentConfig.clauses.firstWhere((c) => c.id == 'contact').body,
        contains('TODO(institution)'),
      );
    });

    testWidgets('the detailed proctor rules are one tap away', (tester) async {
      await pumpConsent(tester);

      final link = find.byKey(const Key('consent-instructions'));
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('exam-instructions-dialog')), findsOneWidget);
    });
  });

  group('accepting', () {
    testWidgets('the button stays disabled until the box is ticked',
        (tester) async {
      await pumpConsent(tester);

      FilledButton button() => tester.widget<FilledButton>(
            find.byKey(const Key('consent-accept-button')),
          );

      expect(button().onPressed, isNull);

      final checkbox = find.byKey(const Key('consent-accept-checkbox'));
      await tester.ensureVisible(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(checkbox);
      await tester.pumpAndSettle();

      expect(button().onPressed, isNotNull);
    });

    testWidgets('records the bundled version for this paper', (tester) async {
      final repo = await pumpConsent(tester);

      await accept(tester);

      expect(repo.recorded, hasLength(1));
      expect(repo.recorded.single.examId, exam.id);
      expect(repo.recorded.single.version, ProctorConsentConfig.version);
    });

    testWidgets('a refusal writes nothing', (tester) async {
      final repo = await pumpConsent(tester);

      await tester.tap(find.byKey(const Key('consent-decline')));
      await tester.pumpAndSettle();

      expect(repo.recorded, isEmpty);
      expect(find.byKey(const Key('exam-consent-page')), findsNothing);
    });
  });

  group('when the acceptance does not count', () {
    testWidgets('a server version newer than this build blocks the box',
        (tester) async {
      // The old-build case: the notice was reworded and this app still shows the
      // previous text. Accepting it would store a row the policy ignores, so the
      // screen says "update" instead of letting the student try.
      await pumpConsent(tester, serverVersion: '2026-12-v2');

      expect(find.byKey(const Key('consent-stale-notice')), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
                find.byKey(const Key('consent-accept-checkbox')))
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('consent-accept-button')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('is_current false keeps the student on the screen',
        (tester) async {
      final repo = await pumpConsent(
        tester,
        record: const ConsentRecord(
          id: 'consent-1',
          version: '2026-12-v2',
          isCurrentVersion: false,
        ),
      );

      await accept(tester);

      expect(repo.recorded, hasLength(1));
      expect(find.byKey(const Key('consent-stale-notice')), findsOneWidget);
      expect(find.byKey(const Key('consent-error')), findsOneWidget);
      // Nothing popped: the attempt must not start on an acceptance the policy
      // will ignore.
      expect(find.byKey(const Key('exam-consent-page')), findsOneWidget);
    });

    testWidgets('a failed write says so, and stays', (tester) async {
      await pumpConsent(tester, throws: Exception('offline'));

      await accept(tester);

      expect(find.byKey(const Key('consent-error')), findsOneWidget);
      expect(find.byKey(const Key('exam-consent-page')), findsOneWidget);
    });
  });

  group('the portal', () {
    /// The portal with both gates stubbed, so what is asserted is the *order* and
    /// the consequence of a refusal - not a camera or a database.
    Widget portal({
      required _RecordingExamRepository repository,
      ConsentGateRequest? consent,
    }) =>
        ProviderScope(
          overrides: [
            examRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: StudentExamPortalPage(
              examPageBuilder: (examId, submissionId) =>
                  const Scaffold(body: Text('session screen')),
              hardwareGate: (_, _) async => true,
              consentGate: consent ?? (_, _) async => true,
            ),
          ),
        );

    testWidgets('a refused notice creates no attempt', (tester) async {
      final repository = _RecordingExamRepository();
      await tester.pumpWidget(
        portal(repository: repository, consent: (_, _) async => false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();

      // The insert policy would refuse this row anyway; the client must not even
      // try, so what a student sees is "you did not accept" rather than a
      // permission error.
      expect(repository.started, isEmpty);
      expect(find.text('session screen'), findsNothing);
    });

    testWidgets('an accepted notice lets the attempt start', (tester) async {
      final repository = _RecordingExamRepository();
      await tester.pumpWidget(portal(repository: repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();

      expect(repository.started, <String>['exam-1']);
      expect(find.text('session screen'), findsOneWidget);
    });
  });
}


/// A consent backend that records what the screen did.
class _FakeConsentRepository implements ConsentRepository {
  _FakeConsentRepository({
    this.serverVersion,
    ConsentRecord? record,
    this.throws,
  }) : record = record ??
            const ConsentRecord(
              id: 'consent-1',
              version: ProctorConsentConfig.version,
            );

  final String? serverVersion;
  final ConsentRecord record;

  /// When set, [recordConsent] throws instead of answering - the "no network"
  /// case the screen has to survive with a sentence and no navigation.
  final Object? throws;

  final List<({String? examId, String version})> recorded =
      <({String? examId, String version})>[];

  @override
  Future<bool> hasCurrentConsent(String examId) async => false;

  @override
  Future<String?> currentServerVersion() async => serverVersion;

  @override
  Future<ConsentRecord> recordConsent({
    String? examId,
    required String version,
  }) async {
    recorded.add((examId: examId, version: version));
    if (throws != null) throw throws!;
    return record;
  }
}

/// Just enough of the exam repository for the portal: one published paper, and a
/// note of whether an attempt was asked for.
class _RecordingExamRepository implements ExamRepository {
  final List<String> started = <String>[];

  @override
  Future<List<Exam>> getPublishedExams() async => const <Exam>[
        Exam(
          id: 'exam-1',
          title: 'CS101: Computer Science Fundamentals',
          createdBy: 'lecturer-1',
          durationMinutes: 60,
          isPublished: true,
        ),
      ];

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
      startedAt: DateTime.now(),
    );
  }

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

