import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/supervision/domain/entities/supervisor_assignment.dart';
import 'package:proctorguard/features/supervision/domain/repositories/supervision_repository.dart';
import 'package:proctorguard/features/supervision/presentation/pages/assign_supervisors_page.dart';
import 'package:proctorguard/features/supervision/presentation/providers/supervision_providers.dart';

/// Records what the screen asked the database to do, so the test can assert the
/// *write* rather than only what the page painted.
class _RecordingRepository implements SupervisionRepository {
  final List<String> assigned = <String>[];
  final List<String> unassigned = <String>[];
  SupervisionException? failure;

  @override
  Future<void> assign({
    required String examId,
    required String supervisorId,
  }) async {
    if (failure != null) throw failure!;
    assigned.add('$examId/$supervisorId');
  }

  @override
  Future<void> unassign({
    required String examId,
    required String supervisorId,
  }) async {
    if (failure != null) throw failure!;
    unassigned.add('$examId/$supervisorId');
  }

  @override
  Future<List<Exam>> listExams() async => const <Exam>[];

  @override
  Future<List<SupervisorAssignment>> listAssignments() async =>
      const <SupervisorAssignment>[];
}

Exam _exam(String id, String title, {bool published = true}) => Exam(
      id: id,
      title: title,
      createdBy: 'lecturer-1',
      durationMinutes: 60,
      isPublished: published,
    );

ManagedAccount _account(String id, String name, UserRole role) =>
    ManagedAccount(
      id: id,
      email: '$id@test.local',
      fullName: name,
      role: role,
    );

void main() {
  late _RecordingRepository repository;

  setUp(() => repository = _RecordingRepository());

  ProviderContainer container(
    List<Exam> exams,
    List<SupervisorAssignment> rows,
    List<ManagedAccount> accounts,
  ) =>
      ProviderContainer(overrides: [
        supervisionRepositoryProvider.overrideWithValue(repository),
        supervisionExamsProvider.overrideWith((ref) => exams),
        supervisorAssignmentsProvider.overrideWith((ref) => rows),
        managedAccountsProvider.overrideWith((ref) => accounts),
      ]);

  Future<void> pump(WidgetTester tester, ProviderContainer scope) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: const MaterialApp(home: AssignSupervisorsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the papers with the supervisors already on them',
      (tester) async {
    final scope = container(
      [_exam('exam-1', 'CS101'), _exam('exam-2', 'MAT201', published: false)],
      [const SupervisorAssignment(examId: 'exam-1', supervisorId: 'sup-1')],
      [
        _account('sup-1', 'Dr Ada Nwosu', UserRole.supervisor),
        _account('sup-2', 'Musa Bello', UserRole.supervisor),
        _account('lec-1', 'Dr Tunde', UserRole.lecturer),
      ],
    );
    addTearDown(scope.dispose);

    await pump(tester, scope);

    expect(find.text('CS101'), findsOneWidget);
    // Drafts are listed too: a sitting is invigilated before publication.
    expect(find.text('MAT201'), findsOneWidget);
    expect(find.text('Draft - not published yet'), findsOneWidget);
    // The assigned supervisor is named on the paper; the unassigned one says so.
    expect(find.text('Supervisor: Dr Ada Nwosu'), findsOneWidget);
    expect(find.textContaining('No supervisor assigned'), findsOneWidget);
  });

  testWidgets('ticking a supervisor assigns them, un-ticking revokes',
      (tester) async {
    final scope = container(
      [_exam('exam-1', 'CS101')],
      const <SupervisorAssignment>[],
      [
        _account('sup-2', 'Musa Bello', UserRole.supervisor),
        _account('lec-1', 'Dr Tunde', UserRole.lecturer),
      ],
    );
    addTearDown(scope.dispose);

    await pump(tester, scope);

    await tester.tap(find.byKey(const Key('assign-manage-exam-1')));
    await tester.pumpAndSettle();

    // Only supervisor accounts are offered - a lecturer is not assignable, and the
    // database would refuse the row anyway (`guard_supervisor_assignment()`).
    expect(find.byKey(const Key('assign-toggle-exam-1-sup-2')), findsOneWidget);
    expect(find.byKey(const Key('assign-toggle-exam-1-lec-1')), findsNothing);

    await tester.tap(find.byKey(const Key('assign-toggle-exam-1-sup-2')));
    await tester.pumpAndSettle();
    expect(repository.assigned, <String>['exam-1/sup-2']);

    await tester.tap(find.byKey(const Key('assign-toggle-exam-1-sup-2')));
    await tester.pumpAndSettle();
    expect(repository.unassigned, <String>['exam-1/sup-2']);

    await tester.tap(find.byKey(const Key('assign-done')));
    await tester.pumpAndSettle();
  });

  testWidgets('a refused assignment says why and leaves the tick alone',
      (tester) async {
    repository.failure = const SupervisionException(
      'That account is not a supervisor.',
    );
    final scope = container(
      [_exam('exam-1', 'CS101')],
      const <SupervisorAssignment>[],
      [_account('sup-2', 'Musa Bello', UserRole.supervisor)],
    );
    addTearDown(scope.dispose);

    await pump(tester, scope);
    await tester.tap(find.byKey(const Key('assign-manage-exam-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assign-toggle-exam-1-sup-2')));
    await tester.pumpAndSettle();

    expect(find.text('That account is not a supervisor.'), findsOneWidget);
    expect(repository.assigned, isEmpty);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('assign-toggle-exam-1-sup-2')),
          )
          .value,
      isFalse,
      reason: 'a refused write must not leave the dialog claiming it worked',
    );
  });

  testWidgets('says there is nothing to assign when no paper exists',
      (tester) async {
    final scope = container(
      const <Exam>[],
      const <SupervisorAssignment>[],
      [_account('sup-2', 'Musa Bello', UserRole.supervisor)],
    );
    addTearDown(scope.dispose);

    await pump(tester, scope);

    expect(find.byKey(const Key('assign-supervisors-empty')), findsOneWidget);
  });

  testWidgets('prompts for a supervisor account when there is none',
      (tester) async {
    final scope = container(
      [_exam('exam-1', 'CS101')],
      const <SupervisorAssignment>[],
      [_account('lec-1', 'Dr Tunde', UserRole.lecturer)],
    );
    addTearDown(scope.dispose);

    await pump(tester, scope);

    expect(
      find.byKey(const Key('assign-supervisors-no-supervisors')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('assign-exam-exam-1')), findsOneWidget);
  });
}
