import 'package:proctorguard/features/admin/presentation/pages/admin_dashboard_page.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/authoring/domain/entities/attempt_grading.dart';
import 'package:proctorguard/features/authoring/domain/entities/authored_exam.dart';
import 'package:proctorguard/features/authoring/domain/repositories/question_authoring_repository.dart';
import 'package:proctorguard/features/authoring/presentation/pages/attempt_review_page.dart';
import 'package:proctorguard/features/authoring/presentation/pages/lecturer_console_page.dart';
import 'package:proctorguard/features/authoring/presentation/providers/question_authoring_providers.dart';
import 'package:proctorguard/features/evidence/domain/entities/attempt_evidence.dart';
import 'package:proctorguard/features/evidence/domain/repositories/evidence_repository.dart';
import 'package:proctorguard/features/evidence/presentation/providers/evidence_providers.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The three doors into the Evidence screen.
///
/// Each portal opens it on the list it already has - the lecturer on the papers
/// they wrote, the administrator on all of them - and the marking screen opens
/// it on the attempt in front of the marker, paper preselected and card marked
/// out. There is deliberately no supervisor door: a supervisor's incidents are
/// the live monitor's job, and the screen is a record review, not a watch.
///
/// These assert the wiring, not the screen: that the action exists where a
/// lecturer or administrator would look for it, that it pushes EvidencePage with
/// the right audience, and that the page then asks the RPC for the expected
/// paper rather than for everything.
void main() {
  const papers = <EvidenceExamOption>[
    EvidenceExamOption(id: 'exam-1', title: 'CS101 Midterm'),
  ];

  final exam = Exam(
    id: 'exam-1',
    title: 'CS101 Midterm',
    createdBy: 'lecturer-1',
    durationMinutes: 60,
    isPublished: true,
  );

  Widget harness({
    required Widget child,
    List<Override> overrides = const <Override>[],
    required _FakeEvidenceRepository evidence,
    EvidenceAudience? audience,
  }) => ProviderScope(
    overrides: [
      evidenceRepositoryProvider.overrideWithValue(evidence),
      if (audience != null)
        evidenceExamOptionsProvider(
          audience,
        ).overrideWith((ref) async => papers),
      ...overrides,
    ],
    child: MaterialApp(home: child),
  );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('the lecturer console opens the Evidence screen', (tester) async {
    wideViewport(tester);
    final evidence = _FakeEvidenceRepository();

    await tester.pumpWidget(
      harness(
        evidence: evidence,
        audience: EvidenceAudience.lecturer,
        overrides: [
          questionAuthoringRepositoryProvider.overrideWithValue(
            _FakeAuthoring(exam),
          ),
        ],
        child: const LecturerConsolePage(lecturerName: 'Dr. Tunde Balogun'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('lecturer-evidence')));
    await tester.pumpAndSettle();

    expect(find.text('Evidence'), findsOneWidget);
    // The page asked for the paper the console lists, through the RPC that
    // enforces the scope - not for "all evidence".
    expect(evidence.exams, <String>['exam-1']);
    expect(find.byKey(const Key('evidence-attempt-att-1')), findsOneWidget);
  });

  testWidgets('the admin dashboard opens it with the student search', (
    tester,
  ) async {
    wideViewport(tester);
    final evidence = _FakeEvidenceRepository();

    await tester.pumpWidget(
      harness(
        evidence: evidence,
        audience: EvidenceAudience.admin,
        overrides: [
          managedAccountsProvider.overrideWith((ref) async => const []),
        ],
        child: const AdminDashboardPage(adminName: 'Registrar'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin-evidence')));
    await tester.pumpAndSettle();

    expect(find.text('Evidence'), findsOneWidget);
    expect(find.byKey(const Key('evidence-search-field')), findsOneWidget);
    expect(evidence.exams, <String>['exam-1']);
  });

  testWidgets('the marking screen opens it on the attempt being marked', (
    tester,
  ) async {
    final evidence = _FakeEvidenceRepository();
    final attempt = AttemptGrading(
      submission: Submission(
        id: 'att-1',
        studentId: '11111111-2222-4333-8444-555555555555',
        examId: 'exam-1',
        answers: const <String, dynamic>{},
        status: SubmissionStatus.flaggedForReview,
        startedAt: DateTime(2026, 11, 18, 14, 5),
      ),
      studentName: 'Ada Nwosu',
      lines: const <GradeLine>[],
    );

    await tester.pumpWidget(
      harness(
        evidence: evidence,
        audience: EvidenceAudience.lecturer,
        overrides: [
          questionAuthoringRepositoryProvider.overrideWithValue(
            _FakeAuthoring(exam),
          ),
        ],
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AttemptReviewPage(
                      examId: 'exam-1',
                      examTitle: 'CS101 Midterm',
                      attempt: attempt,
                    ),
                  ),
                ),
                child: const Text('open attempt'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open attempt'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('review-evidence')));
    await tester.pumpAndSettle();

    expect(evidence.exams, <String>['exam-1']);
    // The card the reviewer came from is the one marked out.
    final card = tester.widget<Card>(
      find.byKey(const Key('evidence-attempt-att-1')),
    );
    expect((card.shape as RoundedRectangleBorder).side.width, 2);
  });
}

/// A repository that answers one paper's rows and counts what it was asked.
class _FakeEvidenceRepository implements EvidenceRepository {
  final List<String> exams = <String>[];

  @override
  Future<List<AttemptEvidence>> listExamEvidence(String examId) async {
    exams.add(examId);
    return <AttemptEvidence>[
      AttemptEvidence(
        submissionId: 'att-1',
        studentId: '11111111-2222-4333-8444-555555555555',
        studentName: 'Ada Nwosu',
        status: 'flagged_for_review',
        startedAt: DateTime(2026, 11, 18, 14, 5),
        items: <EvidenceItem>[
          EvidenceItem(
            logId: 'log-1',
            actionType: 'looking_away',
            weight: 1,
            countsTowardDq: true,
            loggedAt: DateTime(2026, 11, 18, 14, 6),
            snapshotUrl: 'att-1/looking_away_1.jpg',
          ),
        ],
      ),
    ];
  }

  @override
  Future<String?> signedStillUrl(String snapshotUrl) async =>
      'https://storage.invalid/signed/$snapshotUrl';
}

/// The console only needs the list of the caller's papers here; every other
/// member of the interface is unreachable from this test, and `noSuchMethod`
/// keeps the fake to the one method the screen uses.
class _FakeAuthoring implements QuestionAuthoringRepository {
  _FakeAuthoring(Exam paper)
    : _exams = <AuthoredExam>[
        AuthoredExam(exam: paper, questionCount: 1, attemptCount: 1),
      ];

  final List<AuthoredExam> _exams;

  @override
  Future<List<AuthoredExam>> listMyExams() async => _exams;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
