import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:proctorguard/features/admin/data/repositories/admin_user_repository_impl.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/entities/student_roster.dart';
import 'package:proctorguard/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/authoring/data/repositories/question_authoring_repository_impl.dart';
import 'package:proctorguard/features/authoring/domain/entities/authored_question.dart';
import 'package:proctorguard/features/authoring/domain/repositories/question_authoring_repository.dart';
import 'package:proctorguard/features/exam/data/repositories/consent_repository_impl.dart';
import 'package:proctorguard/features/exam/data/repositories/exam_repository_impl.dart';
import 'package:proctorguard/features/exam/domain/entities/proctor_consent.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/exam/presentation/providers/exam_session_controller.dart';
import 'package:proctorguard/features/proctoring/data/repositories/proctoring_repository_impl.dart';
import 'package:proctorguard/features/proctoring/domain/entities/heartbeat.dart';
import 'package:proctorguard/features/proctoring/domain/entities/proctoring_risk.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the client ↔ database contract from `supabase/schema.sql` so the Flutter
/// side cannot drift from the unified production schema:
///  * `register_violation` argument names/values and its returned
///    `warning_count` / `disqualified` fields;
///  * every `action_type` string the check constraint allows (the five camera
///    and lifecycle ones plus the six enterprise lockdown/device ones);
///  * the `proctor-snapshots` upload path convention and JPEG content type;
///  * the admin roster's `profiles` reads/writes and account Edge Function
///    payloads, against the `user_role` enum and `full_name`.
class _RecordingTransport extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<String> bodies = <String>[];
  String responseBody = '[]';

  /// Status the recorded response answers with — 200 unless a test needs an
  /// error (a PostgREST 403, or a function's 40x) to be seen by the client.
  int statusCode = 200;

  /// Per-request body, for the screens that read several tables in one call
  /// (authoring loads the paper, the attempts, the marks and the names): the
  /// answer is chosen by the request's path, and [responseBody] stays the
  /// fallback so every existing use of this harness is unchanged.
  String Function(http.BaseRequest request)? bodyFor;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(request is http.Request ? utf8.decode(request.bodyBytes) : '');
    return http.StreamedResponse(
      Stream<List<int>>.value(
        utf8.encode(bodyFor?.call(request) ?? responseBody),
      ),
      statusCode,
      headers: const <String, String>{'content-type': 'application/json'},
      request: request,
    );
  }
}

void main() {
  late _RecordingTransport transport;
  late SupabaseClient client;

  setUp(() {
    transport = _RecordingTransport();
    client = SupabaseClient(
      'https://mock.supabase.co',
      'sb_publishable_mock',
      httpClient: transport,
    );
  });

  group('register_violation RPC payload', () {
    test('sends exactly the schema argument names and maps the result', () async {
      transport.responseBody = '[{"warning_count": 2, "disqualified": false}]';
      final repo = ProctoringRepositoryImpl(client);

      final result = await repo.logViolation(
        submissionId: 'sub-1',
        violation: Violation(
          type: ViolationType.lookingAway,
          timestamp: DateTime.utc(2026, 1, 1, 10, 30),
          // A stored snapshot reference is the bucket-relative *path* the upload
          // returned, not a URL: the bucket is private and a signed URL would
          // expire long before the evidence is reviewed.
          snapshotUrl: 'sub-1/looking_away_1.jpg',
          clientEventId: '9f1a4d0e-0f6b-4a1e-9a2b-6c2d2b7a3f11',
        ),
      );

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/register_violation');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{
        'p_submission_id',
        'p_action_type',
        'p_snapshot_url',
        'p_client_timestamp',
        'p_client_event_id',
      });
      expect(body['p_submission_id'], 'sub-1');
      expect(body['p_action_type'], 'looking_away');
      expect(body['p_snapshot_url'], 'sub-1/looking_away_1.jpg');
      // The *detection* time travels with the row, so a violation delivered late
      // by the offline queue is still placed correctly in the audit trail
      // (`timestamp` on the row remains the server's receipt time).
      expect(body['p_client_timestamp'], '2026-01-01T10:30:00.000Z');
      // Idempotency key: replaying this exact call must not add a second strike.
      expect(body['p_client_event_id'], '9f1a4d0e-0f6b-4a1e-9a2b-6c2d2b7a3f11');

      expect(result.warningCount, 2);
      expect(result.disqualified, isFalse);
    });

    test('reports the third strike as disqualified', () async {
      transport.responseBody = '[{"warning_count": 3, "disqualified": true}]';
      final repo = ProctoringRepositoryImpl(client);

      final result = await repo.logViolation(
        submissionId: 'sub-1',
        violation: Violation(
          type: ViolationType.noFace,
          timestamp: DateTime.utc(2026),
        ),
      );

      expect(result.warningCount, 3);
      expect(result.disqualified, isTrue);

      // The optional argument is still sent (as an explicit null) so the RPC
      // never has to guess.
      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body['p_snapshot_url'], isNull);
    });

    test('every ViolationType maps to an allowed action_type', () {
      expect(
        ViolationType.values.map((type) => type.dbValue).toList(),
        <String>[
          'looking_away',
          'multiple_faces',
          'no_face',
          'app_minimized',
          'audio_noise',
          'copy_paste_attempt',
          'right_click_blocked',
          'devtools_detected',
          'secondary_display_detected',
          'virtual_camera_detected',
          'idle_afk',
        ],
      );
    });

    test('fromDb is the exact inverse, so a queued row is never dropped', () {
      // A queued violation whose type cannot be mapped is dropped by the offline
      // sync service rather than mis-logged, so the round-trip has to be total
      // over the enum - including the six enterprise values.
      for (final type in ViolationType.values) {
        expect(ViolationType.fromDb(type.dbValue), type);
      }
    });

    test('schema.sql allows every action_type the client can send', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // `register_violation` inserts into a check-constrained column, so a value
      // the enum knows and the constraint does not is a 23514 raised at the
      // moment of the strike - the worst possible time to discover drift.
      for (final type in ViolationType.values) {
        expect(
          sql,
          contains("'${type.dbValue}'"),
          reason: '${type.dbValue} is missing from the schema',
        );
      }
    });

    test('server enforces answer deadlines and scopes staff intervention', () {
      final sql = schemaSql();
      if (sql == null) return;

      // The deadline is answered in one place - `attempt_deadline()`, which caps
      // the attempt's own duration by the exam window - so no copy of the raw
      // arithmetic may remain: a second copy is how a scheduled paper's hard
      // close silently stops applying to an answer write.
      expect(
        RegExp(r'public\.attempt_deadline\(').allMatches(sql).length,
        greaterThanOrEqualTo(5),
        reason: 'the definition, its grants, and the calls that depend on it',
      );
      expect(sql, isNot(contains('clock_timestamp() < s.started_at')));
      expect(
        sql,
        contains('clock_timestamp() < public.attempt_deadline('),
        reason: 'both answer-merge RPCs measure the same deadline',
      );
      expect(
        sql,
        contains(
          'public.attempt_deadline(v_started_at, v_duration_minutes, v_ends_at)',
        ),
        reason: 'the close records the window-aware deadline',
      );
      expect(sql, contains('v_submitted_at := least('));
      expect(sql, contains('authentication is required to submit an exam'));
      expect(sql, contains("and answers = '{}'::jsonb"));
      expect(sql, contains('and submitted_at is null'));
      expect(sql, contains('and started_at = now()'));
      final violationStart = sql.indexOf(
        'create or replace function public.register_violation(',
      );
      final answerMergeStart = sql.indexOf(
        '-- Race-safe partial-answer merge (RPC)',
        violationStart,
      );
      final violationRpc = sql.substring(violationStart, answerMergeStart);
      expect(violationRpc, contains('and s.student_id = auth.uid()'));
      expect(violationRpc, isNot(contains('or public.is_staff()')));
      expect(
        sql,
        contains(
          'revoke execute on function public.submit_exam(uuid, boolean) from public, anon',
        ),
      );
      expect(sql, contains("role in ('admin', 'supervisor')"));
      expect(
        File(
          '../supabase/migrations/secure_exam_access_and_deadlines.sql',
        ).existsSync(),
        isTrue,
        reason: 'existing projects need an explicit hardening migration',
      );
    });
  });

  group('submit_exam RPC payload', () {
    test(
      'a closed/deadline-expired answer becomes a terminal local warning',
      () async {
        transport
          ..statusCode = 400
          ..responseBody = jsonEncode(<String, dynamic>{
            'code': '55000',
            'message':
                'submission is not active or its exam deadline has passed',
            'details': null,
            'hint': null,
          });
        final repo = ExamRepositoryImpl(client);

        await expectLater(
          repo.saveAnswer(
            submissionId: 'sub-1',
            questionId: 'q-1',
            selectedOption: 2,
          ),
          throwsA(isA<AnswerWriteRejected>()),
        );
      },
    );

    test('submitExam asks the server to grade and close the attempt', () async {
      transport.responseBody =
          '[{"result_status":"submitted","final_score":4}]';
      final repo = ExamRepositoryImpl(client);

      final result = await repo.submitExam('sub-1');

      // The row the RPC answers with is the mark the student is shown the moment
      // the attempt closes. `awaitingMarking` / `maxScore` are added by the
      // session screen, which is the only place that knows the paper — so until
      // it has said so, the result claims nothing final.
      expect(result.status, SubmissionStatus.submitted);
      expect(result.score, 4);
      expect(result.awaitingMarking, isTrue);
      expect(result.hasFinalScore, isFalse);

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/submit_exam');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{'p_submission_id'});
      expect(body['p_submission_id'], 'sub-1');

      // The return shape the client reads back is the schema's own: `result_status`
      // plus `final_score`. Drift here would silently turn every result into
      // "submitted, unmarked".
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase
      expect(
        sql,
        contains('returns table(result_status text, final_score numeric)'),
      );
    });

    test(
      'a final score is only claimed once the paper says it is final',
      () async {
        transport.responseBody =
            '[{"result_status":"submitted","final_score":7}]';
        final repo = ExamRepositoryImpl(client);

        final objective = (await repo.submitExam(
          'sub-1',
        )).withPaper(awaitingMarking: false, maxScore: 10);
        expect(objective.hasFinalScore, isTrue);
        // "7 of 10", not "7.0 of 10": a whole-number mark is the common case and
        // the decimal reads like a bug.
        expect(objective.scoreLabel, '7 of 10');

        // The same server row on a paper with an essay on it stays provisional —
        // the number is only the automatic half until a lecturer marks the rest.
        final withEssay = (await repo.submitExam(
          'sub-1',
        )).withPaper(awaitingMarking: true, maxScore: 10);
        expect(withEssay.hasFinalScore, isFalse);
        expect(withEssay.score, 7);
      },
    );

    test('a body the client cannot read becomes "submitted, unmarked"', () async {
      // The attempt is already closed server-side by the time this is parsed, so
      // throwing would replace a finished exam with an error screen.
      transport.responseBody = 'null';

      final result = await ExamRepositoryImpl(client).submitExam('sub-1');

      expect(result.status, SubmissionStatus.submitted);
      expect(result.score, isNull);
      expect(result.hasFinalScore, isFalse);
    });

    test(
      'markDisqualified flags the close so the server never grades',
      () async {
        transport.responseBody =
            '[{"result_status":"disqualified","final_score":null}]';
        final repo = ExamRepositoryImpl(client);

        await repo.markDisqualified('sub-1');

        expect(transport.requests.single.url.path, '/rest/v1/rpc/submit_exam');

        final body =
            jsonDecode(transport.bodies.single) as Map<String, dynamic>;
        expect(body.keys.toSet(), <String>{
          'p_submission_id',
          'p_disqualified',
        });
        expect(body['p_disqualified'], isTrue);
      },
    );

    test(
      'closing an attempt never PATCHes exam_submissions directly',
      () async {
        // schema.sql §4 has no student UPDATE policy on the table, so a direct
        // write would be rejected by RLS — submit_exam is the only writer.
        transport.responseBody =
            '[{"result_status":"submitted","final_score":0}]';
        final repo = ExamRepositoryImpl(client);

        await repo.submitExam('sub-1');

        expect(
          transport.requests.where((request) => request.method == 'PATCH'),
          isEmpty,
        );
      },
    );
  });

  group('admin profiles contract', () {
    const String adminId = '44444444-4444-4444-8444-444444444444';
    const String aishaId = '22222222-2222-4222-8222-222222222222';

    test(
      'listAccounts reads profiles oldest-first and maps every row',
      () async {
        transport.responseBody = jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': adminId,
            'email': 'root@proctor.test',
            'full_name': 'Root Admin',
            'role': 'admin',
            'created_at': '2026-01-01T08:00:00.000Z',
          },
          <String, dynamic>{
            'id': aishaId,
            'email': 'aisha.bello@proctor.test',
            // Blank, not null: `profiles.full_name` is `not null`.
            'full_name': '   ',
            'role': 'student',
          },
        ]);
        final repo = AdminUserRepositoryImpl(client);

        final List<ManagedAccount> accounts = await repo.listAccounts();

        final request = transport.requests.single;
        expect(request.method, 'GET');
        expect(request.url.path, '/rest/v1/profiles');
        expect(
          request.url.queryParameters['order'],
          // postgrest-dart appends `nullslast`, so a row with no `created_at`
          // sorts after the seeded accounts instead of jumping to the top.
          'created_at.asc.nullslast',
        );
        expect(accounts.map((account) => account.role).toList(), <UserRole>[
          UserRole.admin,
          UserRole.student,
        ]);
        expect(accounts.first.createdAt, DateTime.utc(2026, 1, 1, 8));
        // An unnamed row keeps its address, the same fallback the gate uses.
        expect(accounts.last.displayName, 'aisha.bello@proctor.test');
      },
    );

    test(
      'a roster row whose role this build does not know is refused',
      () async {
        // Not rendered as a familiar role: `UserRole.fromDb` throws, and the
        // repository turns that into the "update the app" message.
        transport.responseBody = jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': adminId,
            'email': 'root@proctor.test',
            'role': 'principal',
          },
        ]);

        await expectLater(
          AdminUserRepositoryImpl(client).listAccounts(),
          throwsA(
            isA<AdminAccountException>().having(
              (error) => error.message,
              'message',
              contains('does not know about'),
            ),
          ),
        );
      },
    );

    test(
      'updateRole PATCHes profiles and demands the updated row back',
      () async {
        transport.responseBody = jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{'id': aishaId, 'role': 'supervisor'},
        ]);
        final repo = AdminUserRepositoryImpl(client);

        await repo.updateRole(userId: aishaId, role: UserRole.supervisor);

        final request = transport.requests.single;
        expect(request.method, 'PATCH');
        expect(request.url.path, '/rest/v1/profiles');
        expect(request.url.queryParameters['id'], 'eq.$aishaId');
        // `.select()` is what makes "no row matched" visible instead of silent.
        expect(request.url.queryParameters['select'], '*');
        expect(jsonDecode(transport.bodies.single), <String, dynamic>{
          'role': 'supervisor',
        });
      },
    );

    test(
      'an update that matched no row is an error, not a silent success',
      () async {
        transport.responseBody = '[]'; // e.g. deleted between list and tap

        expect(
          AdminUserRepositoryImpl(
            client,
          ).updateRole(userId: aishaId, role: UserRole.student),
          throwsA(isA<AdminAccountException>()),
        );
      },
    );

    test('an RLS refusal becomes prose for the administrator', () async {
      // A caller who is not an admin passes the client-side form and is stopped
      // by `profiles_admin_all` / `guard_user_role_change` — a 42501.
      transport.statusCode = 403;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'code': '42501',
        'message':
            'new row violates row-level security policy for table "profiles"',
        'details': null,
        'hint': null,
      });

      expect(
        AdminUserRepositoryImpl(
          client,
        ).updateRole(userId: aishaId, role: UserRole.admin),
        throwsA(
          isA<AdminAccountException>().having(
            (error) => error.message,
            'message',
            'Only an administrator may change accounts.',
          ),
        ),
      );
    });

    test(
      'deleteAccount invokes the server-side account deletion function',
      () async {
        transport.responseBody = jsonEncode(<String, dynamic>{
          'id': aishaId,
          'removed': {'exams': 0, 'submissions': 2},
        });

        await AdminUserRepositoryImpl(client).deleteAccount(userId: aishaId);

        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(request.url.path, '/functions/v1/admin-delete-user');
        expect(jsonDecode(transport.bodies.single), <String, dynamic>{
          'id': aishaId,
        });
      },
    );
  });

  group('admin-create-user contract', () {
    Future<ManagedAccount> createLecturer() =>
        AdminUserRepositoryImpl(client).createAccount(
          email: 'ada.nwosu@proctor.test',
          password: 'Proctor123!',
          fullName: 'Dr. Ada Nwosu',
          role: UserRole.lecturer,
        );

    test('createAccount posts the trimmed payload to the Edge Function', () async {
      // The function answers 200 with the created row; `functions.invoke` treats
      // any 2xx as success, so the status itself is not load-bearing.
      transport.statusCode = 200;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'new-1',
        'email': 'ada.nwosu@proctor.test',
        'full_name': 'Dr. Ada Nwosu',
        'role': 'lecturer',
      });
      final repo = AdminUserRepositoryImpl(client);

      final account = await repo.createAccount(
        email: '  ada.nwosu@proctor.test ',
        password: 'Proctor123!',
        fullName: '  Dr. Ada Nwosu ',
        role: UserRole.lecturer,
      );

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/functions/v1/admin-create-user');
      // The function validates these names itself, so the body is the contract.
      expect(jsonDecode(transport.bodies.single), <String, dynamic>{
        'email': 'ada.nwosu@proctor.test',
        'password': 'Proctor123!',
        'full_name': 'Dr. Ada Nwosu',
        'role': 'lecturer',
      });
      expect(account.role, UserRole.lecturer);
      expect(account.displayName, 'Dr. Ada Nwosu');
    });

    test('a refused creation keeps the function\'s own wording', () async {
      transport.statusCode = 403;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'error': 'Only an administrator can create accounts.',
      });

      await expectLater(
        createLecturer(),
        throwsA(
          isA<AdminAccountException>().having(
            (error) => error.message,
            'message',
            'Only an administrator can create accounts.',
          ),
        ),
      );
    });

    test(
      'an un-deployed function is explained, not reported as a 404',
      () async {
        // What the platform answers for a function that was never deployed: no
        // `error` field, so the status is all the client has to go on.
        transport.statusCode = 404;
        transport.responseBody = jsonEncode(<String, dynamic>{
          'code': 404,
          'message': 'Requested function was not found',
        });

        await expectLater(
          createLecturer(),
          throwsA(
            isA<AdminAccountException>().having(
              (error) => error.message,
              'message',
              contains('not deployed on this project'),
            ),
          ),
        );
      },
    );

    test(
      'a 200 that carries `{ error }` is not mistaken for a new account',
      () async {
        transport.statusCode = 200;
        transport.responseBody = jsonEncode(<String, dynamic>{
          'error': 'ada.nwosu@proctor.test already has an account.',
        });

        await expectLater(
          createLecturer(),
          throwsA(
            isA<AdminAccountException>().having(
              (error) => error.message,
              'message',
              'ada.nwosu@proctor.test already has an account.',
            ),
          ),
        );
      },
    );

    test('the academic labels and the identity number ride in one body', () async {
      transport.statusCode = 200;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'new-2',
        'email': 'ada.nwosu@proctor.test',
        'full_name': 'Dr. Ada Nwosu',
        'role': 'lecturer',
        'faculty': 'Science',
        'department': 'Computer Science',
        'level': '300',
        'staff_id': 'STF-0142',
      });

      final account = await AdminUserRepositoryImpl(client).createAccount(
        email: 'ada.nwosu@proctor.test',
        password: 'Proctor123!',
        fullName: 'Dr. Ada Nwosu',
        role: UserRole.lecturer,
        // Trimmed like every other free-text field: the column stores the label,
        // not the padding somebody's spreadsheet left around it.
        faculty: ' Science ',
        department: 'Computer Science',
        level: '300',
        staffId: ' STF-0142 ',
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body, <String, dynamic>{
        'email': 'ada.nwosu@proctor.test',
        'password': 'Proctor123!',
        'full_name': 'Dr. Ada Nwosu',
        'role': 'lecturer',
        'faculty': 'Science',
        'department': 'Computer Science',
        'level': '300',
        'staff_id': 'STF-0142',
        // No `matric_number`: nothing was stated, and an absent key is how the
        // body says "record nothing" — the column stays NULL either way.
      });
      expect(body.containsKey('matric_number'), isFalse);

      // The row the function answers with is read back leniently, so the page can
      // confirm what was recorded without re-reading the whole roster.
      expect(account.staffId, 'STF-0142');
      expect(account.matricNumber, isNull);
      expect(account.identityNumber, 'STF-0142');
      expect(
        account.academicLabel,
        'Computer Science · Science · 300 Level',
      );
    });

    test('an account created without metadata sends none of its keys', () async {
      transport.statusCode = 200;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'new-3',
        'email': 'ada.nwosu@proctor.test',
        'full_name': 'Dr. Ada Nwosu',
        'role': 'lecturer',
      });

      // What a programmatic caller from before this feature sends: the same four
      // keys and nothing else. The body has to stay byte-identical, because a
      // deployment that has not run the identity migration must still accept it.
      final account = await createLecturer();

      expect(jsonDecode(transport.bodies.single), <String, dynamic>{
        'email': 'ada.nwosu@proctor.test',
        'password': 'Proctor123!',
        'full_name': 'Dr. Ada Nwosu',
        'role': 'lecturer',
      });
      // A row without the columns reads as "not recorded" rather than throwing.
      expect(account.matricNumber, isNull);
      expect(account.staffId, isNull);
      expect(account.identityNumber, isNull);
    });
  });

  group('role contract', () {
    test('the client and the Edge Function agree on the roles and the floor', () {
      // Supabase Auth's default minimum: a shorter password would be accepted
      // by the form and refused after the administrator had already typed it.
      expect(adminMinPasswordLength, AdminUserRepositoryImpl.minPasswordLength);
      expect(adminMinPasswordLength, greaterThanOrEqualTo(6));

      final file = File('../supabase/functions/admin-create-user/index.ts');
      if (!file.existsSync()) return; // a checkout without ../supabase

      final source = file.readAsStringSync();
      // Same four roles, same order, on both sides of the wire.
      final expected = UserRole.values
          .map((role) => '"${role.dbValue}"')
          .join(', ');
      expect(source, contains('const ROLES = [$expected]'));
      // `{ error }` is what `_messageFromFunctionError` reads out of a 4xx.
      expect(source, contains('return json({ error: message }, status, headers);'));
      expect(
        source,
        contains('const MIN_PASSWORD_LENGTH = $adminMinPasswordLength;'),
      );
      // Who may create accounts, and the four keys the 200 answers with — the
      // body `ManagedAccount.fromMap` reads back. The academic labels ride along
      // in the same object when the profile row carries them, so a client from
      // before them simply ignores the extra keys.
      expect(
        source,
        contains('const CREATOR_ROLES: readonly Role[] = ["admin"];'),
      );
      final answeredWith = RegExp(
        r'account: \{[\s\S]*?id: created\.user\.id,\s*'
        r'email: input\.email,\s*'
        r'full_name: input\.fullName,\s*'
        r'role: input\.role,[\s\S]*?\.\.\.input\.academic,',
      );
      expect(
        answeredWith.hasMatch(source),
        isTrue,
        reason: 'the 200 no longer answers the keys ManagedAccount.fromMap reads',
      );
      expect(source, contains('return json(outcome.account);'));

      // The bulk branch: the same per-row answer plus the password the
      // administrator has to hand over, and never a role the body asked for.
      expect(source, contains('temporary_password: outcome.password,'));
      expect(source, contains('role: "student",'));
      // A page the client builds has to be a page this function accepts.
      expect(
        source,
        contains('const MAX_BULK_STUDENTS = ${AdminUserRepository.maxStudentPageSize};'),
      );
    });

    test('schema.sql declares the enum, the column and the policies used', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      expect(sql, contains('create type public.user_role as enum'));
      // Every role the app can render has to exist in the database's enum.
      for (final role in UserRole.values) {
        expect(
          sql,
          contains("'${role.dbValue}'"),
          reason: '${role.dbValue} is missing from the schema',
        );
      }
      // The column behind a roster tile's title (it used to be `name`).
      expect(sql, contains('full_name   text not null'));
      // The policy the roster's read and update ride on, and the trigger that
      // stops an admin from re-roling themselves out of their own account.
      expect(sql, contains('profiles_admin_all'));
      expect(sql, contains('guard_user_role_change'));
    });
  });

  group('attempt-reset tier', () {
    test('the console and is_attempt_resetter() allow exactly the same roles', () {
      // `UserRole.canResetAttempts` is what `role_gate.dart` hands the supervisor
      // dashboard as `canResetAttempts` (and what the lecture console and the
      // admin dashboard ask in their own way); the server grants the three halves
      // of the same action - the DELETE, the snapshot purge and the audit row -
      // through `is_attempt_resetter()`. Drift in either direction is something
      // the user sees: a reset control the server refuses, or an action the
      // server would allow that is never offered.
      final clientRoles = UserRole.values
          .where((role) => role.canResetAttempts)
          .toSet();
      expect(clientRoles, <UserRole>{
        UserRole.admin,
        UserRole.supervisor,
        // The paper's author can clear an attempt on it - the wrong answer key,
        // the mis-aimed disqualification.
        UserRole.lecturer,
      });

      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // Read the predicate out of the function instead of trusting a copy of
      // the sentence: the list is what the policies below actually enforce.
      expect(
        _rolesNamedBy(sql, 'is_attempt_resetter'),
        clientRoles,
        reason: 'is_attempt_resetter() and UserRole.canResetAttempts disagree',
      );

      // The intervention tier is deliberately narrower and must stay that way:
      // the policy that writes into somebody else's attempt row in place, and
      // the RPCs that act on another account's attempt, still ask this one.
      expect(_rolesNamedBy(sql, 'is_exam_supervisor'), <UserRole>{
        UserRole.admin,
        UserRole.supervisor,
      });

      // The two steps that *follow* the delete still ask the reset predicate for the
      // Storage purge (and its orphan-read companion): the purge must keep working
      // for the caller the DELETE just allowed. The audit row no longer does - since
      // `20261109090000_supervisor_exam_assignments.sql` it asks the same
      // `can_supervise_exam(exam_id) or owns_exam(exam_id)` question the DELETE does,
      // so a reset that could not happen cannot be recorded as one either.
      expect(sql, contains('and public.is_attempt_resetter()'));
      expect(
        sql.replaceAll('\r\n', '\n'),
        contains(
          'with check (\n'
          '    (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id))\n'
          '    and actor_id = auth.uid()\n'
          '  )',
        ),
      );

      // The DELETE is ownership-scoped: the intervention tier, or the author of
      // that paper. Before this it was `is_attempt_resetter()`, which is every
      // lecturer, so any lecturer could clear any attempt in the institution.
      expect(
        _policyUsing(sql, 'submissions_delete_supervisor'),
        'public.can_supervise_exam(exam_id) or public.owns_exam(exam_id)',
      );

      // ...while the update policy is the one that keeps the narrower tier.
      // (Normalised to `\n`: the file is checked out with the platform's line
      // endings.)
      expect(
        sql.replaceAll('\r\n', '\n'),
        contains(
          'using (public.can_supervise_exam(exam_id))\n'
          '  with check (public.can_supervise_exam(exam_id));',
        ),
      );

      // Exactly three mentions now: the definition, the snapshot purge, and its
      // companion orphan-read policy that lets the purge's DELETE ... WHERE see the
      // rows. The audit row used to be a fourth and now asks the scope question
      // instead; the DELETE itself never asked this predicate.
      expect(
        RegExp(r'public\.is_attempt_resetter\(\)').allMatches(sql).length,
        3,
        reason: 'the function definition, the snapshot purge and the orphan-read '
            'companion',
      );
    });

    test('every copy of the predicate names the same roles', () {
      // The predicate is deliberately repeated so each SQL file stays re-runnable
      // on a database that predates it (a `create policy` is not idempotent, so
      // the file that recreates one has to be able to define what it calls). The
      // cost of that is drift, which this test is here to refuse.
      final copies = <String>[
        '../supabase/schema.sql',
        '../supabase/migrations/secure_exam_access_and_deadlines.sql',
        '../supabase/migrations/session_reset_logs.sql',
        '../supabase/migrations/staff_attempt_resets.sql',
      ];
      final expected = UserRole.values
          .where((role) => role.canResetAttempts)
          .toSet();

      var checked = 0;
      for (final path in copies) {
        final file = File(path);
        if (!file.existsSync()) continue; // a checkout without ../supabase
        checked++;
        expect(
          _rolesNamedBy(file.readAsStringSync(), 'is_attempt_resetter'),
          expected,
          reason: '$path declares a different reset tier',
        );
      }
      // A checkout that has the app but no ../supabase checks nothing - like
      // schemaSql(), it must not pretend otherwise.
      if (checked == 0) return;
      expect(checked, copies.length);
    });

    test('the upgrade migration widens all three policies', () {
      final file = File('../supabase/migrations/staff_attempt_resets.sql');
      if (!file.existsSync()) return; // a checkout without ../supabase
      final sql = file.readAsStringSync();

      // A `create policy` on a name the old revision already used is a 42710
      // unless the file drops it first.
      for (final policy in <String>[
        'submissions_delete_supervisor',
        'Proctor snapshots supervisor purge',
        'session_reset_logs_insert_supervisor',
      ]) {
        expect(
          sql,
          contains('drop policy if exists "$policy"'),
          reason: '$policy is recreated without being dropped first',
        );
      }

      // The audit policy is guarded: a project that has not applied
      // session_reset_logs.sql has no table to put it on, and `create policy`
      // would fail with 42P01 (the same failure the console reports as
      // `auditWarning`).
      expect(sql, contains("to_regclass('public.session_reset_logs')"));
    });
  });

  /// What was recorded *inside* a sitting - the incident feed in
  /// `proctoring_logs` and the reset audit in `session_reset_logs` - is readable
  /// by the paper's author and by the intervention tier, while the roster a
  /// monitor renders (`exam_submissions`) stays readable by every staff member.
  ///
  /// The asymmetry is the design (see the header of
  /// `supabase/migrations/lecturer_scoped_log_reads.sql`), so it is pinned from
  /// both sides here: the `owns_exam()` arm present on the two evidence policies,
  /// the staff tier absent from them and still present on the roster.
  group('lecturer-scoped evidence reads', () {
    /// The `using (...)` predicate of `create policy "<policy>"`, whitespace
    /// squashed to single spaces so the comparison does not depend on layout.
    ///
    /// Read out of the file rather than compared against a copy of the sentence:
    /// the text in the file is what the server enforces. Null when [sql] does not
    /// declare that policy (the upgrade migration assembles the reset policy
    /// inside an `execute`, so it has no `create policy` line to read).
    String? predicateOf(String sql, String policy) {
      final match = RegExp(
        'create policy "$policy"'
        r'[\s\S]*?for select[\s\S]*?using \(([\s\S]*?)\);',
      ).firstMatch(sql.replaceAll('\r\n', '\n'));
      return match?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    /// The body of `create or replace function public.<signature>(...)`,
    /// whitespace squashed. Null when the file omits the function.
    String? functionBody(String sql, String signature) {
      final match = RegExp(
        'create or replace function public\\.$signature'
        r'[\s\S]*?as \$\$([\s\S]*?)\$\$;',
      ).firstMatch(sql.replaceAll('\r\n', '\n'));
      return match?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    /// The body every copy of `owns_exam()` must have: the paper's author, asked
    /// of the exam the evidence row names. `created_by` is the column the
    /// authoring console already scopes edits with (`exams_update_owner`).
    const ownerIsAuthor =
        'select exists ( select 1 from public.exams '
        'where id = p_exam_id and created_by = auth.uid() );';

    test('the incident feed asks the owner as well as the intervention tier', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      final predicate = predicateOf(sql, 'logs_select_own_or_supervisor');
      expect(predicate, isNotNull, reason: 'the policy left schema.sql');
      // The student's own rows, the paper's author, the supervisor of that paper.
      expect(predicate, contains('s.student_id = auth.uid()'));
      expect(predicate, contains('public.owns_exam(s.exam_id)'));
      // The supervisor arm is the *scope* question now: since
      // `20261109090000_supervisor_exam_assignments.sql` a supervisor reaches the
      // incidents of the papers they were assigned, not every paper's.
      expect(predicate, contains('public.can_supervise_exam(s.exam_id)'));
      expect(predicate, isNot(contains('is_exam_supervisor')));
      // The staff tier is exactly what this policy dropped, and dropping it is
      // what stops one lecturer reading the incidents gathered on another
      // teacher's paper.
      expect(predicate, isNot(contains('is_staff')));
    });

    test('the reset audit asks the same question of the same evidence', () {
      final schema = schemaSql();
      if (schema == null) return;

      final predicate = predicateOf(schema, 'session_reset_logs_select_staff');
      expect(
        predicate,
        contains('public.can_supervise_exam(exam_id)'),
        reason:
            'the reset row carries its exam id as plain evidence, so the '
            'supervisor arm is the scope question asked of that id directly '
            'instead of hopping through the attempt the way the incident feed '
            'does',
      );
      expect(predicate, contains('public.owns_exam(exam_id)'));

      // The file that introduced the table carries the *historical* sentence - it
      // runs first, and the scope migration re-creates the policy - so what has to
      // agree with schema.sql is the last definition, asserted below.
      final introduced = File('../supabase/migrations/session_reset_logs.sql');
      if (introduced.existsSync()) {
        final sql = introduced.readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          predicateOf(sql, 'session_reset_logs_select_staff'),
          'public.is_exam_supervisor() or public.owns_exam(exam_id)',
          reason: 'the introducing file is history: rewriting it would change what '
              'an operator who already ran it has',
        );
        expect(
          functionBody(sql, r'owns_exam\(p_exam_id uuid\)'),
          ownerIsAuthor,
        );
      }

      // The scope migration is the current definition of this policy, and it must
      // match the file a fresh install runs.
      final scope = File(
        '../supabase/migrations/20261109090000_supervisor_exam_assignments.sql',
      );
      if (scope.existsSync()) {
        final sql = scope.readAsStringSync().replaceAll('\r\n', '\n');
        expect(predicateOf(sql, 'session_reset_logs_select_staff'), predicate);
      }

      // The upgrade file assembles the incident-feed policy inside an `execute`, so
      // what has to hold there is that the literal it concatenates is the sentence
      // that file shipped - the same words, not a paraphrase.
      final upgrade = File(
        '../supabase/migrations/lecturer_scoped_log_reads.sql',
      );
      if (upgrade.existsSync()) {
        final sql = upgrade.readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          sql,
          contains('public.is_exam_supervisor() or public.owns_exam(exam_id)'),
        );
      }

      // Writes ask the scope question too, in the caller's own name: a reset that
      // could not happen must not be recordable as one.
      expect(
        schema,
        contains(
          '(public.can_supervise_exam(exam_id) or public.owns_exam(exam_id))',
        ),
      );
    });

    test('the roster is staff-wide except for the assigned supervisor', () {
      final sql = schemaSql();
      if (sql == null) return;

      // A lecturer may watch any sitting - "WHAT IT DOES NOT CHANGE" in
      // lecturer_scoped_log_reads.sql - so the attempts keep the wide staff read for
      // them. Since `20261109090000_supervisor_exam_assignments.sql` the one staff
      // label that is narrowed is `supervisor`, and only to the papers an
      // administrator assigned it. If the ownership arm ever replaced the staff one,
      // a lecturer's monitor on another teacher's paper would show an empty roster.
      final predicate = predicateOf(sql, 'submissions_select_own_or_supervisor');
      expect(predicate, contains('student_id = auth.uid()'));
      expect(predicate, contains('public.is_staff()'));
      expect(predicate, contains('not public.is_supervisor_only()'));
      expect(predicate, contains('public.can_supervise_exam(exam_id)'));
      expect(predicate, isNot(contains('is_exam_supervisor')));
    });

    test('every copy of owns_exam() is the same pinned definition', () {
      // The helper is deliberately repeated so each SQL file stays re-runnable on
      // a database that predates it (a `create policy` is not idempotent, so the
      // file that recreates one has to be able to define what it calls). The cost
      // of that is drift, which this test is here to refuse.
      const copies = <String>[
        '../supabase/schema.sql',
        '../supabase/migrations/session_reset_logs.sql',
        '../supabase/migrations/lecturer_scoped_log_reads.sql',
      ];

      var checked = 0;
      for (final path in copies) {
        final file = File(path);
        if (!file.existsSync()) continue; // a checkout without ../supabase
        checked++;
        final sql = file.readAsStringSync().replaceAll('\r\n', '\n');

        expect(
          functionBody(sql, r'owns_exam\(p_exam_id uuid\)'),
          ownerIsAuthor,
          reason: '$path defines ownership as something other than created_by',
        );
        // SECURITY DEFINER with a pinned search_path, for the same reason as the
        // role predicates: the policy calling this must not have to re-enter the
        // policies on `exams`, and a hijacked path must not be able to swap the
        // table underneath the ownership test.
        expect(
          sql,
          contains(
            'language sql\n'
            'security definer\n'
            'stable\n'
            'set search_path = public\n',
          ),
          reason:
              '$path\'s owns_exam() is not the pinned SECURITY DEFINER form',
        );
      }
      // A checkout that has the app but no ../supabase checks nothing - like
      // schemaSql(), it must not pretend otherwise.
      if (checked == 0) return;
      expect(checked, copies.length);
    });

    test('the upgrade migration recreates both policies, guarded', () {
      final file = File('../supabase/migrations/lecturer_scoped_log_reads.sql');
      if (!file.existsSync()) return; // a checkout without ../supabase
      final sql = file.readAsStringSync().replaceAll('\r\n', '\n');

      // Re-runnable: a `create policy` on a name an earlier revision already used
      // is a 42710 unless the file drops it first. `proctoring_logs` is part of
      // the base schema, so that drop is unconditional...
      expect(
        sql,
        contains('drop policy if exists "logs_select_own_or_supervisor"'),
      );
      // ...while the reset policy can only be dropped and recreated once the
      // table is known to exist (see the guard below).
      expect(
        sql,
        contains(
          'execute \'drop policy if exists "session_reset_logs_select_staff" \'',
        ),
      );

      // The file's own copy is the historical sentence; the *current* definition is
      // the scope migration's, and that is the one that has to agree with a fresh
      // schema.sql install - it runs last on an upgraded project.
      expect(
        predicateOf(sql, 'logs_select_own_or_supervisor'),
        contains('public.is_exam_supervisor()'),
        reason: 'the introducing file is history; rewriting it would change what an '
            'operator who already ran it has',
      );
      final schema = schemaSql();
      final scope = File(
        '../supabase/migrations/20261109090000_supervisor_exam_assignments.sql',
      );
      if (schema != null && scope.existsSync()) {
        final scopeSql = scope.readAsStringSync().replaceAll('\r\n', '\n');
        expect(
          predicateOf(scopeSql, 'logs_select_own_or_supervisor'),
          predicateOf(schema, 'logs_select_own_or_supervisor'),
          reason: 'the scope migration and the full schema disagree',
        );
      }

      // The reset policy is created inside a table check: a project that has not
      // applied session_reset_logs.sql has no table to put it on, and an
      // unguarded `create policy` would stop the whole migration at 42P01.
      expect(sql, contains("to_regclass('public.session_reset_logs')"));
      expect(
        RegExp(
          '^create policy "([^"]+)"',
          multiLine: true,
        ).allMatches(sql).map((match) => match.group(1)).toList(),
        <String>['logs_select_own_or_supervisor'],
        reason: 'only the incident-feed policy may be created unconditionally',
      );
    });
  });

  group('admin-reset-password contract', () {
    // Ids straight out of supabase/seed.sql.
    const aishaId = '22222222-2222-4222-8222-222222222222';
    const someoneElseId = '33333333-3333-4333-8333-333333333333';

    Future<void> resetPassword() => AdminUserRepositoryImpl(
      client,
    ).resetPassword(userId: aishaId, password: 'Temporary123!');

    test('posts the account id and the password to the Edge Function', () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': aishaId,
        'email': 'aisha.bello@proctor.test',
        'full_name': 'Aisha Bello',
        'role': 'student',
      });

      await resetPassword();

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.path,
        '/functions/v1/${AdminUserRepositoryImpl.resetPasswordFunction}',
      );
      // The two names the function reads. No `actor_id`-style claim: who set a
      // password is Supabase Auth's record, not the caller's to declare.
      expect(jsonDecode(transport.bodies.single), <String, dynamic>{
        'id': aishaId,
        'password': 'Temporary123!',
      });
    });

    test(
      'an answer about a different account is refused, not trusted',
      () async {
        // The function echoes the id whose password it changed, so a reply
        // naming another account proves nothing about this one.
        transport.responseBody = jsonEncode(<String, dynamic>{
          'id': someoneElseId,
          'email': 'manager@proctor.test',
          'full_name': '',
          'role': 'supervisor',
        });

        await expectLater(
          resetPassword(),
          throwsA(
            isA<AdminAccountException>().having(
              (error) => error.message,
              'message',
              contains('may not have been changed'),
            ),
          ),
        );
      },
    );

    test("a refused reset keeps the function's own wording", () async {
      transport.statusCode = 403;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'error': 'Only an administrator can reset passwords.',
      });

      await expectLater(
        resetPassword(),
        throwsA(
          isA<AdminAccountException>().having(
            (error) => error.message,
            'message',
            'Only an administrator can reset passwords.',
          ),
        ),
      );
    });

    test('the deployed function agrees with the client', () {
      final file = File('../supabase/functions/admin-reset-password/index.ts');
      if (!file.existsSync()) return; // a checkout without ../supabase
      final source = file.readAsStringSync();

      // The same password floor as the form the administrator types into, and
      // the `{ error }` body `_messageFromResetFunctionError` reads out of a 4xx.
      expect(
        source,
        contains('const MIN_PASSWORD_LENGTH = $adminMinPasswordLength;'),
      );
      expect(source, contains('return json({ error: message }, status, headers);'));

      // Admins only: a *password* reset is an identity action, a different tier
      // from the attempt resets a lecturer or supervisor may run
      // (`is_attempt_resetter()`).
      // The 403 sentence is deliberately the same string the repository falls
      // back to when a 401/403 body carries no `{ error }`.
      expect(
        source,
        contains('const RESETTER_ROLES: readonly Role[] = ["admin"];'),
      );
      expect(source, contains('"Only an administrator can reset passwords."'));

      // No self-check, unlike `admin-delete-user` (`if (id ===
      // callerData.user.id)`): resetting a password cannot lock the console's
      // own administrator out of anything, and there is no self-service reset
      // path to fall back on if they were refused.
      expect(source, isNot(contains('id === callerData.user.id')));
    });
  });

  group('session reset audit trail', () {
    test('schema.sql declares the table, its policies and its indexes', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      expect(
        sql,
        contains('create table if not exists public.session_reset_logs'),
      );
      // Who ran a reset is the database's answer: `actor_id` defaults to
      // auth.uid() server-side, the insert policy re-checks it, and the client
      // deliberately never sends the column.
      expect(sql, contains('actor_id        uuid not null default auth.uid()'));
      expect(
        sql.replaceAll('\r\n', '\n'),
        contains(
          'with check (\n'
          '    (public.can_supervise_exam(exam_id) or public.owns_exam(exam_id))\n'
          '    and actor_id = auth.uid()\n'
          '  )',
        ),
      );
      // No foreign keys: the attempt this row describes has just been deleted by
      // the very action that writes the row, so a reference could only refuse
      // the insert or blank out the id it exists to record.
      expect(sql, contains('submission_id   uuid not null'));
      expect(sql, isNot(contains('submission_id   uuid not null references')));
      expect(sql, contains('session_reset_logs_select_staff'));
      // Append-only by omission: with no UPDATE and no DELETE policy, no client
      // - admin included - can rewrite or remove a record.
      expect(sql, isNot(contains('session_reset_logs for update')));
      expect(sql, isNot(contains('session_reset_logs for delete')));
      // The two indexes the console's reads (newest first, per exam) rely on.
      expect(sql, contains('idx_session_reset_logs_created_at'));
      expect(sql, contains('idx_session_reset_logs_exam_id'));
    });

    test('the upgrade migration carries the same table for live projects', () {
      // `schema.sql` is re-runnable, but `create table if not exists` cannot add
      // a table to a database that already ran that file, so an installed
      // project starts recording resets only once this migration is applied.
      final file = File('../supabase/migrations/session_reset_logs.sql');
      if (!file.existsSync()) return; // a checkout without ../supabase
      final sql = file.readAsStringSync();

      expect(
        sql,
        contains('create table if not exists public.session_reset_logs'),
      );
      expect(
        sql,
        contains(
          'alter table public.session_reset_logs enable row level security',
        ),
      );
      expect(sql, contains('"session_reset_logs_select_staff"'));
      expect(sql, contains('"session_reset_logs_insert_supervisor"'));
      expect(sql, contains('idx_session_reset_logs_exam_id'));
    });
  });

  group('attempt clock', () {
    test('Submission parses started_at so the countdown can be anchored', () {
      final submission = Submission.fromMap(<String, dynamic>{
        'id': 'sub-1',
        'student_id': 'student-1',
        'exam_id': 'exam-1',
        'answers': <String, dynamic>{},
        'status': 'ongoing',
        'score': null,
        'started_at': '2026-01-01T09:00:00+00:00',
      });

      expect(submission.startedAt?.toUtc(), DateTime.utc(2026, 1, 1, 9));
      expect(submission.status, SubmissionStatus.ongoing);
    });

    test('an unusable started_at is null rather than an exception', () {
      for (final value in <Object?>[null, 42, 'not-a-date']) {
        expect(Submission.parseTimestamp(value), isNull);
      }
    });
  });

  group('proctor-snapshots upload', () {
    test(
      'POSTs JPEG bytes to <submission_id>/<action_type>_<epoch-ms>.jpg',
      () async {
        // storage_client expects the object key back from the upload response.
        transport.responseBody =
            '{"Key": "proctor-snapshots/sub-1/no_face_1.jpg"}';
        SupabaseService.instance.debugSetClient(client);
        addTearDown(() => SupabaseService.instance.debugSetClient(null));

        final before = DateTime.now().millisecondsSinceEpoch;
        final path = await SupabaseService.instance.uploadViolationSnapshot(
          submissionId: 'sub-1',
          actionType: 'no_face',
          bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        );
        final after = DateTime.now().millisecondsSinceEpoch;

        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(
          request.url.path,
          startsWith('/storage/v1/object/proctor-snapshots/sub-1/no_face_'),
        );
        expect(request.url.path, endsWith('.jpg'));

        // supabase-storage takes the object's MIME type from the multipart part —
        // that is what the bucket's allowed_mime_types (jpeg/png) validates — and
        // `x-upsert: false` keeps snapshot names append-only.
        expect(request, isA<http.MultipartRequest>());
        final multipart = request as http.MultipartRequest;
        expect(multipart.files, hasLength(1));
        expect(multipart.files.single.contentType.mimeType, 'image/jpeg');
        expect(multipart.fields['cacheControl'], '3600');
        expect(multipart.headers['x-upsert'], 'false');

        // What comes back is the bucket-relative **path** that goes on the log
        // row: the bucket is private, so a URL minted here would be dead long
        // before anybody reviews the evidence. Note the absence of `/public/`.
        expect(path, isNotNull);
        expect(path, startsWith('sub-1/no_face_'));
        expect(path, endsWith('.jpg'));
        expect(path, isNot(contains('/storage/v1/')));

        final stamp = int.parse(
          RegExp(r'no_face_(\d+)\.jpg').firstMatch(path!)!.group(1)!,
        );
        expect(stamp, inInclusiveRange(before, after));
      },
    );

    test('snapshotPath is the single source of the path convention', () {
      expect(SupabaseService.snapshotBucket, 'proctor-snapshots');
      expect(
        SupabaseService.snapshotPath(
          submissionId: 'sub-9',
          actionType: 'looking_away',
          at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        'sub-9/looking_away_1700000000000.jpg',
      );
    });

    test('snapshotObjectPath resolves every shape a stored row can hold', () {
      const object = 'sub-1/looking_away_1.jpg';

      // What this build writes: the path itself.
      expect(SupabaseService.snapshotObjectPath(object), object);

      // What rows written while the bucket was public hold.
      expect(
        SupabaseService.snapshotObjectPath(
          'https://mock.supabase.co/storage/v1/object/public/'
          'proctor-snapshots/$object',
        ),
        object,
      );

      // What a console-minted signed URL holds: the token is query, not path.
      expect(
        SupabaseService.snapshotObjectPath(
          'https://mock.supabase.co/storage/v1/object/sign/'
          'proctor-snapshots/$object?token=eyJhbGciOi',
        ),
        object,
      );

      // Not snapshot references: nothing to sign, and the dashboard's old
      // placeholder must not be mistaken for one.
      for (final value in <String>[
        '',
        '   ',
        'proctor-snapshots',
        'https://mock.supabase.co/storage/v1/object/public/proctor-snapshots',
        'https://example.com/elsewhere/thing.jpg',
        'unavailable',
      ]) {
        expect(
          SupabaseService.snapshotObjectPath(value),
          isNull,
          reason: '"$value" is not a snapshot reference',
        );
      }
    });

    test(
      'signedSnapshotUrl asks Storage to sign the object, not a URL',
      () async {
        transport.responseBody =
            '{"signedURL": "/object/sign/proctor-snapshots/sub-1/no_face_1.jpg'
            '?token=sig"}';
        SupabaseService.instance.debugSetClient(client);
        addTearDown(() => SupabaseService.instance.debugSetClient(null));

        // A pre-migration public URL still resolves: the console copies rows from
        // both sides of the change.
        final url = await SupabaseService.instance.signedSnapshotUrl(
          'https://mock.supabase.co/storage/v1/object/public/'
          'proctor-snapshots/sub-1/no_face_1.jpg',
        );

        final request = transport.requests.single;
        expect(request.method, 'POST');
        expect(
          request.url.path,
          '/storage/v1/object/sign/proctor-snapshots/sub-1/no_face_1.jpg',
        );
        // Ten minutes, from the shipped default - a leaked link is worthless
        // before it can be passed around.
        expect(
          jsonDecode(transport.bodies.single) as Map<String, dynamic>,
          containsPair('expiresIn', 600),
        );

        expect(
          url,
          'https://mock.supabase.co/storage/v1/object/sign/'
          'proctor-snapshots/sub-1/no_face_1.jpg?token=sig',
        );
      },
    );

    test('signedSnapshotUrl refuses a value that is not a snapshot', () async {
      SupabaseService.instance.debugSetClient(client);
      addTearDown(() => SupabaseService.instance.debugSetClient(null));

      // No request at all: there is nothing to sign, so asking Storage would
      // only turn a placeholder into an error in the console.
      expect(
        await SupabaseService.instance.signedSnapshotUrl('unavailable'),
        isNull,
      );
      expect(transport.requests, isEmpty);
    });

    test('the private-bucket migration matches schema.sql section 6', () {
      final migration = File(
        '../supabase/migrations/private_proctor_snapshots.sql',
      );
      final schema = File('../supabase/schema.sql');
      if (!migration.existsSync() || !schema.existsSync()) return;

      final sql = migration.readAsStringSync();
      final fresh = schema.readAsStringSync();

      // Re-runnable: an existing bucket is flipped in place rather than
      // duplicated, and every policy is dropped before it is recreated (42710
      // otherwise). The old upload-policy name is dropped too, so a project
      // installed before the ownership check cannot keep a broader insert policy.
      expect(sql, contains('on conflict (id) do update'));
      for (final policy in <String>[
        'Proctor snapshots read access',
        'Proctor snapshots upload access',
        'Proctor snapshots upload own ongoing session',
        'Proctor snapshots supervisor purge',
      ]) {
        expect(
          sql,
          contains('drop policy if exists "$policy"'),
          reason: '$policy is recreated without being dropped first',
        );
      }

      // `public = false` is the whole migration: it is what makes a signed URL
      // the only way to read a still. Pinned in the file that flips an existing
      // project and in the one a fresh install runs.
      const privateBucket =
          "values ('proctor-snapshots', 'proctor-snapshots', false,";
      expect(sql, contains(privateBucket));
      expect(fresh, contains(privateBucket));

      // Parity, not a second design: the upgrade path has to create the same
      // three policies a fresh install gets.
      for (final policy in <String>[
        'Proctor snapshots read access',
        'Proctor snapshots upload own ongoing session',
        'Proctor snapshots supervisor purge',
      ]) {
        expect(sql, contains('create policy "$policy"'));
        expect(fresh, contains('create policy "$policy"'));
      }
    });
  });

  group('merge_submission_text_answer RPC payload', () {
    test('saveTextAnswer uses the documented argument names', () async {
      transport.responseBody = 'null';
      final repo = ExamRepositoryImpl(client);

      await repo.saveTextAnswer(
        submissionId: 'sub-1',
        questionId: 'q-1',
        answer: '  HyperText Transfer Protocol ',
      );

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/merge_submission_text_answer');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{
        'p_submission_id',
        'p_question_id',
        'p_answer',
      });
      expect(body['p_submission_id'], 'sub-1');
      expect(body['p_question_id'], 'q-1');
      // Sent verbatim: submit_exam() trims and lowercases both sides when it
      // grades, so the student's spacing and casing survive as evidence.
      expect(body['p_answer'], '  HyperText Transfer Protocol ');
    });
  });

  group('question shapes', () {
    test('QuestionType round-trips the values the check constraint allows', () {
      expect(QuestionType.values.map((type) => type.dbValue).toList(), <String>[
        'multiple_choice',
        'true_false',
        'fill_in_the_blank',
        'subjective',
      ]);
      expect(
        QuestionType.fromDb('multiple_choice'),
        QuestionType.multipleChoice,
      );
      expect(QuestionType.fromDb('true_false'), QuestionType.trueFalse);
      expect(
        QuestionType.fromDb('fill_in_the_blank'),
        QuestionType.fillInTheBlank,
      );
      expect(QuestionType.fromDb('subjective'), QuestionType.subjective);
    });

    test('the type decides how it is answered and how it is marked', () {
      // Typed answers share one write path (`merge_submission_text_answer`) and
      // one widget; a true/false tap is a pair of cards even though the server
      // stores the word it writes.
      expect(QuestionType.fillInTheBlank.usesTextAnswer, isTrue);
      expect(QuestionType.subjective.usesTextAnswer, isTrue);
      expect(QuestionType.trueFalse.usesTextAnswer, isFalse);
      expect(QuestionType.multipleChoice.usesTextAnswer, isFalse);

      // `submit_exam()` scores everything but an essay; an essay is marked by
      // hand through `grade_submission()`.
      expect(QuestionType.multipleChoice.isAutoGraded, isTrue);
      expect(QuestionType.trueFalse.isAutoGraded, isTrue);
      expect(QuestionType.fillInTheBlank.isAutoGraded, isTrue);
      expect(QuestionType.subjective.isAutoGraded, isFalse);
      expect(QuestionType.subjective.markingLabel, 'Marked by hand');
    });

    test('an unknown or missing type falls back instead of throwing', () {
      // A row must not be able to take the whole exam screen down through the
      // question feed.
      expect(QuestionType.fromDb('matching'), QuestionType.multipleChoice);
      expect(QuestionType.fromDb(null), QuestionType.multipleChoice);
    });

    test('Question.fromMap reads every shape from the safe view', () {
      Question parse(String type) => Question.fromMap(<String, dynamic>{
        'id': 'q-1',
        'exam_id': 'exam-1',
        'question_text': 'Sample',
        'question_type': type,
        'options': <String>[],
        'points': 2,
      });

      expect(parse('true_false').questionType, QuestionType.trueFalse);
      expect(parse('true_false').isTrueFalse, isTrue);
      expect(parse('true_false').options, isEmpty);
      expect(parse('subjective').isSubjective, isTrue);
      expect(parse('subjective').usesTextAnswer, isTrue);
    });

    test(
      'Question.fromMap reads a fill-in-the-blank row from the safe view',
      () {
        final question = Question.fromMap(<String, dynamic>{
          'id': 'q-1',
          'exam_id': 'exam-1',
          'question_text': 'What does the acronym HTTP stand for?',
          'question_type': 'fill_in_the_blank',
          'options': <String>[],
          'points': 2,
        });

        expect(question.questionType, QuestionType.fillInTheBlank);
        expect(question.isFillInTheBlank, isTrue);
        expect(question.options, isEmpty);
      },
    );

    test('a row without question_type (pre-types database) still parses', () {
      final question = Question.fromMap(<String, dynamic>{
        'id': 'q-2',
        'exam_id': 'exam-1',
        'question_text': 'Which structure is FIFO?',
      });

      expect(question.questionType, QuestionType.multipleChoice);
      expect(question.isFillInTheBlank, isFalse);
      expect(question.options, isEmpty);
    });
  });

  group('question authoring contract', () {
    late QuestionAuthoringRepositoryImpl repo;

    setUp(() {
      // The console's own account, so the writes it makes are attributable
      // without a real session (the same injectable seam `RoleGate` uses).
      repo = QuestionAuthoringRepositoryImpl(
        client,
        currentUserId: () => '11111111-1111-4111-8111-111111111111',
      );
    });

    test(
      'a new paper is created owned by the caller, and nothing else',
      () async {
        transport.responseBody = jsonEncode(<String, dynamic>{
          'id': 'exam-9',
          'title': 'GES301: Software Engineering Midterm',
          'created_by': '11111111-1111-4111-8111-111111111111',
          'duration_minutes': 50,
          'is_published': false,
        });

        final exam = await repo.createExam(
          title: 'GES301: Software Engineering Midterm',
          durationMinutes: 50,
          isPublished: false,
        );

        expect(transport.requests.single.url.path, endsWith('/rest/v1/exams'));
        final body =
            jsonDecode(transport.bodies.single) as Map<String, dynamic>;
        // `exams_insert_supervisor_only` checks both halves, so both are sent: the
        // caller's own id, and the draft state the dialog defaults to.
        expect(body, <String, dynamic>{
          'title': 'GES301: Software Engineering Midterm',
          'created_by': '11111111-1111-4111-8111-111111111111',
          'duration_minutes': 50,
          'is_published': false,
        });
        // A paper that has just been created has nothing under it, so no second
        // read is issued to learn that its counts are zero.
        expect(transport.requests, hasLength(1));
        expect(exam.questionCount, 0);
        expect(exam.attemptCount, 0);
        expect(exam.statusLabel, 'Draft');
      },
    );

    test('the console asks for its own papers, with both counts', () async {
      transport.responseBody = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'exam-9',
          'title': 'GES301: Software Engineering Midterm',
          'created_by': '11111111-1111-4111-8111-111111111111',
          'duration_minutes': 50,
          'is_published': true,
          'questions': <Map<String, dynamic>>[
            <String, dynamic>{'count': 4},
          ],
          'exam_submissions': <Map<String, dynamic>>[
            <String, dynamic>{'count': 1},
          ],
        },
      ]);

      final exams = await repo.listMyExams();

      final query = transport.requests.single.url.query;
      // The *mine* filter, and the embedded aggregates the tile prints. The
      // query arrives percent-encoded, so the embeds are read back decoded.
      expect(query, contains('created_by=eq.'));
      final decoded = Uri.decodeFull(query);
      expect(decoded, contains('questions(count)'));
      expect(decoded, contains('exam_submissions(count)'));
      expect(exams.single.questionCount, 4);
      expect(exams.single.attemptCount, 1);
      expect(exams.single.countsLabel, '4 questions · 1 attempt');
      expect(exams.single.statusLabel, 'Published');
    });

    test(
      'a true/false question is sent as a word, with no option index',
      () async {
        transport.responseBody = jsonEncode(<String, dynamic>{
          'id': 'q-7',
          'exam_id': 'exam-9',
          'question_text':
              'A pull request may be merged before its checks pass.',
          'question_type': 'true_false',
          'options': <dynamic>[],
          'correct_option': null,
          'correct_text_answer': 'false',
          'points': 1,
        });

        final question = await repo.createQuestion(
          examId: 'exam-9',
          draft: const QuestionDraft(
            questionType: QuestionType.trueFalse,
            questionText:
                'A pull request may be merged before its checks pass.',
            correctTextAnswer: 'False',
          ),
        );

        final body =
            jsonDecode(transport.bodies.single) as Map<String, dynamic>;
        // The shape `questions_answer_key_shape` accepts for 'true_false': the key
        // is the word, lowercased, and there is no option index at all.
        expect(body['question_type'], 'true_false');
        expect(body['correct_text_answer'], 'false');
        expect(body['correct_option'], isNull);
        expect(body['options'], isEmpty);
        expect(body['exam_id'], 'exam-9');
        expect(question.answerSummary, 'False');
      },
    );

    test('an incomplete draft is refused locally, with the sentence', () async {
      await expectLater(
        repo.createQuestion(
          examId: 'exam-9',
          draft: const QuestionDraft(
            questionType: QuestionType.multipleChoice,
            questionText: 'Which structure is FIFO?',
            options: <String>['Queue', 'Stack'],
          ),
        ),
        throwsA(
          isA<AuthoringException>().having(
            (error) => error.message,
            'message',
            'Pick which option is correct.',
          ),
        ),
      );
      // Nothing reached the server: the rule is answered before the round trip.
      expect(transport.requests, isEmpty);
    });

    test('an edit clears the answer key of the shape it left', () async {
      // An update returns the row(s) it wrote, which is an array on the wire (the
      // client asks for a representation rather than an object here).
      transport.responseBody = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'q-7',
          'exam_id': 'exam-9',
          'question_text':
              'Explain the difference between a stack and a queue.',
          'question_type': 'subjective',
          'options': <dynamic>[],
          'correct_option': null,
          'correct_text_answer': null,
          'points': 4,
        },
      ]);

      await repo.updateQuestion(
        questionId: 'q-7',
        draft: const QuestionDraft(
          questionType: QuestionType.subjective,
          questionText: 'Explain the difference between a stack and a queue.',
          correctTextAnswer: 'ignored',
          points: 4,
        ),
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      // A stale key would violate `questions_answer_key_shape`, and only after
      // the update had already been sent.
      expect(body['question_type'], 'subjective');
      expect(body['correct_text_answer'], isNull);
      expect(body['correct_option'], isNull);
      expect(body['options'], isEmpty);
    });

    test(
      'a signed-out console refuses instead of writing a stray row',
      () async {
        final anonymous = QuestionAuthoringRepositoryImpl(
          client,
          currentUserId: () => null,
        );

        await expectLater(
          anonymous.listMyExams(),
          throwsA(
            isA<AuthoringException>().having(
              (error) => error.message,
              'message',
              contains('signed out'),
            ),
          ),
        );
        await expectLater(
          anonymous.createExam(
            title: 'GES301',
            durationMinutes: 50,
            isPublished: false,
          ),
          throwsA(isA<AuthoringException>()),
        );
        expect(transport.requests, isEmpty);
      },
    );

    test(
      'a PostgREST refusal becomes a sentence a lecturer can act on',
      () async {
        transport.statusCode = 403;
        transport.responseBody = jsonEncode(<String, dynamic>{
          'message':
              'new row violates row-level security policy for table "questions"',
          'code': '42501',
        });

        await expectLater(
          repo.createQuestion(
            examId: 'exam-9',
            draft: const QuestionDraft(
              questionType: QuestionType.subjective,
              questionText:
                  'Explain the difference between a stack and a queue.',
            ),
          ),
          throwsA(
            isA<AuthoringException>().having(
              (error) => error.message,
              'message',
              contains('Only the owner of a paper'),
            ),
          ),
        );
      },
    );

    test('a missing grading function names the migration to run', () async {
      transport.statusCode = 404;
      transport.responseBody = jsonEncode(<String, dynamic>{
        'message': 'Could not find the function public.grade_submission',
        'code': 'PGRST202',
      });

      await expectLater(
        repo.saveGrades(
          submissionId: 'sub-1',
          grades: <String, dynamic>{
            'q-9': <String, dynamic>{'awarded': 3, 'feedback': ''},
          },
        ),
        throwsA(
          isA<AuthoringException>().having(
            (error) => error.message,
            'message',
            contains('question_types_and_grading.sql'),
          ),
        ),
      );
    });
  });

  group('lecture authoring and marking in schema.sql', () {
    test('the four shapes, their keys and the marks floor are declared', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // Widened from two shapes to four by drop-and-add: an `if not exists`
      // guard would have left a live database refusing to store the new types.
      expect(
        sql,
        contains('drop constraint if exists questions_question_type_check'),
      );
      expect(sql, contains("in ('multiple_choice', 'true_false',"));
      expect(sql, contains("'fill_in_the_blank', 'subjective'"));
      // A true/false row's key is the word, never an option index.
      expect(
        sql,
        contains(
          "lower(btrim(coalesce(correct_text_answer, ''))) in ('true', 'false')",
        ),
      );
      // An essay's shape is having no key at all.
      expect(sql, contains("question_type = 'subjective'"));
      // `points` feeds the sum `submit_exam()` writes, so a negative weight must
      // not be storable.
      expect(
        sql,
        contains('questions_points_non_negative check (points >= 0)'),
      );
    });

    test('question_grades is staff-readable and client-unwritable', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains('create table if not exists public.question_grades'),
      );
      // `on delete cascade` from both parents: a reset or a deleted question has
      // to take its marks with it, or `score` would keep counting them.
      expect(
        sql,
        contains('references public.exam_submissions(id) on delete cascade'),
      );
      expect(
        sql,
        contains('references public.questions(id) on delete cascade'),
      );
      expect(sql, contains('unique (submission_id, question_id)'));
      expect(sql, contains('"question_grades_select_staff"'));
      expect(sql, contains('idx_question_grades_question_id'));
      // One write path only — the RPC — the same shape `proctoring_logs` uses
      // for violations: no client insert, update or delete policy at all.
      expect(sql, isNot(contains('on public.question_grades for insert')));
      expect(sql, isNot(contains('on public.question_grades for update')));
      expect(sql, isNot(contains('on public.question_grades for delete')));
    });

    test('the automatic sum has one home, and submit_exam() asks for it', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains(
          'create or replace function public.auto_graded_score(p_submission_id uuid)',
        ),
      );
      // True/false grades through the word comparison, exactly like a
      // fill-in-the-blank answer.
      expect(
        sql,
        contains("q.question_type in ('fill_in_the_blank', 'true_false')"),
      );
      // The close and every re-mark ask this one function, so they cannot drift
      // apart about which answers count.
      expect(
        sql,
        contains('v_score := public.auto_graded_score(p_submission_id);'),
      );
      expect(
        sql,
        contains(
          'revoke execute on function public.auto_graded_score(uuid) from public, anon;',
        ),
      );
    });

    test('grade_submission is owner-scoped and recomputes the total', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains('create or replace function public.grade_submission('),
      );
      expect(sql, contains('  p_grades        jsonb'));
      expect(sql, contains('only the exam owner may grade its answers'));
      expect(sql, contains('is still in progress'));
      expect(sql, contains('was disqualified and is not graded'));
      expect(sql, contains('needs a numeric "awarded" mark'));
      expect(sql, contains('must be between 0 and'));
      expect(
        sql,
        contains('on conflict (submission_id, question_id) do update'),
      );
      expect(
        sql,
        contains(
          'grant execute on function public.grade_submission(uuid, jsonb) to authenticated, service_role;',
        ),
      );
      // The marks are the grader's input and the student's answers are not
      // rewritten: `score` is the only thing that moves on the attempt.
      expect(sql, contains('set score = v_score'));
    });

    test('the upgrade migration carries the same DDL and the new submit_exam', () {
      final migration = migrationSql();
      if (migration == null) return;

      expect(
        migration,
        contains('drop constraint if exists questions_question_type_check'),
      );
      expect(
        migration,
        contains('create table if not exists public.question_grades'),
      );
      expect(
        migration,
        contains('create or replace function public.grade_submission('),
      );
      expect(
        migration,
        contains(
          'create or replace function public.auto_graded_score(p_submission_id uuid)',
        ),
      );
      // A live project's own submit_exam() grades only the two original shapes,
      // so a true/false answer would never score without this replacement.
      expect(
        migration,
        contains('create or replace function public.submit_exam('),
      );
      expect(
        migration,
        contains('v_score := public.auto_graded_score(p_submission_id);'),
      );
    });
  });

  group('schema.sql carries the offline-retry contract', () {
    test('the log table, the RPC and the dedupe index agree with the client', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // The two columns `ProctoringRepositoryImpl` now sends.
      expect(
        sql,
        contains('add column if not exists client_timestamp timestamptz'),
      );
      expect(sql, contains('add column if not exists client_event_id uuid'));
      expect(sql, contains('p_client_timestamp timestamptz default null'));
      expect(sql, contains('p_client_event_id  uuid default null'));

      // The idempotency key only works with the partial unique index behind it.
      expect(sql, contains('idx_logs_client_event_id'));
      expect(
        sql,
        contains(
          'on conflict (client_event_id) where client_event_id is not null '
          'do nothing',
        ),
      );

      // And the old 3-argument overload has to be dropped, or every call becomes
      // ambiguous now that a 5-argument defaulted version exists.
      expect(
        sql,
        contains(
          'drop function if exists public.register_violation(uuid, text, text);',
        ),
      );
    });
  });

  /// Optional exam scheduling: the client's window (`Exam.startsAt` / `endsAt`)
  /// against the server's (`exams.starts_at` / `ends_at`), in both the unified
  /// schema and the upgrade migration an existing project applies.
  group('optional exam scheduling', () {
    test('the schema keeps the window optional and enforces it on start', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // Both nullable. An unscheduled paper is the default, so the bounds cannot
      // be NOT NULL and cannot carry a default.
      expect(sql, contains('starts_at        timestamptz,'));
      expect(sql, contains('ends_at          timestamptz,'));
      // A window that closes before it opens is refused by the database too, not
      // only by the console's dialog.
      expect(
        sql,
        contains(
          'check (starts_at is null or ends_at is null or ends_at > starts_at)',
        ),
      );

      // The window is enforced where an attempt row is created...
      expect(
        sql,
        contains('and (e.starts_at is null or now() >= e.starts_at)'),
      );
      expect(sql, contains('and (e.ends_at  is null or now() <= e.ends_at)'));

      // ...and capped where an attempt is answered and closed, through the one
      // helper rather than a second copy of the arithmetic.
      expect(
        sql,
        contains('create or replace function public.attempt_deadline('),
      );
      expect(
        sql,
        contains("coalesce(p_ends_at, 'infinity'::timestamptz)"),
        reason: 'a paper with no close must keep the pre-scheduling deadline',
      );
    });

    test('the client countdown is the same least() the server enforces', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // The server's one deadline helper: `started_at + duration`, capped by the
      // paper's close (coalesced to infinity when it has none).
      expect(
        sql,
        contains('p_started_at + make_interval(mins => p_duration_minutes)'),
      );
      expect(sql, contains("coalesce(p_ends_at, 'infinity'::timestamptz)"));

      // `ExamSessionController.resolveDeadline` has to answer the *same* instant.
      // It is the only client-side copy of that arithmetic, and it is what the
      // student's clock counts down to: if it dropped the `ends_at` cap the page
      // would keep showing time in which every write was already being refused.
      expect(
        ExamSessionController.resolveDeadline(
          now: DateTime.utc(2026, 1, 5, 16, 55),
          durationMinutes: 60,
          startedAt: DateTime.utc(2026, 1, 5, 16, 50),
          endsAt: DateTime.utc(2026, 1, 5, 17),
        ),
        DateTime.utc(2026, 1, 5, 17),
        reason: 'least(16:50 + 60min, 17:00) is the paper\'s close',
      );
      expect(
        ExamSessionController.resolveDeadline(
          now: DateTime.utc(2026, 1, 5, 16, 55),
          durationMinutes: 60,
          startedAt: DateTime.utc(2026, 1, 5, 16, 50),
          endsAt: null,
        ),
        DateTime.utc(2026, 1, 5, 17, 50),
        reason: 'a NULL ends_at coalesces to infinity, so the duration stands',
      );
    });

    test('the upgrade migration carries the same DDL and the same policies', () {
      final file = File('../supabase/migrations/optional_exam_scheduling.sql');
      if (!file.existsSync()) return; // a checkout without ../supabase
      final sql = file.readAsStringSync();

      // A column added with `add column if not exists`, because
      // `create table if not exists` in schema.sql cannot touch a table that is
      // already there - the whole reason this file exists.
      expect(sql, contains('add column if not exists starts_at timestamptz'));
      expect(sql, contains('add column if not exists ends_at   timestamptz'));
      expect(sql, contains('drop constraint if exists exams_window_ordered'));
      // Recreating a policy on a name the old revision used is a 42710 unless it
      // is dropped first.
      expect(
        sql,
        contains('drop policy if exists "submissions_insert_own_ongoing"'),
      );

      // Every function whose behaviour the window changes is replaced, or a live
      // project would keep grading and closing with the old deadline.
      for (final fn in <String>[
        'attempt_deadline',
        'merge_submission_answer',
        'merge_submission_text_answer',
        'submit_exam',
      ]) {
        expect(
          sql,
          contains('create or replace function public.$fn('),
          reason: '$fn is not replaced by the migration',
        );
      }
    });

    test('createExam sends the window as UTC, and omits it when unset', () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'exam-9',
        'title': 'GES301: Software Engineering Midterm',
        'created_by': '11111111-1111-4111-8111-111111111111',
        'duration_minutes': 50,
        'is_published': true,
        'starts_at': '2026-01-05T09:00:00+00:00',
        'ends_at': '2026-01-05T17:00:00+00:00',
      });

      final repo = QuestionAuthoringRepositoryImpl(
        client,
        currentUserId: () => '11111111-1111-4111-8111-111111111111',
      );
      final created = await repo.createExam(
        title: 'GES301: Software Engineering Midterm',
        durationMinutes: 50,
        isPublished: true,
        startsAt: DateTime.parse('2026-01-05T09:00:00Z'),
        endsAt: DateTime.parse('2026-01-05T17:00:00Z'),
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      // UTC, because the columns are timestamptz: the console's pickers work in
      // the author's own zone and the instant is what is stored.
      expect(body['starts_at'], '2026-01-05T09:00:00.000Z');
      expect(body['ends_at'], '2026-01-05T17:00:00.000Z');
      // The window the row came back with is parsed, not discarded: the console
      // shows it on the tile it has just created.
      expect(created.exam.startsAt?.toUtc(), DateTime.utc(2026, 1, 5, 9));
      expect(created.exam.endsAt?.toUtc(), DateTime.utc(2026, 1, 5, 17));
      expect(created.exam.isScheduled, isTrue);
    });

    test('an unscheduled paper sends no window keys at all', () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'exam-10',
        'title': 'GES302: Requirements Engineering',
        'created_by': '11111111-1111-4111-8111-111111111111',
        'duration_minutes': 30,
        'is_published': false,
      });

      final repo = QuestionAuthoringRepositoryImpl(
        client,
        currentUserId: () => '11111111-1111-4111-8111-111111111111',
      );
      final created = await repo.createExam(
        title: 'GES302: Requirements Engineering',
        durationMinutes: 30,
        isPublished: false,
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      // Omitted rather than sent as null: the column's own default is NULL, and
      // the request says out loud which kind of paper this is.
      expect(body.containsKey('starts_at'), isFalse);
      expect(body.containsKey('ends_at'), isFalse);
      // A database from before the columns existed answers without them, and that
      // has to read as "unscheduled" rather than throwing.
      expect(created.exam.isScheduled, isFalse);
      expect(created.exam.startsAt, isNull);
      expect(created.exam.scheduleLabel, 'Anytime');
    });

    test('a project without the columns names the migration to run', () async {
      // PostgREST answers a *read* of a column the schema cache does not have
      // with 42703 and a write with PGRST204. Both have to reach the console as
      // the file to run: "could not load your papers" would leave a lecturer
      // with nothing to do about it.
      transport
        ..statusCode = 400
        ..responseBody = jsonEncode(<String, dynamic>{
          'code': 'PGRST204',
          'message':
              "Could not find the 'starts_at' column of 'exams' in the "
              'schema cache',
        });

      final repo = QuestionAuthoringRepositoryImpl(
        client,
        currentUserId: () => '11111111-1111-4111-8111-111111111111',
      );

      await expectLater(
        repo.createExam(
          title: 'GES303: Software Testing',
          durationMinutes: 30,
          isPublished: false,
        ),
        throwsA(
          isA<AuthoringException>().having(
            (error) => error.message,
            'message',
            contains('optional_exam_scheduling.sql'),
          ),
        ),
      );
    });
  });

  /// Scoped exposure: the labels a paper carries (what `createExam` sends), the
  /// columns on both tables, the borrow list, and the rewritten `exams_select`
  /// that reads them - in the unified schema and in the upgrade migration an
  /// existing project applies.
  group('academic targeting contract', () {
    /// The `using (...)` of `create policy "<policy>" ... for select`, whitespace
    /// squashed so two files can be compared as sentences rather than layouts.
    String? selectPredicate(String sql, String policy) {
      final match = RegExp(
        'create policy "$policy"'
        r'[\s\S]*?for select[\s\S]*?using \(([\s\S]*?)\);',
      ).firstMatch(sql.replaceAll('\r\n', '\n'));
      return match?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    test('createExam sends the labels, trimmed, and omits the ones it was not '
        'given', () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'exam-11',
        'title': 'CSC301: Databases',
        'created_by': '11111111-1111-4111-8111-111111111111',
        'duration_minutes': 45,
        'is_published': false,
        'faculty': 'Science',
        'department': 'Computer Science',
        'level': '300',
      });

      final repo = QuestionAuthoringRepositoryImpl(
        client,
        currentUserId: () => '11111111-1111-4111-8111-111111111111',
      );
      final created = await repo.createExam(
        title: 'CSC301: Databases',
        durationMinutes: 45,
        isPublished: false,
        // The console's fields are free text, so the column gets it trimmed.
        faculty: '  Science  ',
        department: 'Computer Science',
        level: '300',
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body['faculty'], 'Science');
      expect(body['department'], 'Computer Science');
      expect(body['level'], '300');
      // The console shows the target on the tile it has just added.
      expect(created.exam.isTargeted, isTrue);
      expect(
        created.exam.targetLabel,
        'Computer Science · Science · 300 Level',
      );
    });

    test('a paper aimed at nobody sends no label keys at all', () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'exam-12',
        'title': 'GST101: Communication Skills',
        'created_by': '11111111-1111-4111-8111-111111111111',
        'duration_minutes': 30,
        'is_published': false,
      });

      final repo = QuestionAuthoringRepositoryImpl(
        client,
        currentUserId: () => '11111111-1111-4111-8111-111111111111',
      );
      final created = await repo.createExam(
        title: 'GST101: Communication Skills',
        durationMinutes: 30,
        isPublished: false,
        // A cleared dropdown arrives as blank text, which means "not narrowed":
        // the columns store NULL, never the empty string.
        faculty: '   ',
        department: '',
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      for (final key in <String>['faculty', 'department', 'level']) {
        expect(body.containsKey(key), isFalse, reason: '$key was sent blank');
      }
      // A database from before the columns existed answers without them, and
      // that has to read as "not narrowed" rather than throwing.
      expect(created.exam.isTargeted, isFalse);
      expect(created.exam.targetLabel, isNull);
    });

    test('a roster page goes up as `students`, and its answer is read back',
        () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'created': <Map<String, dynamic>>[
          {
            'id': '22222222-2222-4222-8222-222222222222',
            'email': 'ada@uni.test',
            'full_name': 'Ada Nwosu',
            'role': 'student',
            'faculty': 'Science',
            'department': 'Computer Science',
            'level': '300',
            'temporary_password': 'Pg-4f9c21',
          },
        ],
        'failed': <Map<String, dynamic>>[
          {
            'email': 'taken@uni.test',
            'error': 'taken@uni.test already has an account.',
          },
        ],
      });

      final repo = AdminUserRepositoryImpl(client);
      final outcome = await repo.createStudentAccounts(
        const <NewStudentAccount>[
          NewStudentAccount(
            email: 'ada@uni.test',
            fullName: 'Ada Nwosu',
            faculty: 'Science',
            department: 'Computer Science',
            level: '300',
          ),
          // Labels it does not know are absent from the row, not sent as null.
          NewStudentAccount(email: 'taken@uni.test', fullName: 'Taken Nwosu'),
        ],
      );

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/functions/v1/admin-create-user');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      // One key, and no `role`: the function makes every roster row a student,
      // so a file cannot mint a lecturer by carrying a column for it.
      expect(body.keys.toList(), <String>['students']);
      expect(body['students'], <dynamic>[
        <String, dynamic>{
          'email': 'ada@uni.test',
          'full_name': 'Ada Nwosu',
          'faculty': 'Science',
          'department': 'Computer Science',
          'level': '300',
        },
        <String, dynamic>{
          'email': 'taken@uni.test',
          'full_name': 'Taken Nwosu',
        },
      ]);

      // A refused row is an *answer*, not an exception: the rest of the class
      // was created and the report has to say both.
      expect(outcome.createdCount, 1);
      expect(outcome.created.single.account.faculty, 'Science');
      expect(outcome.created.single.temporaryPassword, 'Pg-4f9c21');
      expect(outcome.failedCount, 1);
      expect(outcome.failed.single.email, 'taken@uni.test');
      // The one control the administrator actually needs afterwards.
      expect(outcome.handoverSheet, 'ada@uni.test\tPg-4f9c21');
    });

    test('a page the server would refuse never leaves the device', () async {
      final repo = AdminUserRepositoryImpl(client);

      // An empty page is not a request at all.
      final nothing =
          await repo.createStudentAccounts(const <NewStudentAccount>[]);
      expect(nothing.isEmpty, isTrue);

      // One row over the limit is a paging bug, caught here rather than by the
      // function's 400 - the caller pages by this same number.
      await expectLater(
        repo.createStudentAccounts(<NewStudentAccount>[
          for (var i = 0; i <= AdminUserRepository.maxStudentPageSize; i++)
            NewStudentAccount(email: 's$i@uni.test', fullName: 'Student $i'),
        ]),
        throwsA(
          isA<AdminAccountException>().having(
            (error) => error.message,
            'message',
            contains('at most ${AdminUserRepository.maxStudentPageSize}'),
          ),
        ),
      );
      expect(transport.requests, isEmpty);
    });

    test('the schema declares the labels on both tables and the borrow list',
        () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // `create table if not exists` cannot add a column to a table that is
      // already there, so every label is declared *and* added in place.
      for (final table in <String>['profiles', 'exams']) {
        for (final column in <String>['faculty', 'department', 'level']) {
          expect(
            RegExp(
              'alter table public\\.$table add column if not exists '
              '$column\\s+text;',
            ).hasMatch(sql),
            isTrue,
            reason: '$table.$column has no upgrade path',
          );
          expect(
            RegExp(
              'create table if not exists public\\.$table \\([\\s\\S]*?'
              '\\b$column\\s+text',
            ).hasMatch(sql),
            isTrue,
            reason: '$table.$column is missing from a fresh install',
          );
        }
      }

      // The borrow list: one row per (paper, student), cascading from both, and
      // the reverse index the student's side of `exams_select` walks.
      expect(
        sql,
        contains('create table if not exists public.exam_allowed_students ('),
      );
      expect(sql, contains('references public.exams(id) on delete cascade'));
      expect(sql, contains('references public.profiles(id) on delete cascade'));
      expect(sql, contains('primary key (exam_id, student_id)'));
      expect(sql, contains('idx_exam_allowed_students_student'));
    });

    test('exams_select narrows students by cohort and leaves staff unscoped',
        () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      final predicate = selectPredicate(sql, 'exams_select');
      expect(predicate, isNotNull);

      // Staff, and the author of a draft, see every paper: an invigilator opens
      // sittings in any department.
      expect(predicate, contains('public.is_staff()'));
      expect(predicate, contains('created_by = auth.uid()'));
      // A student only ever sees a paper the named predicate says is theirs. The
      // rule itself no longer lives in this policy: it is
      // `public.student_can_access_exam(id)`, so that the question feed and the
      // attempt-insert policy ask the same question instead of carrying three
      // copies of it that could drift apart.
      expect(predicate, contains('public.student_can_access_exam(id)'));
      expect(
        predicate,
        isNot(contains('is_published')),
        reason: 'publication is asserted inside the helper, not repeated here',
      );

      // The rule, where it now lives: published, every named label must match the
      // student's own row (blank on the paper = no narrowing, blank on the
      // profile = no match), or the student is on the borrow list.
      final helperMatch = RegExp(
        r'create or replace function public\.student_can_access_exam'
        r'\(p_exam_id uuid\)[\s\S]*?as \$\$([\s\S]*?)\$\$;',
      ).firstMatch(sql.replaceAll('\r\n', '\n'));
      expect(helperMatch, isNotNull, reason: 'the cohort rule lost its home');
      final rule = helperMatch!.group(1)!.replaceAll(RegExp(r'\s+'), ' ');
      expect(rule, contains('e.is_published = true'));
      for (final column in <String>['faculty', 'department', 'level']) {
        expect(rule, contains("nullif(btrim(e.$column), '') is null"));
        expect(rule, contains("nullif(btrim(p.$column), '') is not null"));
        expect(
          rule,
          contains("lower(btrim(p.$column)) = lower(btrim(e.$column))"),
        );
      }
      expect(rule, contains('from public.exam_allowed_students a'));
      expect(rule, contains('a.exam_id = e.id and a.student_id = auth.uid()'));
    });

    test("the borrow list is the student's own row, writable by the author",
        () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // A student must not learn who *else* holds an exception.
      expect(
        selectPredicate(sql, 'exam_allowed_students_select'),
        contains('student_id = auth.uid()'),
      );
      // `owns_exam()` is SECURITY DEFINER, so the write check does not re-enter
      // `exams_select` - the policy that reads this very table.
      expect(sql, contains('with check (public.owns_exam(exam_id))'));
      expect(sql, contains('using (public.owns_exam(exam_id))'));
    });

    test('the upgrade migration carries the same DDL and the same policy', () {
      final file = File('../supabase/migrations/academic_targeting.sql');
      if (!file.existsSync()) return; // a checkout without ../supabase
      final sql = file.readAsStringSync();

      for (final table in <String>['profiles', 'exams']) {
        for (final column in <String>['faculty', 'department', 'level']) {
          expect(
            RegExp(
              'alter table public\\.$table add column if not exists '
              '$column\\s+text;',
            ).hasMatch(sql),
            isTrue,
            reason: '$table.$column is not added by the migration',
          );
        }
      }
      expect(
        sql,
        contains('create table if not exists public.exam_allowed_students ('),
      );
      // Recreating a policy on a name the old revision used is a 42710 unless
      // it is dropped first.
      for (final policy in <String>[
        'exams_select',
        'exam_allowed_students_select',
        'exam_allowed_students_insert_owner',
        'exam_allowed_students_delete_owner',
      ]) {
        expect(
          sql,
          contains('drop policy if exists "$policy"'),
          reason: '$policy is recreated without being dropped first',
        );
      }

      // The `exams_select` predicate is deliberately NOT compared here because
      // `supabase/migrations/academic_targeting.sql` was restored to its
      // original (pre-strict-targeting) form.  The predicate is compared
      // against `supabase/migrations/strict_targeting_null_profiles.sql`
      // in the test that follows.
    });

    test('strict-targeting migration carries the same exams_select policy', () {
      final file = File(
        '../supabase/migrations/strict_targeting_null_profiles.sql',
      );
      if (!file.existsSync()) return; // a checkout without ../supabase
      final sql = file.readAsStringSync();

      expect(sql, contains('drop policy if exists "exams_select"'));

      // The historical file still installs the strict rule **inline** - that is
      // what a project which predates the helper needs - while `schema.sql` now
      // delegates the same rule to `public.student_can_access_exam()`. The two are
      // no longer textually equal, on purpose, so the contract is that each keeps
      // its own half: the migration the strict terms, `schema.sql` the delegation -
      // and that the migration is marked so it cannot be applied back over the
      // hardened policy by mistake.
      final historical = selectPredicate(sql, 'exams_select');
      expect(historical, contains('is_published = true'));
      for (final column in <String>['faculty', 'department', 'level']) {
        expect(
          historical,
          contains("nullif(btrim(exams.$column), '') is null"),
        );
      }
      expect(historical, contains('from public.exam_allowed_students a'));
      expect(sql, contains('DO NOT RE-RUN AFTER APPLYING'));

      final schema = schemaSql();
      if (schema == null) return;
      expect(
        selectPredicate(schema, 'exams_select'),
        contains('public.student_can_access_exam(id)'),
      );
    });

    test('submissions_insert_own_ongoing asks the cohort rule itself, '
        'and keeps the window', () {
      final sql = schemaSql();
      if (sql == null) return;

      // This policy used to rely on `exams_select` filtering the inner subquery,
      // which is not what a SELECT policy does for an INSERT's WITH CHECK: an
      // out-of-cohort student could start a paper they could not see, and then
      // read its questions. It now asks
      // `public.student_can_access_exam(exam_id)` itself.
      final policyStart = sql.indexOf(
        'create policy "submissions_insert_own_ongoing"',
      );
      expect(policyStart, greaterThanOrEqualTo(0));
      final policyEnd = sql.indexOf(';', policyStart);
      final policyBody = policyEnd >= 0
          ? sql.substring(policyStart, policyEnd + 1)
          : sql.substring(policyStart);
      final normalised = policyBody.replaceAll(RegExp(r'\s+'), ' ');

      expect(normalised, contains('public.student_can_access_exam(exam_id)'));
      // The labels stay in one place - the helper - so this policy does not
      // carry a second copy of the comparison.
      expect(normalised, isNot(contains('nullif(btrim')));
      // Publication is asserted by the helper now, so it is not repeated here.
      expect(normalised, isNot(contains('e.is_published')));
      // The window stayed, and this is still its only server-side check.
      expect(
        normalised,
        contains('e.starts_at is null or now() >= e.starts_at'),
      );
      expect(normalised, contains('e.ends_at'));
      // Everything the "fresh attempt" rule needs is still there.
      for (final requirement in <String>[
        'student_id = auth.uid()',
        "status = 'ongoing'",
        'score is null',
        "answers = '{}'::jsonb",
        'submitted_at is null',
        'started_at = now()',
      ]) {
        expect(
          normalised,
          contains(requirement),
          reason: '$requirement is load-bearing',
        );
      }
    });

    test('the identity numbers are declared, optional, and forwarded', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // `profiles` only: a paper is aimed at a cohort, never at one person's
      // matriculation number, so `exams` gets neither column.
      for (final column in <String>['matric_number', 'staff_id']) {
        expect(
          RegExp(
            'alter table public\\.profiles add column if not exists '
            '$column\\s+text;',
          ).hasMatch(sql),
          isTrue,
          reason: 'profiles.$column has no upgrade path',
        );
        expect(
          RegExp(
            'create table if not exists public\\.profiles \\([\\s\\S]*?'
            '\\b$column\\s+text',
          ).hasMatch(sql),
          isTrue,
          reason: 'profiles.$column is missing from a fresh install',
        );
        // Optional, deliberately: an account created without a number is the
        // account every install already has, and an import must not fail over a
        // missing cell.
        expect(
          RegExp('\\b$column\\s+text not null').hasMatch(sql),
          isFalse,
          reason: 'profiles.$column must stay nullable',
        );
      }

      // The upgrade file an existing project applies carries the same two
      // statements: `create table if not exists` is a no-op on a live project.
      final migration = File(
        '../supabase/migrations/profile_identity_numbers.sql',
      );
      if (!migration.existsSync()) return; // a checkout without ../supabase
      final upgrade = migration.readAsStringSync();
      for (final column in <String>['matric_number', 'staff_id']) {
        expect(
          RegExp(
            'alter table public\\.profiles add column if not exists '
            '$column\\s+text;',
          ).hasMatch(upgrade),
          isTrue,
          reason: '$column is not added by the migration',
        );
      }

      // The Edge Function reads both spellings and stores the column's own name,
      // so a JavaScript client's `matricNumber` lands in `matric_number`.
      final function = File('../supabase/functions/admin-create-user/index.ts');
      if (!function.existsSync()) return;
      final source = function.readAsStringSync();
      expect(source, contains('const IDENTITY_FIELDS'));
      for (final column in <String>['matric_number', 'staff_id']) {
        expect(source, contains('["$column"'), reason: '$column is not read');
      }
      expect(source, contains('stringField(payload, column, ...aliases)'));
      // A project that has not run the migration answers "column ... does not
      // exist"; the refusal has to name the file that fixes it, exactly as the
      // scheduling migration's message does.
      expect(source, contains('const PROFILE_METADATA_COLUMNS'));
      expect(source, contains('profile_identity_numbers.sql'));
      // Both branches go through `academicFields`, and the row insert spreads its
      // answer - one path, so neither can forget a column the other writes.
      expect(source, contains('academic: academicFields(payload)'));
      expect(source, contains('academic: academicFields(row)'));
    });
  });

  // ---------------------------------------------------------------------
  // The hardening wave (`supabase/migrations/2026110309*.sql`): a student
  // cannot retarget themselves, and a paper is not readable without being
  // aimed at you.
  // ---------------------------------------------------------------------
  group('exam visibility hardening', () {
    test('the cohort rule is one named predicate, asked by all three callers', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // SECURITY DEFINER + stable + a pinned search_path: the question is asked
      // from a policy on `exam_submissions` and from a definer view, neither of
      // which may assume the caller can read `profiles`.
      expect(
        RegExp(
          r'create or replace function public\.student_can_access_exam'
          r'\(p_exam_id uuid\)\s*returns boolean\s*language sql\s*'
          r'security definer\s*stable\s*set search_path = public',
        ).hasMatch(sql.replaceAll('\r\n', '\n')),
        isTrue,
        reason: 'student_can_access_exam() must be a definer/stable predicate',
      );

      // The three callers that must not be able to disagree: the paper list, the
      // question feed, and the attempt insert.
      expect(
        _policyUsing(sql, 'exams_select'),
        contains('public.student_can_access_exam(id)'),
      );
      expect(sql, contains('public.student_can_access_exam(e.id)'));
      expect(
        sql,
        contains('and public.student_can_access_exam(exam_id)'),
      );
    });

    test('the question feed is aimed, windowed and attempt-aware', () {
      final sql = schemaSql();
      if (sql == null) return;

      final match = RegExp(
        r'create view public\.questions_public as([\s\S]*?);\n',
      ).firstMatch(sql.replaceAll('\r\n', '\n'));
      expect(match, isNotNull, reason: 'the view left schema.sql');
      final view = match!.group(1)!;

      // Still no answer key, on either shape.
      expect(view, isNot(contains('correct_option')));
      expect(view, isNot(contains('correct_text_answer')));
      // The four audiences, and nothing as wide as `is_staff()`.
      expect(view, contains('public.can_supervise_exam(e.id)'));
      expect(view, contains('e.created_by = auth.uid()'));
      expect(view, contains('public.student_can_access_exam(e.id)'));
      expect(view, contains('e.starts_at'));
      expect(view, contains('make_interval(mins => e.duration_minutes)'));
      expect(view, isNot(contains('is_staff')));
      // The old blanket filter is what made the id guessable into a read.
      expect(view, isNot(contains('where e.is_published = true;')));
    });

    test('the feed is created after the table it joins', () {
      // A view body is resolved when the view is created, so `questions_public`
      // cannot be defined above `exam_submissions`: its LEFT JOIN names that table.
      // It used to sit at the end of section 3, above it - an order that only worked
      // because nothing replayed the file from scratch. The helper functions are the
      // same question (`language sql` bodies naming tables created further down), and
      // `set check_function_bodies = off` is what lets them be defined first.
      final sql = schemaSql();
      if (sql == null) return;
      final normalised = sql.replaceAll('\r\n', '\n');

      final tableAt = normalised.indexOf(
        'create table if not exists public.exam_submissions',
      );
      final viewAt = normalised.indexOf(
        'create view public.questions_public as',
      );
      expect(tableAt, greaterThan(-1), reason: 'the attempt table left schema.sql');
      expect(viewAt, greaterThan(-1), reason: 'the feed left schema.sql');
      expect(
        viewAt,
        greaterThan(tableAt),
        reason: 'questions_public joins exam_submissions, so it must follow it',
      );

      final flagAt = normalised.indexOf('set check_function_bodies = off;');
      expect(
        flagAt,
        greaterThan(-1),
        reason: 'the deferred body check left schema.sql',
      );
      final helperAt = normalised.indexOf(
        'create or replace function public.student_can_access_exam',
      );
      expect(helperAt, greaterThan(-1));
      expect(
        flagAt,
        lessThan(helperAt),
        reason: 'the flag has to precede the first helper that names a later table',
      );
    });

    test("a live attempt's evidence cannot be purged, a reset one can", () {
      // The reset sequence is delete -> purge -> audit, and this policy is what
      // makes the order the rule: an object is purgeable only once its folder no
      // longer resolves to a submission.
      final sql = schemaSql();
      if (sql == null) return;

      final purge = _policyUsing(sql, 'Proctor snapshots supervisor purge');
      expect(purge, contains("bucket_id = 'proctor-snapshots'"));
      expect(purge, contains('public.is_attempt_resetter()'));
      expect(purge, contains('not exists ('));
      expect(purge, contains('from public.exam_submissions s'));
      expect(
        purge,
        contains('s.id::text = (storage.foldername(name))[1]'),
        reason: 'the purge must use the same folder expression the read and '
            'upload policies use',
      );

      final migration = File(
        '../supabase/migrations/20261103090800_snapshot_purge_not_live_attempt.sql',
      );
      if (migration.existsSync()) {
        expect(
          _policyUsing(
            migration.readAsStringSync(),
            'Proctor snapshots supervisor purge',
          ),
          purge,
          reason: 'the upgrade migration and schema.sql disagree about the purge',
        );
      }

      // ... and the client already does it in that order, which is why the narrower
      // policy does not break "Reset attempt".
      final repo = File(
        '../mobile/lib/features/dashboard/data/repositories/dashboard_repository_impl.dart',
      );
      if (repo.existsSync()) {
        final source = repo.readAsStringSync();
        final deleteAt = source.indexOf('.delete()');
        final purgeAt = source.indexOf('.from(snapshotBucket).remove(');
        expect(deleteAt, greaterThan(-1));
        expect(purgeAt, greaterThan(-1));
        expect(
          deleteAt,
          lessThan(purgeAt),
          reason: 'resetSubmission() must delete the attempt before purging its '
              'snapshots, or the purge removes nothing',
        );
        // ... and that DELETE is the attempt's, not some other table's: the chain
        // it belongs to is `.from('exam_submissions')`.
        expect(
          source.lastIndexOf(".from('exam_submissions')", deleteAt),
          greaterThan(-1),
        );
      }
    });

    test('a lecturer reads their own papers and their own evidence only', () {
      final sql = schemaSql();
      if (sql == null) return;

      // The raw table: no `is_staff()` arm, so a colleague's draft is not
      // readable just because they are employed.
      expect(
        _policyUsing(sql, 'questions_select_supervisor'),
        'public.can_supervise_exam(exam_id) or public.owns_exam(exam_id)',
      );

      // Signing a URL is a SELECT, so this predicate is the read gate on the
      // evidence itself.
      final storage = _policyUsing(sql, 'Proctor snapshots read access');
      expect(storage, contains('public.can_supervise_exam(s.exam_id)'));
      expect(storage, contains('public.owns_exam(s.exam_id)'));
      expect(storage, isNot(contains('is_staff')));
    });

    test('the profile labels a policy compares are not self-service', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains('create or replace function public.guard_profile_labels()'),
      );
      // INSERT as well as UPDATE: a self-provisioned row must not arrive with a
      // cohort on it.
      expect(
        RegExp(
          r'create trigger profiles_guard_labels\s*'
          r'before insert or update on public\.profiles',
        ).hasMatch(sql.replaceAll('\r\n', '\n')),
        isTrue,
        reason: 'the label guard must fire on INSERT and UPDATE',
      );
      for (final column in <String>[
        'faculty',
        'department',
        'level',
        'matric_number',
        'staff_id',
        'email',
      ]) {
        expect(sql, contains('new.$column'), reason: '$column is not guarded');
      }
    });

    test('a snapshot path belongs to its attempt, and the strike still counts', () {
      final sql = schemaSql();
      if (sql == null) return;

      // The stored value must be the object this app mints and nothing else:
      // `<submission_id>/<action_type>_<epoch-ms>.(jpg|png)`, which is what
      // `SupabaseService.snapshotPath()` builds and what the bucket's mime list
      // accepts. A prefix-only test (`starts_with(...)`) also accepted names the app
      // never writes - `<own id>/evidence.jpg`, `<own id>/nested/x.jpg` - so the rule
      // is the whole shape, in the RPC and in the migration that upgrades a live
      // project.
      const shape =
          r"p_snapshot_url ~ ('^' || p_submission_id::text || '/[a-z_]+_[0-9]+\.(jpg|png)$')";
      expect(sql, contains(shape));
      expect(
        sql,
        isNot(contains('starts_with(p_snapshot_url')),
        reason: 'the prefix test is what the shape test replaced',
      );

      final migration = File(
        '../supabase/migrations/20261103090700_register_violation_snapshot_path.sql',
      );
      if (migration.existsSync()) {
        expect(
          migration.readAsStringSync(),
          contains(shape),
          reason: 'the upgrade migration and schema.sql disagree about the path',
        );
      }

      // The insert policy is where "may this student sit this paper" is enforced
      // server-side; the window stayed here with it.
      final match = RegExp(
        r'create policy "submissions_insert_own_ongoing"'
        r'[\s\S]*?with check \(([\s\S]*?)\);',
      ).firstMatch(sql.replaceAll('\r\n', '\n'));
      expect(match, isNotNull, reason: 'the insert policy left schema.sql');
      final check = match!.group(1)!.replaceAll(RegExp(r'\s+'), ' ');
      expect(check, contains('public.student_can_access_exam(exam_id)'));
      expect(check, contains('started_at = now()'));
      expect(check, contains('starts_at'));
      expect(check, contains('ends_at'));
    });
  });

  group('weighted strikes contract', () {
    /// The `insert into public.violation_weights ... on conflict ...;` block, so a
    /// row can be compared where it is *seeded* rather than anywhere the word
    /// appears in a comment.
    String? weightSeed(String sql) => RegExp(
          r'insert into public\.violation_weights[\s\S]*?'
          r'on conflict \(action_type\) do nothing;',
        ).firstMatch(sql.replaceAll('\r\n', '\n'))?.group(0);

    test('every ViolationType is seeded, with the weight the client mirrors', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      final seed = weightSeed(sql);
      expect(seed, isNotNull, reason: 'schema.sql has no violation_weights seed');

      for (final type in ViolationType.values) {
        final row = RegExp(
          "\\('${RegExp.escape(type.dbValue)}',\\s*(\\d+),\\s*(true|false)\\)",
        ).firstMatch(seed!);
        expect(
          row,
          isNotNull,
          reason: '${type.dbValue} has no violation_weights row - a type with no '
              'row is scored as one point, so silence is not a safe default',
        );
        expect(
          int.parse(row!.group(1)!),
          type.weight,
          reason: '${type.dbValue}: schema weight and ViolationType.weight disagree',
        );
        expect(
          row.group(2) == 'true',
          type.countsTowardDisqualification,
          reason: '${type.dbValue}: schema counts_toward_dq and the client disagree',
        );
      }
    });

    test('the upgrade migration seeds the same vocabulary', () {
      final migration = File(
        '../supabase/migrations/20261104090000_violation_weights.sql',
      );
      if (!migration.existsSync()) return;

      final seed = weightSeed(migration.readAsStringSync());
      expect(seed, isNotNull);
      for (final type in ViolationType.values) {
        expect(
          seed,
          contains("('${type.dbValue}',"),
          reason: '${type.dbValue} is missing from the migration',
        );
      }
    });
    test('the migration that counts the glance and the noise says so, and is safe '
        'to re-run', () {
      // `looking_away` and `audio_noise` are counted strikes now. The upgrade for a
      // project that already carries the old (0, false) rows is one UPDATE, and it
      // has to be:
      //  * exactly those two types - a stray third would silently re-price a signal
      //    nobody asked about;
      //  * an UPDATE, not an INSERT or a rewrite of `proctoring_logs`, so it can run
      //    twice and so no evidence changes;
      //  * present in the apply lists, or an operator following the README would
      //    never run it.
      final migration = File(
        '../supabase/migrations/20261108090000_looking_away_and_noise_count.sql',
      );
      expect(
        migration.existsSync(),
        isTrue,
        reason: 'the live project needs a file to run, not just a schema.sql edit',
      );
      final sql = migration.readAsStringSync().replaceAll('\r\n', '\n');

      expect(
        sql,
        contains(
          'update public.violation_weights\n'
          '   set weight = 1,\n'
          '       counts_toward_dq = true\n'
          " where action_type in ('looking_away', 'audio_noise');",
        ),
        reason: 'the migration is the single statement the plan specifies',
      );
      // Only those two types, and it must not touch evidence or attempts.
      expect(sql, isNot(contains("'copy_paste_attempt'")));
      expect(sql, isNot(contains("'right_click_blocked'")));
      expect(sql, isNot(contains("'idle_afk'")));
      expect(sql, isNot(contains('update public.proctoring_logs')));
      expect(sql, isNot(contains('update public.exam_submissions')));
      expect(sql, isNot(contains('insert into public.violation_weights')));

      // Every header section the repository's migrations carry, so the file explains
      // itself to whoever is about to run it on a live project.
      for (final section in <String>[
        '-- WHY THIS FILE EXISTS',
        '-- WHAT CHANGES',
        '-- WHAT IT DOES NOT DO',
        '-- SAFETY',
        '-- APPLY ORDER',
        '-- Verify',
      ]) {
        expect(sql, contains(section), reason: 'missing section: $section');
      }

      // The client mirror has to agree with the new values, and the seeding
      // migration keeps its historical (0, false) rows - which is why this UPDATE
      // exists rather than an edit in place.
      expect(ViolationType.lookingAway.weight, 1);
      expect(ViolationType.audioNoise.weight, 1);
      expect(ViolationType.lookingAway.countsTowardDisqualification, isTrue);
      expect(ViolationType.audioNoise.countsTowardDisqualification, isTrue);

      // And the two apply scripts list it, or it is a file nobody runs.
      for (final script in <String>['../apply_in_order.ps1', '../apply_live_cli.ps1']) {
        final file = File(script);
        if (!file.existsSync()) continue;
        expect(
          file.readAsStringSync(),
          contains('20261108090000_looking_away_and_noise_count'),
          reason: '$script does not apply the new migration',
        );
      }
    });



    test('register_violation scores through the table and flags, never disqualifies',
        () {
      final sql = schemaSql();
      if (sql == null) return;

      // The client mirror and the server's constant have to be the same number, or
      // the console's "how close is this" explanation lies.
      expect(
        sql,
        contains(
          'c_flag_threshold constant int := '
          '${ProctoringRisk.disqualificationThreshold}',
        ),
      );
      expect(
        sql,
        contains(
          'left join public.violation_weights w on w.action_type = l.action_type',
        ),
        reason: 'the score must come from the weights table',
      );
      expect(
        sql,
        contains('returns table(warning_count int, disqualified boolean, flagged boolean)'),
      );
      expect(
        sql,
        contains("set status = 'flagged_for_review'"),
        reason: 'the threshold closes the attempt for review',
      );
      expect(
        sql,
        isNot(contains('if v_count >= 3 then')),
        reason: 'the row count is not the rule any more',
      );
    });

    test('the upgrade drops the old return shape before it recreates the function',
        () {
      final migration = File(
        '../supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql',
      );
      if (!migration.existsSync()) return;
      final sql = migration.readAsStringSync().replaceAll('\r\n', '\n');

      // `create or replace function` can change a body, never a return type. On a
      // project that still carries the two-column `(warning_count, disqualified)`
      // version the `create` fails with 42P13 - "cannot change return type of
      // existing function" - and the upgrade stops there, having already added the
      // weights table and the new status. The signature has to be dropped first,
      // and the grants re-applied afterwards because a drop takes the ACL with it.
      final dropped = sql.indexOf(
        'drop function if exists '
        'public.register_violation(uuid, text, text, timestamptz, uuid);',
      );
      final created = sql.indexOf(
        'create or replace function public.register_violation(',
      );
      expect(
        dropped,
        greaterThanOrEqualTo(0),
        reason: 'a widened return shape can only be replaced by dropping the '
            'function first',
      );
      expect(
        dropped,
        lessThan(created),
        reason: 'a drop after the create would delete the new definition',
      );
      expect(
        sql.indexOf(
          'grant execute on function '
          'public.register_violation(uuid, text, text, timestamptz, uuid)',
        ),
        greaterThan(created),
        reason: 'the drop removed the grants, so they have to be granted again',
      );
    });

    test('the status check accepts flagged_for_review, and the enum matches it', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains(
          "check (status in ('ongoing', 'flagged_for_review', 'submitted', 'disqualified'))",
        ),
      );
      expect(SubmissionStatus.flaggedForReview.dbValue, 'flagged_for_review');
      expect(
        SubmissionStatus.fromDb('flagged_for_review'),
        SubmissionStatus.flaggedForReview,
      );

      final migration = File(
        '../supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql',
      );
      if (!migration.existsSync()) return;
      expect(
        migration.readAsStringSync(),
        contains(
          "check (status in ('ongoing', 'flagged_for_review', 'submitted', 'disqualified'))",
        ),
      );
    });
  });

  group('review decision contract', () {
    test('resolve_flagged_attempt is supervisor-tier, audited and idempotent', () {
      final sql = schemaSql();
      if (sql == null) return;

      final start = sql.indexOf(
        'create or replace function public.resolve_flagged_attempt(',
      );
      expect(start, greaterThan(-1), reason: 'the resolve RPC left schema.sql');
      final end = sql.indexOf(
        'comment on function public.resolve_flagged_attempt',
        start,
      );
      final fn = sql.substring(start, end);

      // Supervisor, or the lecturer who wrote *this* paper - never `is_staff()`
      // (every lecturer) and never the student under review.
      expect(
        fn,
        contains('public.can_supervise_exam(v_exam) or public.owns_exam(v_exam)'),
      );
      expect(fn, isNot(contains('is_staff()')));
      // The audit row, and an actor the database decides rather than the request.
      expect(fn, contains('insert into public.attempt_review_logs'));
      expect(fn, isNot(contains('p_actor_id')));
      // Both outcomes, and "clear" recomputes the automatic mark so the attempt is
      // gradable rather than merely open.
      expect(fn, contains("v_to := 'disqualified'"));
      expect(fn, contains("v_to := 'submitted'"));
      expect(fn, contains('public.auto_graded_score(p_submission_id)'));
      // Retry-safe: an attempt that is no longer flagged answers with its status.
      expect(fn, contains("if v_status <> 'flagged_for_review' then"));

      expect(
        sql,
        contains(
          'revoke execute on function public.resolve_flagged_attempt(uuid, text, text) from public, anon;',
        ),
      );
    });

    test('the review trail is readable by staff and writable by nobody else', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains('create table if not exists public.attempt_review_logs'),
      );
      final using = _policyUsing(sql, 'attempt_review_logs_select_staff');
      expect(using, isNotNull, reason: 'the audit trail needs a read policy');
      expect(using, contains('public.can_supervise_exam(exam_id)'));
      expect(using, contains('public.owns_exam(exam_id)'));
      expect(
        sql,
        isNot(contains('on public.attempt_review_logs for insert')),
        reason: 'the definer RPC is the only writer of a review row',
      );
    });

    test('grade_submission refuses an attempt under review', () {
      final sql = schemaSql();
      if (sql == null) return;
      expect(
        sql,
        contains('is under review and is not graded until it is resolved'),
      );

      // The migration carries its own copy of the function; a fix applied to one
      // and not the other is exactly the drift this assertion exists for.
      final migration = File(
        '../supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql',
      );
      if (!migration.existsSync()) return;
      expect(
        migration.readAsStringSync(),
        contains('is under review and is not graded until it is resolved'),
      );
    });

    test('the repository maps the flagged column, and tolerates an old server',
        () async {
      transport.responseBody =
          '[{"warning_count": 3, "disqualified": false, "flagged": true}]';
      final result = await ProctoringRepositoryImpl(client).logViolation(
        submissionId: 'sub-1',
        violation: Violation(
          type: ViolationType.multipleFaces,
          timestamp: DateTime.utc(2026),
        ),
      );
      expect(result.warningCount, 3);
      expect(result.flagged, isTrue);
      expect(result.disqualified, isFalse);

      // A backend that predates the column answers without it: no crash, and never
      // a flag the server did not send (that would end a live session).
      transport.responseBody = '[{"warning_count": 1, "disqualified": false}]';
      final old = await ProctoringRepositoryImpl(client).logViolation(
        submissionId: 'sub-1',
        violation: Violation(
          type: ViolationType.lookingAway,
          timestamp: DateTime.utc(2026),
        ),
      );
      expect(old.flagged, isFalse);
    });
  });

  group('proctoring heartbeats', () {
    test('the series is readable by the same audience as the evidence', () {
      final sql = schemaSql();
      if (sql == null) return;

      final read = _policyUsing(sql, 'heartbeats_select_own_or_supervisor');
      expect(read, contains('s.student_id = auth.uid()'));
      expect(read, contains('public.owns_exam(s.exam_id)'));
      expect(read, contains('public.can_supervise_exam(s.exam_id)'));

      // The write side is deliberately absent, and that absence *is* the control:
      // a client-insertable heartbeat table would let a tampered client backfill
      // the tidy series it never sent - the one thing these rows exist to make
      // hard. So there must be no insert/update/delete policy at all.
      for (final action in <String>['insert', 'update', 'delete']) {
        expect(
          RegExp('on public\\.proctor_heartbeats\\s+for $action')
              .hasMatch(sql.replaceAll('\r\n', '\n')),
          isFalse,
          reason: 'record_heartbeat() must stay the only writer ($action)',
        );
      }
      expect(
        sql,
        contains('grant select on public.proctor_heartbeats to authenticated'),
      );
      expect(sql, contains('revoke all on public.proctor_heartbeats from anon'));
    });

    test('a replayed beat is stored once and a throttled one still counts', () {
      final sql = schemaSql();
      if (sql == null) return;
      final body = _functionBody(sql, 'record_heartbeat');
      expect(body, isNotNull);

      // One row per queued beat, however many times the queue replays it. The
      // partial index is what the `on conflict` below targets, and the `where`
      // clause keeps the many beats with no id at all from colliding.
      expect(
        sql.replaceAll('\r\n', '\n'),
        contains(
          'on public.proctor_heartbeats(client_event_id)\n'
          '  where client_event_id is not null',
        ),
      );
      expect(
        body,
        contains(
          'on conflict (client_event_id) where client_event_id is not null do nothing',
        ),
      );

      // Three outcomes, and only one of them grew the table.
      expect(body, contains("'recorded'"));
      expect(body, contains("'duplicate'"));
      expect(body, contains("'throttled'"));

      // The window must be shorter than the client's 15s cadence, or an honest
      // client would be throttled by ordinary jitter.
      expect(body, contains("interval '8 seconds'"));

      // Every outcome refreshes liveness, so a beat the server chose not to store
      // is still proof the client is talking to us now: three stamps, one per
      // branch.
      expect(
        RegExp('set last_heartbeat_at = v_now')
            .allMatches(body!)
            .length,
        3,
        reason: 'recorded, duplicate and throttled must each stamp liveness',
      );

      // A closed attempt cannot report for duty: accepting the beats would keep a
      // finished sitting's coverage looking healthy after the fact.
      expect(body, contains("v_sub.status <> 'ongoing'"));
      expect(body, contains('security definer'));

      // `beat_count` is declared int and `count(*)` is bigint. A RETURN QUERY is
      // type-checked against the declared row type exactly - unlike `select ...
      // into`, it applies no assignment cast - so a bare count fails on the first
      // call with "Returned type bigint does not match expected type integer in
      // column 3". Every count a RETURN QUERY returns has to be cast.
      expect(body, contains('count(*)::integer'));
      final returned = RegExp(r'return query[\s\S]*?;')
          .allMatches(body)
          .map((match) => match.group(0)!.replaceAll(RegExp(r'\s+'), ' '));
      expect(returned, isNotEmpty);
      for (final statement in returned) {
        expect(
          RegExp(r'count\(\*\)(?!::integer)').hasMatch(statement),
          isFalse,
          reason: 'a RETURN QUERY returns count(*)::integer, not bigint: '
              '$statement',
        );
      }
    });

    test('coverage flags an attempt for a human and never ends one', () {
      final sql = schemaSql();
      if (sql == null) return;
      final body = _functionBody(sql, 'proctoring_coverage');
      expect(body, isNotNull);

      // The three numbers the report is made of: the cadence the client is
      // expected to keep, the gap worth a supervisor's time, and the quiet start
      // every attempt has while the camera and the detector boot.
      expect(body, contains('c_expected_interval constant numeric  := 15'));
      expect(body, contains('c_gap_threshold     constant int      := 60'));
      expect(body, contains("interval '90 seconds'"));

      // The flag's own wording, which is what stops it being read as a verdict.
      expect(body, contains('coverage never disqualifies an attempt'));

      // Nothing here writes: coverage informs a human, it does not act.
      expect(body, isNot(contains('update public.exam_submissions')));
      expect(body, isNot(contains('set status')));
      expect(body, isNot(contains('delete from')));

      // SECURITY DEFINER, so the visibility rule the RLS policy would have
      // applied has to be spelled out - and it names the same three audiences.
      expect(body, contains('v_sub.student_id = auth.uid()'));
      expect(body, contains('public.owns_exam(v_sub.exam_id)'));
      expect(body, contains('public.can_supervise_exam(v_sub.exam_id)'));

      // The exam-wide wrapper filters visibility *before* the lateral call, so a
      // student asking about their own paper gets their row instead of an
      // exception raised for a classmate's.
      final examWide = _functionBody(sql, 'proctoring_coverage_for_exam');
      expect(
        examWide,
        contains('cross join lateral public.proctoring_coverage'),
      );
      expect(examWide, contains('where s.exam_id = p_exam_id'));
      expect(examWide, contains('s.student_id = auth.uid()'));
    });

    test('the beat series expires with the evidence it explains', () {
      final file = File('../supabase/migrations/retention_policy.sql');
      if (!file.existsSync()) return;
      final retention = file.readAsStringSync();

      expect(
        retention,
        contains(
          'create or replace function public.purge_expired_proctor_heartbeats(',
        ),
      );
      // Seeded from a policy row, so an institution can change the window without
      // editing SQL; and a table with no enabled policy purges *nothing* rather
      // than everything.
      expect(retention, contains("values ('proctor_heartbeats', 30)"));
      expect(retention, contains('nothing purged'));

      // A live attempt's beats are never pruned: deleting them would punch a hole
      // in a report that is still being written and then read as a gap the client
      // never caused - the worst kind of false positive in this system.
      final purge =
          _functionBody(retention, 'purge_expired_proctor_heartbeats');
      expect(purge, isNotNull);
      expect(
        RegExp(r"s\.status <> 'ongoing'").allMatches(purge!).length,
        2,
        reason: 'the dry run and the delete must share the ongoing-attempt guard',
      );

      // Nightly on its own schedule, so a slow incident purge cannot starve it.
      expect(retention, contains("'proctor-heartbeats-retention'"));
      expect(
        retention,
        contains("'select public.purge_expired_proctor_heartbeats()'"),
      );
    });

    test('a project created from schema.sql and one upgraded agree', () {
      final sql = schemaSql();
      final migration = File(
        '../supabase/migrations/20261105090000_proctor_heartbeats.sql',
      );
      if (sql == null || !migration.existsSync()) return;
      final upgrade = migration.readAsStringSync();

      // The SQL that runs must be identical: comments may differ (schema.sql
      // explains the same function to a different reader), but a definition that
      // drifted would enforce something different in a fresh project than in an
      // upgraded one, and nothing else in the repository would notice.
      //
      // `record_heartbeat` is still this file's own definition. The two coverage
      // readers and the read policy were re-created by
      // `20261109090000_supervisor_exam_assignments.sql` (their supervisor arm is the
      // scope question now), so *that* is the file a fresh install has to agree with.
      expect(
        _functionBody(upgrade, 'record_heartbeat'),
        _functionBody(sql, 'record_heartbeat'),
        reason: 'record_heartbeat differs between schema.sql and its migration',
      );

      final scope = File(
        '../supabase/migrations/20261109090000_supervisor_exam_assignments.sql',
      );
      if (scope.existsSync()) {
        final scopeSql = scope.readAsStringSync();
        for (final name in <String>[
          'proctoring_coverage',
          'proctoring_coverage_for_exam',
        ]) {
          expect(
            _functionBody(scopeSql, name),
            _functionBody(sql, name),
            reason: '$name differs between schema.sql and the scope migration',
          );
        }
        expect(
          _policyUsing(scopeSql, 'heartbeats_select_own_or_supervisor'),
          _policyUsing(sql, 'heartbeats_select_own_or_supervisor'),
          reason: 'the scope migration and schema.sql disagree about the read policy',
        );
      }

      // The column the live grid reads, on both paths: created with the table, and
      // added to a project that already had `exam_submissions`.
      expect(sql, contains('last_heartbeat_at timestamptz'));
      expect(upgrade, contains('add column if not exists last_heartbeat_at'));
    });

    test('the client sends the argument names the RPC declares', () async {
      transport.responseBody =
          '[{"outcome":"recorded","recorded_at":"2026-01-01T10:00:00Z",'
          '"beat_count":1}]';
      final repo = ProctoringRepositoryImpl(client);

      final ack = await repo.recordHeartbeat(
        submissionId: 'sub-1',
        cameraOk: true,
        monitoringOk: false,
        appVersion: '1.0.0+1',
        clientTime: DateTime.utc(2026, 1, 1, 10),
        clientEventId: '9f1a4d0e-0f6b-4a1e-9a2b-6c2d2b7a3f11',
      );

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/record_heartbeat');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{
        'p_submission_id',
        'p_camera_ok',
        'p_monitoring_ok',
        'p_app_version',
        'p_client_time',
        'p_client_event_id',
      });
      // The camera state is the point of the beat, so it must travel even when it
      // is the default; the version and the device clock are diagnostics.
      expect(body['p_monitoring_ok'], isFalse);
      expect(body['p_app_version'], '1.0.0+1');
      expect(body['p_client_time'], '2026-01-01T10:00:00.000Z');

      expect(ack.outcome, HeartbeatOutcome.recorded);
      expect(ack.beatCount, 1);
      expect(ack.provesLiveness, isTrue);
    });
  });

  group('proctoring consent', () {
    test('the record of consent is write-once for the student who gave it', () {
      final sql = schemaSql();
      if (sql == null) return;
      final normalised = sql.replaceAll('\r\n', '\n');

      // The table survives a deleted paper (no FK on `exam_id`) and a null paper
      // means "every paper". Losing either shape would break the general
      // acceptance the policy explicitly supports.
      expect(
        normalised,
        contains('create table if not exists public.proctoring_consents'),
      );
      expect(RegExp(r'exam_id\s+uuid,').hasMatch(normalised), isTrue);
      expect(RegExp(r'consent_version\s+text not null').hasMatch(normalised), isTrue);
      expect(RegExp(r'user_agent\s+text').hasMatch(normalised), isTrue);

      // Accepting is your own act, and only your own.
      expect(
        _policyWithCheck(sql, 'consents_insert_own'),
        contains('student_id = auth.uid()'),
      );

      // Read: own rows, or the supervisor of the paper the acceptance names. Not
      // `is_staff()` - a lecturer reads the evidence of a sitting, not a person's
      // agreement - and not the tier any more: a supervisor reads the acceptances of
      // the papers assigned to them (`can_supervise_exam()`), which is why a general
      // acceptance (`exam_id IS NULL`) is not in this arm at all.
      final read = _policyUsing(sql, 'consents_select_own_or_supervisor');
      expect(read, contains('student_id = auth.uid()'));
      expect(read, contains('exam_id is not null'));
      expect(read, contains('public.can_supervise_exam(exam_id)'));
      expect(read, isNot(contains('is_staff')));

      // The absence *is* the control: no UPDATE or DELETE policy, and no grant
      // past select/insert.
      for (final action in <String>['update', 'delete']) {
        expect(
          RegExp('on public\\\\.proctoring_consents\\\\s+for $action')
              .hasMatch(normalised),
          isFalse,
          reason: 'an acceptance must not be editable or erasable ($action)',
        );
      }
      expect(
        normalised,
        contains(
          'grant select, insert on table public.proctoring_consents to authenticated',
        ),
      );
      expect(
        normalised,
        contains('revoke all on table public.proctoring_consents from anon'),
      );
    });

    test('the attempt policy asks for an acceptance', () {
      final sql = schemaSql();
      if (sql == null) return;

      final check = _policyWithCheck(sql, 'submissions_insert_own_ongoing');
      expect(check, contains('public.student_has_consent(exam_id)'));
      // ...without losing any of the checks that were already there.
      expect(check, contains('public.student_can_access_exam(exam_id)'));
      expect(check, contains('started_at = now()'));
      expect(check, contains('answers = '));

      // `student_can_access_exam()` itself must NOT grow a consent arm: it also
      // answers `exams_select` and `questions_public`, and a student has to be
      // able to read a paper before deciding whether to accept the notice for it.
      final access = _functionBody(sql, 'student_can_access_exam');
      expect(access, isNotNull);
      expect(access, isNot(contains('consent')));
    });

    test('the predicate asks for the current version, or a general acceptance', () {
      final sql = schemaSql();
      if (sql == null) return;

      final body = _functionBody(sql, 'student_has_consent');
      expect(body, isNotNull);
      expect(body, contains('c.student_id = auth.uid()'));
      expect(
        body,
        contains('c.consent_version = public.current_proctor_consent_version()'),
      );
      expect(body, contains('(c.exam_id is null or c.exam_id = p_exam_id)'));
      expect(body, contains('security definer'));
    });

    test('accepting is idempotent and records what the client displayed', () {
      final sql = schemaSql();
      if (sql == null) return;

      final body = _functionBody(sql, 'record_consent');
      expect(body, isNotNull);
      // The version is evidence, not input to be "corrected"; the paper must be
      // one the student may sit; and the client is never taken at its word about
      // who it is.
      expect(body, contains('v_student    uuid := auth.uid()'));
      expect(body, contains("using errcode = '28000'"));
      expect(body, contains("using errcode = '22023'"));
      expect(body, contains("using errcode = '42501'"));
      expect(body, contains('public.student_can_access_exam(p_exam_id)'));
      // The transport's own header, not a body field.
      expect(body, contains("current_setting('request.headers', true)"));
      expect(body, contains("->> 'user-agent'"));
      // Idempotent: a retry after a lost response returns the row that exists.
      expect(body, contains('on conflict do nothing'));
      // The answer the client needs: does what I stored actually count?
      expect(
        body,
        contains('v_version = public.current_proctor_consent_version()'),
      );

      // Every name in the INSERT's RETURNING list is qualified with the table's
      // alias. The OUT parameters are declared `consent_id`, `consent_version`,
      // `accepted_at` and `is_current`, and PL/pgSQL resolves a bare column name
      // against those variables first: `returning id, accepted_at into ...` raises
      //   42702  column reference "accepted_at" is ambiguous
      // on the *first call*, not at install time - the migration applies cleanly
      // and the RPC fails, which is why this is pinned here rather than left to a
      // live test.
      expect(body, contains('insert into public.proctoring_consents as c ('));
      expect(
        body,
        contains('returning c.id, c.accepted_at into v_id, v_accepted;'),
      );
      expect(
        body,
        isNot(contains('returning id, accepted_at')),
        reason: 'an unqualified RETURNING name is ambiguous against the OUT params',
      );
    });

    test('the app and the database agree on the shipped notice version', () {
      final sql = schemaSql();
      final migration =
          File('../supabase/migrations/20261106090000_proctoring_consents.sql');
      if (sql == null || !migration.existsSync()) return;

      // The seed is read out of the SQL rather than compared against a copy of the
      // string: bumping the wording in one place and not the other is exactly the
      // drift that would leave every student refused at the insert with
      // `is_current = false` and no clue why.
      final seed = RegExp(r"values \(1, '([^']+)'\)")
          .firstMatch(sql.replaceAll('\r\n', '\n'));
      expect(seed, isNotNull, reason: 'no consent version is seeded in schema.sql');
      expect(seed!.group(1), ProctorConsentConfig.version);

      final upgradeSeed = RegExp(r"values \(1, '([^']+)'\)").firstMatch(
        migration.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      expect(upgradeSeed?.group(1), ProctorConsentConfig.version);
    });

    test('the retention windows the notice quotes are the ones enforced', () {
      final file =
          File('../supabase/migrations/20261106090100_snapshot_retention.sql');
      if (!file.existsSync()) return;
      final retention = file.readAsStringSync().replaceAll('\r\n', '\n');

      int? windowFor(String table) {
        final match = RegExp("\\('$table', (\\d+)\\)").firstMatch(retention);
        return match == null ? null : int.parse(match.group(1)!);
      }

      // The consent notice renders these numbers from its own constants, so the
      // sentence a student accepts and the window the purge enforces are the same
      // value or this fails.
      expect(windowFor('proctor_snapshots'),
          ProctorConsentConfig.snapshotRetentionDays);
      expect(windowFor('exam_submissions'),
          ProctorConsentConfig.attemptRetentionDays);
      // "Align with your appeals period" - the account row too, not just the
      // attempt it belongs to.
      expect(windowFor('profiles'), ProctorConsentConfig.attemptRetentionDays);
    });

    test('the snapshot purge keeps the incident and never a live sitting', () {
      final file =
          File('../supabase/migrations/20261106090100_snapshot_retention.sql');
      if (!file.existsSync()) return;
      final retention = file.readAsStringSync();

      final body = _functionBody(retention, 'purge_expired_snapshots');
      expect(body, isNotNull);
      // The pointer goes, the row stays: a flag that happened still happened after
      // its photograph expired.
      expect(body, contains('set snapshot_url = null'));
      expect(body, isNot(contains('delete from public.proctoring_logs')));
      // A live sitting is exactly when a still matters.
      expect(body, contains("<> 'ongoing'"));
      // An operator can look before deleting, and a window of zero is refused
      // rather than clamped.
      expect(body, contains('p_dry_run'));
      expect(body, contains("interval '0'"));

      // Not scheduled: a job that deletes photographs is an operator's decision.
      expect(retention, isNot(contains('cron.schedule')));
    });

    test('the SQL purge reports the hosted guard instead of bypassing it', () {
      final file =
          File('../supabase/migrations/20261106090100_snapshot_retention.sql');
      if (!file.existsSync()) return;
      final retention = file.readAsStringSync();

      final body = _functionBody(retention, 'purge_expired_snapshots');
      expect(body, isNotNull);
      // `storage.objects` on a hosted project carries storage.protect_delete(),
      // which refuses every SQL DELETE (42501) unless the session sets
      // storage.allow_delete_query - the flag the Storage API sets on itself.
      // The function must NOT set it: it would remove the bookkeeping row and
      // strand the file, invisible to the Storage API for good. So the refusal is
      // translated into the route that actually deletes the photograph.
      expect(body, isNot(contains('allow_delete_query')));
      expect(body, isNot(contains('set_config')));
      expect(body, contains('when insufficient_privilege then'));
      // The SQLSTATE survives the translation, so a caller's own
      // `when sqlstate '42501'` still matches what it did before.
      expect(body, contains("errcode = '42501'"));
      expect(body, contains('storage.protect_delete()'));
      expect(body, contains('purge-snapshots Edge Function'));
      // And a refused run is not a count: it must not come back as 0, which reads
      // as "nothing had expired" and would have an operator stop looking.
      expect(body, contains('return v_deleted'));
    });

    test('the SQL tests stand in for the Storage API before they delete', () {
      final dir = Directory('../supabase/tests');
      if (!dir.existsSync()) return;
      // The flag the Storage API sets on itself while it deletes. Without it a
      // hosted project refuses every SQL delete from storage.objects with 42501,
      // and the test below would be reporting the guard instead of the policy or
      // the purge it is there to check.
      const standIn = "set_config('storage.allow_delete_query', 'true', true)";
      var sawDirectDelete = false;

      for (final file in dir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.sql'))) {
        final sql = file.readAsStringSync().replaceAll('\r\n', '\n');
        for (final delete
            in RegExp(r'delete from storage\.objects').allMatches(sql)) {
          sawDirectDelete = true;
          final before = sql.substring(0, delete.start);
          expect(
            before.lastIndexOf(standIn) > before.lastIndexOf(r'do $$'),
            isTrue,
            reason: '${file.path}: a direct delete from storage.objects has no '
                '$standIn earlier in its own DO block, so a hosted project '
                'refuses it with 42501',
          );
        }
      }

      // One delete is indirect: section (g) of the consent check calls the purge
      // function, whose live path deletes. It needs the same flag, or that
      // section fails on a hosted project for a reason that has nothing to do
      // with retention.
      final consents = File('../supabase/tests/proctoring_consents_check.sql');
      if (consents.existsSync()) {
        final sql = consents.readAsStringSync().replaceAll('\r\n', '\n');
        final call = _livePurgeCallIndex(sql);
        expect(call, greaterThan(-1));
        expect(
          sql.substring(0, call),
          contains(standIn),
          reason: 'the live purge call deletes from storage.objects',
        );
      }

      // A scan that quietly matched nothing would pass forever.
      expect(sawDirectDelete, isTrue);
    });

    test('the consent check sets the storage flag first, in the call\'s own '
        'block', () {
      final file = File('../supabase/tests/proctoring_consents_check.sql');
      if (!file.existsSync()) return;
      final sql = file.readAsStringSync().replaceAll('\r\n', '\n');

      // The flag the Storage API sets on itself while it deletes. On a hosted
      // project `storage.protect_delete()` refuses every other SQL delete from
      // `storage.objects` with 42501, and the live purge call below is one: the
      // function is `security definer`, but the delete inside it is still a plain
      // SQL delete.
      const standIn = "set_config('storage.allow_delete_query', 'true', true)";
      final call = _livePurgeCallIndex(sql);
      expect(call, greaterThan(-1), reason: 'the live purge call left the file');

      // ...inside the same DO block as the call. `is_local = true` really lasts
      // for the transaction, so a flag from an earlier block would still be in
      // force today - but only because the whole file happens to be one
      // transaction, and a DO block can be lifted out and run on its own. What is
      // pinned is that this block carries its own flag.
      final blockStart = sql.lastIndexOf(r'do $$', call);
      expect(blockStart, greaterThan(-1),
          reason: 'the live call is not inside a DO block');
      expect(sql.indexOf(r'end $$', call), greaterThan(call));

      final flag = sql.lastIndexOf(standIn, call);
      expect(flag, greaterThan(blockStart),
          reason: 'the live purge call deletes from storage.objects, so $standIn '
              'has to run inside the same DO block, ahead of it');

      // Nothing between the flag and the call may put the guard back: a RESET, a
      // DISCARD, or a second set_config turning it off again. Comments are dropped
      // first - they name the flag on purpose, and naming it is not a statement.
      final between =
          _withoutSqlComments(sql.substring(flag + standIn.length, call));
      expect(between, isNot(contains('reset')),
          reason: 'a reset between the flag and the live call clears it');
      expect(between, isNot(contains('discard')));
      expect(between, isNot(contains('allow_delete_query')));
      expect(between, isNot(contains('set_config')));

      // And it is the block's *first* statement: between the `begin` that opens
      // the block and the flag there is nothing but whitespace (the `declare`
      // section comes before `begin`, so it is out of scope here). The fixture
      // writes, the dry run and the live run are therefore all behind it - no
      // statement of this block can run without the flag, and one inserted ahead
      // of it later cannot silently reintroduce the 42501.
      final head = _withoutSqlComments(sql.substring(blockStart, flag));
      final open = head.lastIndexOf('begin');
      expect(open, greaterThan(-1), reason: 'the DO block has no begin');
      // Between `begin` and the flag there is one word: the `perform` that belongs
      // to the flag statement itself. Anything else is a statement that runs
      // without the flag - and a completed one always ends in `;`.
      final ahead = head.substring(open + 'begin'.length);
      expect(ahead, isNot(contains(';')),
          reason: 'a completed statement sits between `begin` and the storage flag, '
              'so it runs without it');
      expect(ahead.trim(), 'perform',
          reason: 'the storage flag has to be the first statement of the block that '
              'makes the live purge call');
    });

    test('the README says which purge route runs on a hosted project', () {
      final file = File('../README.md');
      if (!file.existsSync()) return;
      final readme = file.readAsStringSync().replaceAll('\r\n', '\n');

      final start = readme.indexOf('**And the photographs?**');
      expect(start, greaterThan(-1));
      final end = readme.indexOf('## Getting started', start);
      expect(end, greaterThan(start));
      final section = readme.substring(start, end);

      // The section is where an operator decides what to schedule, so the block
      // belongs here in as many words - not only in a migration header.
      expect(section, contains('storage.protect_delete()'));
      expect(section, contains('42501'));
      expect(section, contains('purge-snapshots'));
      expect(section, contains('on a hosted Supabase project it refuses'));
      // ...and the dry run, the one form that works everywhere.
      expect(section, contains('dry run'));
    });

    test('a project created from schema.sql and one upgraded agree', () {
      final sql = schemaSql();
      final migration =
          File('../supabase/migrations/20261106090000_proctoring_consents.sql');
      if (sql == null || !migration.existsSync()) return;
      final upgrade = migration.readAsStringSync();

      for (final name in <String>[
        'current_proctor_consent_version',
        'student_has_consent',
        'record_consent',
      ]) {
        expect(
          _functionBody(upgrade, name),
          _functionBody(sql, name),
          reason: '$name differs between schema.sql and the upgrade migration',
        );
      }

      // The policy this migration exists to change must be identical on both paths
      // too, or a fresh install and an upgraded project enforce different rules -
      // which is the one thing a consent gate must never do.
      expect(
        _policyWithCheck(upgrade, 'submissions_insert_own_ongoing'),
        _policyWithCheck(sql, 'submissions_insert_own_ongoing'),
        reason: 'the attempt policy disagrees between the two paths',
      );
      expect(
        _policyWithCheck(upgrade, 'consents_insert_own'),
        _policyWithCheck(sql, 'consents_insert_own'),
      );
      // The read policy was re-created by the scope migration (a supervisor reads the
      // acceptances of the papers assigned to them, and a general acceptance is their
      // subject's alone), so that is the file a fresh install has to agree with.
      final scope = File(
        '../supabase/migrations/20261109090000_supervisor_exam_assignments.sql',
      );
      if (scope.existsSync()) {
        expect(
          _policyUsing(
            scope.readAsStringSync(),
            'consents_select_own_or_supervisor',
          ),
          _policyUsing(sql, 'consents_select_own_or_supervisor'),
          reason: 'the scope migration and schema.sql disagree about the consent read',
        );
      }
    });

    test('the client sends the argument names the RPC declares', () async {
      transport.responseBody = '[{"consent_id":"c-1","consent_version":"'
          '${ProctorConsentConfig.version}","accepted_at":"2026-01-01T10:00:00Z",'
          '"is_current":true}]';
      final repo = ConsentRepositoryImpl(client);

      final record = await repo.recordConsent(
        examId: 'exam-1',
        version: ProctorConsentConfig.version,
      );

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/record_consent');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{'p_exam_id', 'p_version'});
      expect(body['p_exam_id'], 'exam-1');
      expect(body['p_version'], ProctorConsentConfig.version);

      expect(record.id, 'c-1');
      expect(record.version, ProctorConsentConfig.version);
      expect(record.isCurrentVersion, isTrue);
    });

    test('a general acceptance sends a null paper', () async {
      transport.responseBody = '[{"consent_id":"c-2","consent_version":"v",'
          '"accepted_at":null,"is_current":true}]';

      await ConsentRepositoryImpl(client).recordConsent(
        version: ProctorConsentConfig.version,
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.containsKey('p_exam_id'), isTrue);
      expect(body['p_exam_id'], isNull, reason: 'NULL is "every paper"');
    });

    test('no session means no consent, and no request', () async {
      final repo = ConsentRepositoryImpl(client);

      // The insert policy would refuse the attempt anyway; making the round trip
      // would only teach the gate a 401 it cannot act on.
      expect(await repo.hasCurrentConsent('exam-1'), isFalse);
      expect(transport.requests, isEmpty);
    });

    test('a reply that cannot be read does not block the student', () {
      // The gate is the one screen a student cannot get past: an older server
      // answering without `is_current` must not read as "your acceptance is
      // stale".
      expect(
        ConsentRecord.fromRpc(<String, dynamic>{
          'consent_id': 'c-3',
          'consent_version': 'v',
        }).isCurrentVersion,
        isTrue,
      );

      // ...but an explicit `false` does, which is the whole point of the field.
      expect(
        ConsentRecord.fromRpc(<String, dynamic>{'is_current': false})
            .isCurrentVersion,
        isFalse,
      );

      // A list-shaped answer (the PostgREST `returns table` shape) is unwrapped.
      expect(
        ConsentRecord.fromRpc(<dynamic>[
          <String, dynamic>{'consent_id': 'c-4', 'is_current': true},
        ]).id,
        'c-4',
      );
    });
  });

  // ---------------------------------------------------------------------
  // The supervisor scope (`20261109090000_supervisor_exam_assignments.sql`):
  // a supervisor reaches the papers an administrator assigned to them, an
  // administrator needs no row, and a lecturer keeps exactly what they had.
  // ---------------------------------------------------------------------
  group('supervisor scope', () {
    File? scopeMigration() {
      final file = File(
        '../supabase/migrations/20261109090000_supervisor_exam_assignments.sql',
      );
      return file.existsSync() ? file : null;
    }

    test('the migration exists, explains itself and is in both apply lists', () {
      final migration = scopeMigration();
      if (migration == null) {
        fail('the live project needs a file to run, not just a schema.sql edit');
      }
      final sql = migration.readAsStringSync().replaceAll('\r\n', '\n');

      for (final section in <String>[
        '-- WHY THIS FILE EXISTS',
        '-- WHAT CHANGES',
        '-- WHAT IT DOES NOT DO',
        '-- SAFETY',
        '-- APPLY ORDER',
        '-- 5. VERIFY',
      ]) {
        expect(sql, contains(section), reason: 'missing section: $section');
      }

      // Every policy it re-creates is dropped by name first, or re-running it on a
      // project that already has the policy is a 42710.
      expect(
        sql,
        contains(
          'drop policy if exists "submissions_delete_supervisor" '
          'on public.exam_submissions;',
        ),
      );

      for (final script in <String>[
        '../apply_in_order.ps1',
        '../apply_live_cli.ps1',
      ]) {
        final file = File(script);
        if (!file.existsSync()) continue;
        expect(
          file.readAsStringSync(),
          contains('20261109090000_supervisor_exam_assignments'),
          reason: '$script does not apply the scope migration',
        );
      }
    });

    test('the scope test file exists and names what it proves', () {
      final file = File('../supabase/tests/supervisor_scope_check.sql');
      if (!file.existsSync()) {
        fail('the scope has no RLS check of its own');
      }
      final sql = file.readAsStringSync().replaceAll('\r\n', '\n');
      expect(sql, contains('begin;'));
      expect(sql, contains('rollback;'));
      for (final marker in <String>[
        'PASS (a)ii',
        'PASS (c)',
        'PASS (e)',
        'PASS (f)',
        'PASS (g)',
        'PASS (i)iii',
        'PASS (j)',
        'PASS (k)',
        'PASS (k)vii',
        'PASS (k)ix',
      ]) {
        expect(sql, contains(marker), reason: 'the check stopped proving $marker');
      }
    });

    test('schema.sql carries the table, the predicates and the write policies', () {
      final sql = schemaSql();
      if (sql == null) return;

      expect(
        sql,
        contains(
          'create table if not exists public.supervisor_exam_assignments',
        ),
      );
      expect(sql, contains('primary key (exam_id, supervisor_id)'));
      expect(
        sql,
        contains('create or replace function public.can_supervise_exam('),
      );
      expect(
        sql,
        contains('create or replace function public.is_supervisor_only()'),
      );

      // An administrator answers true without a row; a supervisor only through the
      // table; a null paper answers false for everybody.
      final body = _functionBody(sql, 'can_supervise_exam');
      expect(body, isNotNull);
      expect(body, contains('p_exam_id is not null'));
      expect(body, contains("role = 'admin'"));
      expect(body, contains('public.supervisor_exam_assignments'));
      expect(body, contains("p.role = 'supervisor'"));

      // Only an administrator writes it, in their own name, and only for a
      // supervisor account (the guard).
      expect(
        _policyWithCheck(sql, 'supervisor_assignments_insert_admin'),
        'public.is_admin() and assigned_by = auth.uid()',
      );
      expect(
        _policyUsing(sql, 'supervisor_assignments_select_own_or_admin'),
        'supervisor_id = auth.uid() or public.is_admin()',
      );
      expect(
        _functionBody(sql, 'guard_supervisor_assignment'),
        contains("v_role <> 'supervisor'"),
      );
      // No update policy: the row is a fact, and re-aiming it is another assignment.
      expect(sql, isNot(contains('"supervisor_assignments_update')));
    });

    test('the roster read is narrowed for a supervisor, unchanged for staff', () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      // Own row first, then the staff tier with only the supervisor arm narrowed:
      // the question is asked of the *person* the row is, not of a paper.
      expect(
        _policyUsing(sql, 'profiles_select_own_or_staff'),
        'id = auth.uid() or ( public.is_staff() and '
        '(not public.is_supervisor_only() or public.can_read_profile(id)) )',
      );

      final body = _functionBody(sql, 'can_read_profile');
      expect(
        body,
        isNotNull,
        reason: 'the roster read asks a predicate that is not in the file',
      );
      // The three answers: an attempt on an assigned paper (the monitor's roster), a
      // borrow-list row on one, and the cohort a *labelled* paper names. Without the
      // last two a supervisor could not print a name before the first attempt.
      expect(body, contains('public.exam_submissions'));
      expect(body, contains('public.exam_allowed_students'));
      expect(body, contains('public.supervisor_exam_assignments'));
      // ...and a paper that names no cohort must not stand in for "everybody in the
      // institution", which is the hole this predicate exists to close.
      expect(body, contains("nullif(btrim(e.faculty), '') is not null"));
      expect(body, contains("p.role = 'student'"));
      // Never another member of staff: no screen a supervisor can reach prints a
      // colleague's name, and the author of a paper is a uuid the console ignores.
      expect(body, isNot(contains("'admin'")));
      expect(body, isNot(contains("'lecturer'")));

      // The same policy and the same function on an upgraded project: the migration
      // runs last there, so *it* is what a linked database ends up enforcing.
      final scope = File(
        '../supabase/migrations/20261109090000_supervisor_exam_assignments.sql',
      );
      if (!scope.existsSync()) return; // a checkout without ../supabase
      final scopeSql = scope.readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        _functionBody(scopeSql, 'can_read_profile'),
        body,
        reason: 'the scope migration and the full schema disagree about the roster read',
      );
      expect(
        _policyUsing(scopeSql, 'profiles_select_own_or_staff'),
        _policyUsing(sql, 'profiles_select_own_or_staff'),
        reason: 'the scope migration and the full schema disagree about the roster read',
      );
    });
  });

}

/// Reads `supabase/schema.sql`, which sits next to `mobile/` in the repository.
///
/// A checkout that only contains the app returns null and the test above passes
/// without pretending to have checked anything - the point of this half of the
/// contract is to catch drift while both halves are present.
String? schemaSql() {
  final file = File('../supabase/schema.sql');
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// Reads the role list out of the `role in (...)` predicate of
/// `create or replace function public.<name>()` in [sql], as [UserRole]s.
///
/// Null when the function is absent. Reading the sentence out of the definition
/// rather than asserting a copy of it is what makes the reset-tier tests check
/// what the policies actually enforce.
Set<UserRole>? _rolesNamedBy(String sql, String function) {
  final match = RegExp(
    'create or replace function public\\.$function\\(\\)'
    r'[\s\S]*?role in \(([^)]*)\)',
  ).firstMatch(sql);
  if (match == null) return null;
  return RegExp(r"'(\w+)'")
      .allMatches(match.group(1)!)
      .map((role) => UserRole.fromDb(role.group(1)!))
      .toSet();
}

/// The `using (...)` predicate of `create policy "<policy>"`, whitespace squashed
/// to single spaces so the comparison does not depend on layout.
///
/// Read out of the file rather than compared against a copy of the sentence: the
/// text in the file is what the server enforces. Null when [sql] does not declare
/// that policy.
String? _policyUsing(String sql, String policy) {
  final match = RegExp(
    'create policy "$policy"'
    r'[\s\S]*?for (?:select|delete|update)[\s\S]*?using \(([\s\S]*?)\);',
  ).firstMatch(sql.replaceAll('\r\n', '\n'));
  return match?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The `with check (...)` predicate of `create policy "<policy>"` on an INSERT
/// policy, whitespace squashed to single spaces so the comparison does not depend
/// on layout.
///
/// The twin of [_policyUsing] for the policies that only have a WITH CHECK clause
/// (an INSERT policy cannot have a USING clause). Read out of the file rather than
/// compared against a copy of the sentence: the text in the file is what the
/// server enforces. Null when [sql] does not declare that policy.
String? _policyWithCheck(String sql, String policy) {
  final match = RegExp(
    'create policy "$policy"'
    r'[\s\S]*?for insert[\s\S]*?with check \(([\s\S]*?)\);',
  ).firstMatch(sql.replaceAll('\r\n', '\n'));
  return match?.group(1)?.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Reads the upgrade migration a database created *before* the four question
/// shapes and `question_grades` needs
/// (`supabase/migrations/question_types_and_grading.sql`).
///
/// Null outside a full checkout, like [schemaSql], so the assertion reports
/// drift where both halves are present instead of failing on a lone app folder.
String? migrationSql() {
  final file = File('../supabase/migrations/question_types_and_grading.sql');
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// [sql] with its `--` line comments removed.
///
/// The ordering checks read *statements*, and the prose around them names the
/// guard and the flag on purpose; dropping the comments is what keeps a sentence
/// about a `set_config` from reading as one. This is a lexical approximation
/// (a `--` inside a string literal would be dropped too), which is why it is only
/// used to look for keywords, never to reproduce SQL.
String _withoutSqlComments(String sql) => sql.replaceAll(RegExp(r'--[^\n]*'), '');

/// Where the *live* purge call starts in a SQL test file: the statement that
/// calls `public.purge_expired_snapshots(...)` into `v_done`.
///
/// The argument list is deliberately not pinned. Section (g) hands over the
/// window it read from `public.retention_policies` (so the fixture and the purge
/// agree when an operator keeps something other than 30 days), and a test that
/// spelled the call out would go on passing while pinning the wrong thing -
/// what matters is that the call is there and where it sits.
///
/// -1 when the file has no such statement.
int _livePurgeCallIndex(String sql) =>
    RegExp(
      r'select public\.purge_expired_snapshots\((?:[^()]|\([^()]*\))*\) into v_done',
    ).firstMatch(sql.replaceAll('\r\n', '\n'))?.start ??
    -1;
/// `create` keyword through the closing `$$;`, with `--` comments stripped and
/// every line trimmed.
///
/// Comments are dropped on purpose. `schema.sql` and an upgrade migration explain
/// the same function to different readers and may word it differently; what must
/// not differ is the SQL that runs, and this is the shape to compare on. Null when
/// [sql] does not declare that function.
String? _functionBody(String sql, String name) {
  final normalised = sql.replaceAll('\r\n', '\n');
  final start = normalised.indexOf('create or replace function public.$name(');
  if (start < 0) return null;
  final end = normalised.indexOf(r'$$;', start);
  if (end < 0) return null;
  return normalised
      .substring(start, end)
      .split('\n')
      .map((line) => line.replaceFirst(RegExp(r'--.*$'), '').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}
