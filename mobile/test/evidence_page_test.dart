import 'package:proctorguard/features/evidence/domain/entities/attempt_evidence.dart';
import 'package:proctorguard/features/evidence/domain/repositories/evidence_repository.dart';
import 'package:proctorguard/features/evidence/presentation/pages/evidence_page.dart';
import 'package:proctorguard/features/evidence/presentation/providers/evidence_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Evidence screen: the rows `public.exam_evidence()` returns, grouped per
/// sitting, shown with one still per incident.
///
/// The *scope* is not tested here - it is SQL, and
/// `supabase/tests/exam_evidence_check.sql` proves it against a database. What
/// this file pins is the client half: the grouping and the name fallback, one
/// signature per still and never more than two attempts at one, a failed
/// signature that degrades to a tile instead of a page, the administrator's
/// student search, and the paper picker opening on the paper the reviewer came
/// from.
void main() {
  const papers = <EvidenceExamOption>[
    EvidenceExamOption(id: 'exam-a', title: 'CS101 Midterm'),
    EvidenceExamOption(id: 'exam-b', title: 'CS102 Final'),
  ];

  Widget page({
    required EvidenceRepository repository,
    EvidenceAudience audience = EvidenceAudience.lecturer,
    List<EvidenceExamOption> examOptions = papers,
    String? initialExamId,
    String? highlightSubmissionId,
  }) => ProviderScope(
    overrides: [
      evidenceRepositoryProvider.overrideWithValue(repository),
      evidenceExamOptionsProvider(
        audience,
      ).overrideWith((ref) async => examOptions),
    ],
    child: MaterialApp(
      home: EvidencePage(
        audience: audience,
        initialExamId: initialExamId,
        highlightSubmissionId: highlightSubmissionId,
      ),
    ),
  );

  group('rows', () {
    test('groups per attempt and keeps the order the RPC returned', () {
      final attempts = AttemptEvidence.group(<Map<String, dynamic>>[
        _row(logId: 'log-3', submissionId: 'att-2', actionType: 'no_face'),
        _row(logId: 'log-1', submissionId: 'att-1'),
        _row(
          logId: 'log-2',
          submissionId: 'att-1',
          actionType: 'copy_paste_attempt',
        ),
      ]);

      expect(attempts.map((attempt) => attempt.submissionId), <String>[
        'att-2',
        'att-1',
      ]);
      expect(attempts[1].items.map((item) => item.logId), <String>[
        'log-1',
        'log-2',
      ]);
    });

    test('falls back to a short id when the name is withheld', () {
      final attempts = AttemptEvidence.group(<Map<String, dynamic>>[
        _row(
          logId: 'log-1',
          studentName: null,
          studentId: '9f3c1a2b-0000-4000',
        ),
      ]);

      expect(attempts.single.studentName, isNull);
      expect(attempts.single.displayName, 'Student 9f3c1a2b');
    });

    test('counts only the incidents that count, and labels what is left', () {
      final attempt = AttemptEvidence.group(<Map<String, dynamic>>[
        _row(logId: 'log-1'),
        _row(logId: 'log-2', actionType: 'multiple_faces'),
        _row(
          logId: 'log-3',
          actionType: 'copy_paste_attempt',
          weight: 0,
          counts: false,
        ),
      ]).single;

      expect(attempt.items.length, 3);
      expect(attempt.points, 2);
      expect(attempt.items[2].weightLabel, 'Not counted');
      expect(attempt.items[0].weightLabel, '1 point');
      expect(attempt.statusLabel, 'Flagged for review');
      expect(attempt.needsReview, isTrue);
    });

    test('keeps a row without a still, and an unknown action, readable', () {
      final attempt = AttemptEvidence.group(<Map<String, dynamic>>[
        _row(logId: 'log-1', snapshotUrl: null),
        _row(logId: 'log-2', actionType: 'phone_in_hand'),
      ]).single;

      expect(attempt.items[0].hasStill, isFalse);
      expect(attempt.items[0].actionLabel, 'Looked away');
      expect(attempt.items[1].hasStill, isTrue);
      expect(
        attempt.items[1].actionLabel,
        'phone_in_hand',
        reason: 'a signal this build does not know must still be visible',
      );
      expect(attempt.hasStills, isTrue);
    });
  });

  group('the screen', () {
    testWidgets('shows each sitting, its incidents and one signature per still', (
      tester,
    ) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[_attempt()],
      );

      await tester.pumpWidget(page(repository: repository));
      await tester.pumpAndSettle();

      expect(find.text('Ada Nwosu'), findsOneWidget);
      expect(find.textContaining('Flagged for review · sat'), findsOneWidget);
      expect(find.text('2 incidents · 2 counted points'), findsOneWidget);
      expect(find.text('Looked away'), findsOneWidget);
      expect(find.text('No face detected'), findsOneWidget);

      // One signature per still, minted for the stored path - not for a URL the
      // entity carried, and one per tile rather than one per sitting.
      expect(repository.signed, <String>[
        'att-1/looking_away_1.jpg',
        'att-1/no_face_2.jpg',
      ]);
      expect(find.byKey(const Key('evidence-still-log-1')), findsOneWidget);
      expect(find.byKey(const Key('evidence-still-log-2')), findsOneWidget);

      // The page never names the still in its own right: the path is an internal
      // identifier, and printing it would invite somebody to paste it into a
      // browser where it means nothing.
      expect(find.textContaining('att-1/'), findsNothing);
    });

    testWidgets('an incident logged without a still is still an incident', (
      tester,
    ) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[
          _attempt(items: <EvidenceItem>[_item(snapshotUrl: null)]),
        ],
      );

      await tester.pumpWidget(page(repository: repository));
      await tester.pumpAndSettle();

      expect(find.text('No still'), findsOneWidget);
      expect(repository.signed, isEmpty);
      expect(find.text('Looked away'), findsOneWidget);
    });

    testWidgets(
      'a signature that fails is retried once, then reported, and the '
      'page carries on',
      (tester) async {
        final repository = _FakeEvidenceRepository(
          attempts: <AttemptEvidence>[
            _attempt(items: <EvidenceItem>[_item()]),
          ],
          failSigns: 2,
        );

        await tester.pumpWidget(page(repository: repository));
        await tester.pumpAndSettle();

        expect(repository.signed.length, 2, reason: 'one retry, no more');
        expect(find.text('Preview unavailable'), findsOneWidget);
        // The incident itself is unaffected: the row is the evidence.
        expect(find.text('Looked away'), findsOneWidget);
        expect(find.text('Ada Nwosu'), findsOneWidget);
      },
    );

    testWidgets('a read that fails explains itself and a retry reloads', (
      tester,
    ) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[_attempt()],
        failReads: 1,
      );

      await tester.pumpWidget(page(repository: repository));
      await tester.pumpAndSettle();

      expect(find.textContaining('Backend unavailable'), findsOneWidget);

      await tester.tap(find.byKey(const Key('evidence-retry')));
      await tester.pumpAndSettle();

      expect(find.text('Ada Nwosu'), findsOneWidget);
      expect(repository.reads, 2);
    });

    testWidgets(
      'a paper with no incidents says so instead of showing nothing',
      (tester) async {
        final repository = _FakeEvidenceRepository(attempts: const []);

        await tester.pumpWidget(page(repository: repository));
        await tester.pumpAndSettle();

        expect(
          find.text('No incidents were recorded on this paper.'),
          findsOneWidget,
        );
        expect(repository.signed, isEmpty);
      },
    );
  });

  group('the picker and the administrator search', () {
    testWidgets('opens on the paper the reviewer came from, highlighting that '
        'attempt', (tester) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[
          _attempt(submissionId: 'att-2', studentName: 'Bola Ade'),
        ],
      );

      await tester.pumpWidget(
        page(
          repository: repository,
          initialExamId: 'exam-b',
          highlightSubmissionId: 'att-2',
        ),
      );
      await tester.pumpAndSettle();

      expect(repository.exams.first, 'exam-b');

      final card = tester.widget<Card>(
        find.byKey(const Key('evidence-attempt-att-2')),
      );
      final side = (card.shape as RoundedRectangleBorder).side;
      expect(side.width, 2, reason: 'the card arrived from is marked out');
    });

    testWidgets('a route naming a paper the account cannot read falls back to '
        'the first one offered', (tester) async {
      final repository = _FakeEvidenceRepository(attempts: const []);

      await tester.pumpWidget(
        page(repository: repository, initialExamId: 'exam-not-mine'),
      );
      await tester.pumpAndSettle();

      // A picker whose value is not in its item list throws; more importantly, a
      // route parameter must not decide what the page asks for.
      expect(repository.exams, <String>['exam-a']);
    });

    testWidgets('switching papers asks the RPC for the new paper', (
      tester,
    ) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[_attempt()],
      );

      await tester.pumpWidget(page(repository: repository));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('evidence-exam-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CS102 Final').last);
      await tester.pumpAndSettle();

      expect(repository.exams, <String>['exam-a', 'exam-b']);
    });

    testWidgets('the administrator can find a sitting by the student name', (
      tester,
    ) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[
          _attempt(submissionId: 'att-1', studentName: 'Ada Nwosu'),
          _attempt(
            submissionId: 'att-2',
            studentName: 'Bola Ade',
            studentId: '22222222-0000-4000',
          ),
        ],
      );

      await tester.pumpWidget(
        page(repository: repository, audience: EvidenceAudience.admin),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('evidence-search-field')), findsOneWidget);
      expect(find.text('2 attempts'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('evidence-search-field')),
        'bola',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('evidence-attempt-att-1')), findsNothing);
      expect(find.byKey(const Key('evidence-attempt-att-2')), findsOneWidget);
      expect(find.text('1 of 2 attempts'), findsOneWidget);
    });

    testWidgets('the lecturer keeps the whole list and no search bar', (
      tester,
    ) async {
      final repository = _FakeEvidenceRepository(
        attempts: <AttemptEvidence>[
          _attempt(submissionId: 'att-1', studentName: 'Ada Nwosu'),
          _attempt(
            submissionId: 'att-2',
            studentName: 'Bola Ade',
            studentId: '22222222-0000-4000',
          ),
        ],
      );

      await tester.pumpWidget(page(repository: repository));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('evidence-search-field')), findsNothing);
      expect(find.byKey(const Key('evidence-attempt-att-1')), findsOneWidget);
      expect(find.byKey(const Key('evidence-attempt-att-2')), findsOneWidget);
    });
  });
}

/// One `exam_evidence()` row, as the RPC answers it.
Map<String, dynamic> _row({
  required String logId,
  String submissionId = 'att-1',
  String studentId = '11111111-2222-4333-8444-555555555555',
  String? studentName = 'Ada Nwosu',
  String actionType = 'looking_away',
  int weight = 1,
  bool counts = true,
  String? snapshotUrl = 'att-1/looking_away_1.jpg',
  String status = 'flagged_for_review',
}) => <String, dynamic>{
  'log_id': logId,
  'submission_id': submissionId,
  'student_id': studentId,
  'student_name': studentName,
  'action_type': actionType,
  'weight': weight,
  'counts_toward_dq': counts,
  'logged_at': '2026-11-18T14:06:00.000Z',
  'snapshot_url': snapshotUrl,
  'attempt_status': status,
  'attempt_started_at': '2026-11-18T14:05:00.000Z',
};

EvidenceItem _item({
  String logId = 'log-1',
  String actionType = 'looking_away',
  int weight = 1,
  bool counts = true,
  String? snapshotUrl = 'att-1/looking_away_1.jpg',
}) => EvidenceItem(
  logId: logId,
  actionType: actionType,
  weight: weight,
  countsTowardDq: counts,
  loggedAt: DateTime(2026, 11, 18, 14, 6),
  snapshotUrl: snapshotUrl,
);

AttemptEvidence _attempt({
  String submissionId = 'att-1',
  String studentId = '11111111-2222-4333-8444-555555555555',
  String? studentName = 'Ada Nwosu',
  String status = 'flagged_for_review',
  List<EvidenceItem>? items,
}) => AttemptEvidence(
  submissionId: submissionId,
  studentId: studentId,
  studentName: studentName,
  status: status,
  startedAt: DateTime(2026, 11, 18, 14, 5),
  items:
      items ??
      <EvidenceItem>[
        _item(),
        _item(
          logId: 'log-2',
          actionType: 'no_face',
          snapshotUrl: 'att-1/no_face_2.jpg',
        ),
      ],
);

/// A repository that answers from memory and counts what it was asked.
///
/// No Supabase client is constructed: the point of `evidenceRepositoryProvider`
/// throwing until it is overridden is that a test can bind this instead.
class _FakeEvidenceRepository implements EvidenceRepository {
  _FakeEvidenceRepository({
    this.attempts = const <AttemptEvidence>[],
    this.failReads = 0,
    this.failSigns = 0,
  });

  final List<AttemptEvidence> attempts;

  /// How many reads fail before one succeeds, and how many signatures fail
  /// before one is answered - the two failures the page treats differently.
  int failReads;
  int failSigns;

  final List<String> exams = <String>[];
  final List<String> signed = <String>[];
  int reads = 0;

  @override
  Future<List<AttemptEvidence>> listExamEvidence(String examId) async {
    reads++;
    exams.add(examId);
    if (failReads > 0) {
      failReads--;
      throw const EvidenceException(
        'Could not read the evidence: Backend unavailable',
      );
    }
    return attempts;
  }

  @override
  Future<String?> signedStillUrl(String snapshotUrl) async {
    signed.add(snapshotUrl);
    if (failSigns > 0) {
      failSigns--;
      return null;
    }
    return 'https://storage.invalid/signed/$snapshotUrl';
  }
}
