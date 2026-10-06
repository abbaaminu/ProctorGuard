import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/presentation/providers/exam_providers.dart';
import 'package:proctorguard/features/exam/presentation/widgets/published_exam_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Optional exam scheduling, on the two sides that meet a student:
///
///  * the **entity** — `exams.starts_at` / `ends_at` read into a window, the
///    labels a tile prints, and the instant-based "is it open" the portal asks;
///  * the **list** — a tile the window has not reached yet (or has passed) is
///    inert and says why, while the supervisor's picker — the other caller of
///    the same widget — deliberately keeps offering it.
///
/// The database is what actually enforces the window
/// (`submissions_insert_own_ongoing`, pinned in `schema_contract_test.dart`);
/// everything here is the presentation that has to agree with it.
void main() {
  // One fixed instant for the whole file, and every window is built relative to
  // it: a test that read the wall clock would be a test that fails at 17:00.
  final now = DateTime(2026, 1, 5, 12);

  Exam examAt({
    String id = 'exam-1',
    DateTime? startsAt,
    DateTime? endsAt,
  }) =>
      Exam(
        id: id,
        title: 'CS101: Computer Science Fundamentals',
        createdBy: 'lecturer-1',
        durationMinutes: 60,
        isPublished: true,
        startsAt: startsAt,
        endsAt: endsAt,
      );

  group('Exam window', () {
    test('a row with no bounds is an unscheduled paper, not an error', () {
      final exam = Exam.fromMap(<String, dynamic>{
        'id': 'exam-1',
        'title': 'CS101',
        'created_by': 'lecturer-1',
        'duration_minutes': 60,
        'is_published': true,
      });

      expect(exam.startsAt, isNull);
      expect(exam.endsAt, isNull);
      expect(exam.isScheduled, isFalse);
      expect(exam.scheduleLabel, 'Anytime');
      // The reading that cannot lock anybody out of a paper they were told to
      // sit, which is also what a database from before the columns gives.
      expect(exam.isOpenAt(now), isTrue);
      expect(exam.closedReason(now), isNull);
    });

    test('a timestamptz string is read as the instant it names', () {
      final exam = Exam.fromMap(<String, dynamic>{
        'id': 'exam-1',
        'title': 'CS101',
        'created_by': 'lecturer-1',
        'duration_minutes': 60,
        'is_published': true,
        'starts_at': '2026-01-05T09:00:00+00:00',
        'ends_at': '2026-01-05T17:00:00+00:00',
      });

      expect(exam.startsAt?.toUtc(), DateTime.utc(2026, 1, 5, 9));
      expect(exam.endsAt?.toUtc(), DateTime.utc(2026, 1, 5, 17));
      expect(exam.isScheduled, isTrue);
    });

    test('an unparseable bound is "no bound", never a throw', () {
      final exam = Exam.fromMap(<String, dynamic>{
        'id': 'exam-1',
        'title': 'CS101',
        'created_by': 'lecturer-1',
        'duration_minutes': 60,
        'is_published': true,
        'starts_at': 'yesterday-ish',
        'ends_at': 0,
      });

      expect(exam.startsAt, isNull);
      expect(exam.endsAt, isNull);
      expect(exam.isOpenAt(now), isTrue);
    });

    test('the bounds are inclusive at their own instant', () {
      final exam = examAt(
        startsAt: DateTime(2026, 1, 5, 12),
        endsAt: DateTime(2026, 1, 5, 17),
      );

      // Opens at 12:00, so 12:00:00.000 is already inside — matching the
      // policy's `now() >= e.starts_at`.
      expect(exam.isOpenAt(DateTime(2026, 1, 5, 12)), isTrue);
      expect(exam.isOpenAt(DateTime(2026, 1, 5, 11, 59, 59)), isFalse);
      // And closed *at* the closing instant: the paper is spent then, not one
      // millisecond later.
      expect(exam.closesAt(DateTime(2026, 1, 5, 17)), isTrue);
      expect(exam.isOpenAt(DateTime(2026, 1, 5, 16, 59)), isTrue);
      expect(exam.isOpenAt(DateTime(2026, 1, 5, 17)), isFalse);
    });

    test('a one-sided window only closes the side it names', () {
      final opensOnly = examAt(startsAt: DateTime(2026, 1, 6, 9));
      expect(opensOnly.isOpenAt(now), isFalse);
      expect(opensOnly.closesAt(DateTime(2030)), isFalse);
      expect(
        opensOnly.isOpenAt(DateTime(2030)),
        isTrue,
        reason: 'no closing bound means it never closes',
      );

      final closesOnly = examAt(endsAt: DateTime(2026, 1, 5, 17));
      expect(closesOnly.isOpenAt(DateTime(2020)), isTrue);
      expect(closesOnly.isOpenAt(now), isTrue);
      expect(closesOnly.isOpenAt(DateTime(2026, 1, 5, 17)), isFalse);
    });

    test('the label prints the window a student plans around', () {
      expect(examAt().scheduleLabel, 'Anytime');
      expect(
        examAt(startsAt: DateTime(2026, 1, 5, 9)).scheduleLabel,
        'Opens 5 Jan 2026, 09:00',
      );
      expect(
        examAt(endsAt: DateTime(2026, 1, 5, 17)).scheduleLabel,
        'Closes 5 Jan 2026, 17:00',
      );
      // Both bounds on one day print the date once: "09:00 – 17:00" is a
      // sitting, and an overnight window says both dates.
      expect(
        examAt(
          startsAt: DateTime(2026, 1, 5, 9),
          endsAt: DateTime(2026, 1, 5, 17),
        ).scheduleLabel,
        '5 Jan 2026, 09:00 – 17:00',
      );
      expect(
        examAt(
          startsAt: DateTime(2026, 1, 5, 9),
          endsAt: DateTime(2026, 1, 6, 8),
        ).scheduleLabel,
        '5 Jan 2026, 09:00 – 6 Jan 2026, 08:00',
      );
    });

    test('closedReason names the bound that is in the way', () {
      expect(
        examAt(startsAt: DateTime(2026, 1, 6, 9)).closedReason(now),
        'It opens 6 Jan 2026, 09:00.',
      );
      expect(
        examAt(endsAt: DateTime(2026, 1, 5, 9)).closedReason(now),
        'It closed 5 Jan 2026, 09:00.',
      );
      expect(examAt().closedReason(now), isNull);
    });

    test('the window is part of equality, so a cached list cannot go stale', () {
      expect(examAt(), isNot(examAt(startsAt: DateTime(2026, 1, 5, 9))));
      expect(
        examAt(startsAt: DateTime(2026, 1, 5, 9)),
        examAt(startsAt: DateTime(2026, 1, 5, 9)),
      );
    });
  });

  /// Renders the list the way one of its two callers does, and returns the
  /// exams that were actually opened — the record of which tiles were live.
  Future<List<Exam>> pumpList(
    WidgetTester tester,
    List<Exam> exams, {
    bool lockWhenNotOpen = true,
  }) async {
    final opened = <Exam>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          publishedExamsProvider.overrideWith((ref) => exams),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PublishedExamList(
              onOpen: opened.add,
              lockWhenNotOpen: lockWhenNotOpen,
              clock: () => now,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  group('the portal locks what it cannot offer', () {
    testWidgets('an unscheduled paper is offered any time', (tester) async {
      final opened = await pumpList(tester, <Exam>[examAt()]);

      expect(find.text('60 minutes'), findsOneWidget);
      // No window line and no lock: "Anytime" is the norm on this list, so
      // saying it on every tile would be noise.
      expect(find.byKey(const Key('exam-window-exam-1')), findsNothing);
      expect(find.byKey(const Key('exam-locked-exam-1')), findsNothing);

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();
      expect(opened.single.id, 'exam-1');
    });

    testWidgets('a paper that has not opened yet is inert, and says when it opens',
        (tester) async {
      final opened = await pumpList(
        tester,
        <Exam>[examAt(startsAt: DateTime(2026, 1, 6, 9))],
      );

      expect(find.text('Opens 6 Jan 2026, 09:00'), findsOneWidget);
      expect(find.text('It opens 6 Jan 2026, 09:00.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty, reason: 'nothing to tap until the window opens');
    });

    testWidgets('a closed paper is inert, and names the close', (tester) async {
      final opened = await pumpList(
        tester,
        <Exam>[
          examAt(
            startsAt: DateTime(2026, 1, 4, 9),
            endsAt: DateTime(2026, 1, 5, 9),
          ),
        ],
      );

      expect(find.text('4 Jan 2026, 09:00 – 5 Jan 2026, 09:00'), findsOneWidget);
      expect(find.text('It closed 5 Jan 2026, 09:00.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
    });

    testWidgets('an open scheduled paper shows its window and stays startable',
        (tester) async {
      final opened = await pumpList(
        tester,
        <Exam>[
          examAt(
            startsAt: DateTime(2026, 1, 5, 9),
            endsAt: DateTime(2026, 1, 5, 17),
          ),
        ],
      );

      expect(find.text('5 Jan 2026, 09:00 – 17:00'), findsOneWidget);
      expect(find.byKey(const Key('exam-locked-exam-1')), findsNothing);

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();
      expect(opened.single.id, 'exam-1');
    });

    testWidgets('the supervisor picker still offers a closed paper',
        (tester) async {
      // The monitor is opened on a sitting that has closed (and on one that has
      // not started) on purpose, so the window is *shown* but never a lock.
      final opened = await pumpList(
        tester,
        <Exam>[examAt(endsAt: DateTime(2026, 1, 5, 9))],
        lockWhenNotOpen: false,
      );

      expect(find.text('Closes 5 Jan 2026, 09:00'), findsOneWidget);
      expect(find.byKey(const Key('exam-locked-exam-1')), findsNothing);

      await tester.tap(find.byKey(const Key('exam-exam-1')));
      await tester.pumpAndSettle();
      expect(opened.single.id, 'exam-1');
    });
  });
}
