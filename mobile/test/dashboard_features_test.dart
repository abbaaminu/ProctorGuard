import 'dart:convert';

import 'package:exam_proctor/features/dashboard/data/repositories/dashboard_repository_impl.dart';
import 'package:exam_proctor/features/dashboard/domain/entities/analytics_report.dart';
import 'package:exam_proctor/features/dashboard/domain/entities/submission_reset_result.dart';
import 'package:exam_proctor/features/dashboard/domain/repositories/dashboard_repository.dart';
import 'package:exam_proctor/features/dashboard/presentation/pages/analytics_page.dart';
import 'package:exam_proctor/features/dashboard/presentation/providers/dashboard_providers.dart';
import 'package:exam_proctor/features/dashboard/presentation/pages/supervisor_dashboard_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('analytics report', () {
    test('rolls up attempts and recent incidents by exam', () async {
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/exams')) {
          return '[{"id":"exam-1","title":"Biology"}]';
        }
        if (request.url.path.endsWith('/exam_submissions')) {
          return '''
            [
              {"id":"attempt-1","exam_id":"exam-1","status":"submitted","score":80},
              {"id":"attempt-2","exam_id":"exam-1","status":"ongoing","score":null},
              {"id":"attempt-3","exam_id":"exam-1","status":"disqualified","score":null}
            ]
          ''';
        }
        if (request.url.path.endsWith('/proctoring_logs')) {
          return '''
            [
              {"submission_id":"attempt-1"},
              {"submission_id":"attempt-1"},
              {"submission_id":"missing-attempt"}
            ]
          ''';
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      });
      final repository = DashboardRepositoryImpl(_client(transport));

      final report = await repository.getAnalytics();

      expect(report.attempts, 3);
      expect(report.completed, 1);
      expect(report.disqualified, 1);
      expect(report.disqualificationRate, 50);
      expect(report.incidents, 2);
      expect(report.averageScore, 80);
      expect(report.exams.single.title, 'Biology');
      expect(report.exams.single.scoredAttempts, 1);
    });

    testWidgets('renders staff analytics and retries a failed read', (
      tester,
    ) async {
      final repository = _FakeDashboardRepository(
        error: const DashboardException('Backend unavailable'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardRepositoryProvider.overrideWithValue(repository),
          ],
          child: const MaterialApp(home: AnalyticsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Backend unavailable'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('Attempts'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Biology'), findsOneWidget);
      expect(repository.reads, 2);
    });
  });

  group('console home button', () {
    testWidgets('Home returns to the landing page from any depth', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final repository = _FakeDashboardRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            examSubmissionsStreamProvider('exam-1').overrideWith(
              (ref) => Stream.value(<Map<String, dynamic>>[]),
            ),
            liveViolationFeedProvider(
              'exam-1',
            ).overrideWith((ref) => Stream.value(<Map<String, dynamic>>[])),
            accountNamesProvider.overrideWith(
              (ref) => Stream.value(<String, String>{}),
            ),
            dashboardRepositoryProvider.overrideWithValue(repository),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SupervisorDashboardPage(
                          examId: 'exam-1',
                          examTitle: 'Biology',
                        ),
                      ),
                    ),
                    child: const Text('open monitor'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open monitor'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('monitor-home')), findsOneWidget);

      // Another level down: the analytics view is pushed from the monitor, so the
      // stack is landing page -> monitor -> analytics on a real console.
      await tester.tap(find.byKey(const Key('monitor-analytics')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analytics-home')), findsOneWidget);

      // Home goes all the way back to the landing page, not one step back: the
      // whole point is that nobody has to unwind a three-deep stack by hand.
      await tester.tap(find.byKey(const Key('analytics-home')));
      await tester.pumpAndSettle();

      expect(find.text('open monitor'), findsOneWidget);
      expect(find.byKey(const Key('analytics-home')), findsNothing);
      expect(find.byKey(const Key('monitor-home')), findsNothing);
    });
  });

  group('supervisor attempt reset', () {
    test('deletes the attempt before cleaning its snapshot objects', () async {
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/proctoring_logs')) {
          return jsonEncode([
            {
              'snapshot_url':
                  'https://mock.supabase.co/storage/v1/object/public/'
                  'proctor-snapshots/attempt-1/flag%201.jpg',
            },
            {
              'snapshot_url':
                  'https://mock.supabase.co/storage/v1/object/sign/'
                  'proctor-snapshots/attempt-1/flag%201.jpg?token=secret',
            },
            {'snapshot_url': 'https://example.invalid/placeholder.jpg'},
          ]);
        }
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/exam_submissions')) {
          return '[{"id":"attempt-1"}]';
        }
        if (request.url.path.contains('/storage/v1/object/')) return '[]';
        fail('Unexpected request: ${request.method} ${request.url}');
      });
      final repository = DashboardRepositoryImpl(_client(transport));

      final result = await repository.resetSubmission('attempt-1');

      expect(result.incidents, 3);
      expect(result.snapshots, 0);
      expect(transport.requests.map((request) => request.url.path).toList(), [
        '/rest/v1/proctoring_logs',
        '/rest/v1/exam_submissions',
        '/storage/v1/object/proctor-snapshots',
      ]);
      expect(
        transport.bodies.last,
        contains('attempt-1/flag 1.jpg'),
        reason: 'duplicate URLs resolve to one decoded Storage object path',
      );
    });

    test('does not report success when RLS deletes no rows', () async {
      final transport = _FakeTransport((request) {
        if (request.url.path.endsWith('/proctoring_logs')) return '[]';
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/exam_submissions')) {
          return '[]';
        }
        fail('Unexpected request: ${request.method} ${request.url}');
      });
      final repository = DashboardRepositoryImpl(_client(transport));

      await expectLater(
        repository.resetSubmission('attempt-1'),
        throwsA(
          isA<DashboardException>().having(
            (error) => error.message,
            'message',
            contains('deleted nothing'),
          ),
        ),
      );
      expect(
        transport.requests.any(
          (request) => request.url.path.contains('/storage/'),
        ),
        isFalse,
      );
    });
  });

  testWidgets('reset controls are supervisor-only', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final repository = _FakeDashboardRepository();
    final overrides = [
      examSubmissionsStreamProvider('exam-1').overrideWith(
        (ref) => Stream.value([
          {
            'id': 'attempt-1',
            'student_id': 'student-1',
            'status': 'ongoing',
            'score': null,
          },
        ]),
      ),
      liveViolationFeedProvider(
        'exam-1',
      ).overrideWith((ref) => Stream.value(<Map<String, dynamic>>[])),
      accountNamesProvider.overrideWith(
        (ref) => Stream.value({'student-1': 'Aisha Bello'}),
      ),
      dashboardRepositoryProvider.overrideWithValue(repository),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const MaterialApp(
          home: SupervisorDashboardPage(examId: 'exam-1', examTitle: 'Biology'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-attempt-attempt-1')), findsNothing);

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: const MaterialApp(
          home: SupervisorDashboardPage(
            examId: 'exam-1',
            examTitle: 'Biology',
            canResetAttempts: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-attempt-attempt-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reset-attempt-attempt-1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reset Aisha Bello’s attempt?'), findsOneWidget);
    await tester.tap(find.text('Reset attempt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(repository.resets, ['attempt-1']);
    expect(find.textContaining('Attempt reset'), findsOneWidget);
  });
}

SupabaseClient _client(_FakeTransport transport) => SupabaseClient(
  'https://mock.supabase.co',
  'sb_publishable_mock',
  httpClient: transport,
);

class _FakeTransport extends http.BaseClient {
  _FakeTransport(this.respond);

  final String Function(http.BaseRequest request) respond;
  final List<http.BaseRequest> requests = [];
  final List<String> bodies = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(request is http.Request ? utf8.decode(request.bodyBytes) : '');
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(respond(request))),
      200,
      headers: const {'content-type': 'application/json'},
      request: request,
    );
  }
}

class _FakeDashboardRepository implements DashboardRepository {
  _FakeDashboardRepository({this.error});

  final Object? error;
  int reads = 0;
  final List<String> resets = [];

  @override
  Future<AnalyticsReport> getAnalytics() async {
    reads++;
    final failure = error;
    if (failure != null && reads == 1) throw failure;
    return const AnalyticsReport([
      ExamAnalytics(
        examId: 'exam-1',
        title: 'Biology',
        attempts: 3,
        ongoing: 1,
        completed: 1,
        disqualified: 1,
        incidents: 2,
        averageScore: 80,
        scoredAttempts: 1,
      ),
    ]);
  }

  @override
  Future<SubmissionResetResult> resetSubmission(String submissionId) async =>
      _reset(submissionId);

  Future<SubmissionResetResult> _reset(String submissionId) async {
    resets.add(submissionId);
    return const SubmissionResetResult(incidents: 1, snapshots: 1);
  }
}
