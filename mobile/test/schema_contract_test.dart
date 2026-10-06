import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:proctorguard/core/services/supabase_service.dart';
import 'package:proctorguard/features/admin/data/repositories/admin_user_repository_impl.dart';
import 'package:proctorguard/features/admin/domain/entities/managed_account.dart';
import 'package:proctorguard/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:proctorguard/features/admin/presentation/providers/admin_providers.dart';
import 'package:proctorguard/features/auth/domain/entities/user_profile.dart';
import 'package:proctorguard/features/authoring/data/repositories/question_authoring_repository_impl.dart';
import 'package:proctorguard/features/authoring/domain/entities/authored_question.dart';
import 'package:proctorguard/features/authoring/domain/repositories/question_authoring_repository.dart';
import 'package:proctorguard/features/exam/data/repositories/exam_repository_impl.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/proctoring/data/repositories/proctoring_repository_impl.dart';
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
    test('sends exactly the schema argument names and maps the result',
        () async {
      transport.responseBody = '[{"warning_count": 2, "disqualified": false}]';
      final repo = ProctoringRepositoryImpl(client);

      final result = await repo.logViolation(
        submissionId: 'sub-1',
        violation: Violation(
          type: ViolationType.lookingAway,
          timestamp: DateTime.utc(2026, 1, 1, 10, 30),
          snapshotUrl: 'https://mock.supabase.co/storage/v1/object/public/'
              'proctor-snapshots/sub-1/looking_away_1.jpg',
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
      expect(body['p_snapshot_url'], contains('/proctor-snapshots/sub-1/'));
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
        contains('public.attempt_deadline(v_started_at, v_duration_minutes, v_ends_at)'),
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

    test('a final score is only claimed once the paper says it is final',
        () async {
      transport.responseBody =
          '[{"result_status":"submitted","final_score":7}]';
      final repo = ExamRepositoryImpl(client);

      final objective = (await repo.submitExam('sub-1'))
          .withPaper(awaitingMarking: false, maxScore: 10);
      expect(objective.hasFinalScore, isTrue);
      // "7 of 10", not "7.0 of 10": a whole-number mark is the common case and
      // the decimal reads like a bug.
      expect(objective.scoreLabel, '7 of 10');

      // The same server row on a paper with an essay on it stays provisional —
      // the number is only the automatic half until a lecturer marks the rest.
      final withEssay = (await repo.submitExam('sub-1'))
          .withPaper(awaitingMarking: true, maxScore: 10);
      expect(withEssay.hasFinalScore, isFalse);
      expect(withEssay.score, 7);
    });

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

    test('createAccount posts the trimmed payload to the Edge Function',
        () async {
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
  });

  group('role contract', () {
    test('the client and the Edge Function agree on the roles and the floor',
        () {
      // Supabase Auth's default minimum: a shorter password would be accepted
      // by the form and refused after the administrator had already typed it.
      expect(adminMinPasswordLength, AdminUserRepositoryImpl.minPasswordLength);
      expect(adminMinPasswordLength, greaterThanOrEqualTo(6));

      final file = File('../supabase/functions/admin-create-user/index.ts');
      if (!file.existsSync()) return; // a checkout without ../supabase

      final source = file.readAsStringSync();
      // Same four roles, same order, on both sides of the wire.
      final expected =
          UserRole.values.map((role) => '"${role.dbValue}"').join(', ');
      expect(source, contains('const ROLES = [$expected]'));
      // `{ error }` is what `_messageFromFunctionError` reads out of a 4xx.
      expect(source, contains('return json({ error: message }, status);'));
      expect(
        source,
        contains('const MIN_PASSWORD_LENGTH = $adminMinPasswordLength;'),
      );
      // Who may create accounts, and the four keys the 200 answers with — the
      // body `ManagedAccount.fromMap` reads back.
      expect(
        source,
        contains('const CREATOR_ROLES: readonly Role[] = ["admin"];'),
      );
      expect(
        source,
        contains(
          'return json({ id: created.user.id, email, full_name: fullName, role });',
        ),
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
    test('the console and is_attempt_resetter() allow exactly the same roles',
        () {
      // `UserRole.canResetAttempts` is what `role_gate.dart` hands the supervisor
      // dashboard as `canResetAttempts` (and what the lecture console and the
      // admin dashboard ask in their own way); the server grants the three halves
      // of the same action - the DELETE, the snapshot purge and the audit row -
      // through `is_attempt_resetter()`. Drift in either direction is something
      // the user sees: a reset control the server refuses, or an action the
      // server would allow that is never offered.
      final clientRoles =
          UserRole.values.where((role) => role.canResetAttempts).toSet();
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
      expect(
        _rolesNamedBy(sql, 'is_exam_supervisor'),
        <UserRole>{UserRole.admin, UserRole.supervisor},
      );

      // Every policy the console's reset rides on asks the *reset* predicate: the
      // DELETE that removes the attempt, the Storage purge of its snapshots, and
      // the audit row.
      expect(sql, contains('using (public.is_attempt_resetter());'));
      expect(sql, contains('and public.is_attempt_resetter()'));
      expect(
        sql,
        contains(
          'with check (public.is_attempt_resetter() and actor_id = auth.uid())',
        ),
      );

      // ...while the update policy is the one that keeps the narrower tier.
      // (Normalised to `\n`: the file is checked out with the platform's line
      // endings.)
      expect(
        sql.replaceAll('\r\n', '\n'),
        contains('using (public.is_exam_supervisor())\n'
            '  with check (public.is_exam_supervisor());'),
      );

      // Exactly four mentions: the definition plus those three policies. A fifth
      // would be a policy somebody left on the old predicate (or a new caller
      // that should be checked rather than copied).
      expect(
        RegExp(r'public\.is_attempt_resetter\(\)').allMatches(sql).length,
        4,
        reason: 'the function definition and its three policies',
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
      final expected =
          UserRole.values.where((role) => role.canResetAttempts).toSet();

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
    const ownerIsAuthor = 'select exists ( select 1 from public.exams '
        'where id = p_exam_id and created_by = auth.uid() );';

    test('the incident feed asks the owner as well as the intervention tier',
        () {
      final sql = schemaSql();
      if (sql == null) return; // a checkout without ../supabase

      final predicate = predicateOf(sql, 'logs_select_own_or_supervisor');
      expect(predicate, isNotNull, reason: 'the policy left schema.sql');
      // The student's own rows, the paper's author, the intervention tier.
      expect(predicate, contains('s.student_id = auth.uid()'));
      expect(predicate, contains('public.owns_exam(s.exam_id)'));
      expect(predicate, contains('public.is_exam_supervisor()'));
      // The staff tier is exactly what this policy dropped, and dropping it is
      // what stops one lecturer reading the incidents gathered on another
      // teacher's paper. (`is_exam_supervisor()` does not contain `is_staff`, so
      // this really is the staff arm.)
      expect(predicate, isNot(contains('is_staff')));
    });

    test('the reset audit asks the same question of the same evidence', () {
      final schema = schemaSql();
      if (schema == null) return;

      final predicate = predicateOf(schema, 'session_reset_logs_select_staff');
      expect(
        predicate,
        'public.is_exam_supervisor() or public.owns_exam(exam_id)',
        reason: 'the reset row carries its exam id as plain evidence, so this '
            'policy can ask owns_exam() directly instead of hopping through '
            'the attempt the way the incident feed does',
      );

      // The file that introduced the table carries the identical sentence.
      final introduced = File('../supabase/migrations/session_reset_logs.sql');
      if (introduced.existsSync()) {
        final sql = introduced.readAsStringSync().replaceAll('\r\n', '\n');
        expect(predicateOf(sql, 'session_reset_logs_select_staff'), predicate);
        expect(functionBody(sql, r'owns_exam\(p_exam_id uuid\)'), ownerIsAuthor);
      }

      // The upgrade file assembles the policy inside an `execute`, so what has to
      // hold there is that the literal it concatenates contains this exact
      // predicate - the same sentence, not a paraphrase of it.
      final upgrade =
          File('../supabase/migrations/lecturer_scoped_log_reads.sql');
      if (upgrade.existsSync()) {
        final sql = upgrade.readAsStringSync().replaceAll('\r\n', '\n');
        expect(sql, contains(predicate!));
      }

      // Writes are a different question and are untouched: who may *clear* an
      // attempt is still `is_attempt_resetter()`, whoever may read the row it
      // leaves behind.
      expect(
        schema,
        contains(
          'with check (public.is_attempt_resetter() and actor_id = auth.uid())',
        ),
      );
    });

    test('the roster stays staff-wide: only the evidence was narrowed', () {
      final sql = schemaSql();
      if (sql == null) return;

      // A lecturer may watch any sitting - "WHAT IT DOES NOT CHANGE" in
      // lecturer_scoped_log_reads.sql - so the attempts keep the wide read. If
      // this ever gains the ownership arm, a monitor opened on another teacher's
      // paper would show an empty roster instead of the students in the room.
      expect(
        predicateOf(sql, 'submissions_select_own_or_supervisor'),
        'student_id = auth.uid() or public.is_staff()',
      );
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
          contains('language sql\n'
              'security definer\n'
              'stable\n'
              'set search_path = public\n'),
          reason: '$path\'s owns_exam() is not the pinned SECURITY DEFINER form',
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

      // Both copies of the incident-feed policy agree, so re-running this file
      // cannot land a different tier than a fresh schema.sql install gets.
      final schema = schemaSql();
      if (schema != null) {
        expect(
          predicateOf(sql, 'logs_select_own_or_supervisor'),
          predicateOf(schema, 'logs_select_own_or_supervisor'),
          reason: 'the upgrade path and the full schema disagree',
        );
      }

      // The reset policy is created inside a table check: a project that has not
      // applied session_reset_logs.sql has no table to put it on, and an
      // unguarded `create policy` would stop the whole migration at 42P01.
      expect(sql, contains("to_regclass('public.session_reset_logs')"));
      expect(
        RegExp('^create policy "([^"]+)"', multiLine: true)
            .allMatches(sql)
            .map((match) => match.group(1))
            .toList(),
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

    test('posts the account id and the password to the Edge Function',
        () async {
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
      expect(source, contains('return json({ error: message }, status);'));

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
        sql,
        contains(
          'with check (public.is_attempt_resetter() and actor_id = auth.uid())',
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
        final url = await SupabaseService.instance.uploadViolationSnapshot(
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

        // The URL stored on the log row comes from getPublicUrl().
        expect(url, isNotNull);
        expect(
          url,
          contains(
            '/storage/v1/object/public/proctor-snapshots/sub-1/no_face_',
          ),
        );
        expect(url, endsWith('.jpg'));

        final stamp = int.parse(
          RegExp(r'no_face_(\d+)\.jpg').firstMatch(url!)!.group(1)!,
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

    test('a new paper is created owned by the caller, and nothing else',
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
      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
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
    });

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

    test('a true/false question is sent as a word, with no option index',
        () async {
      transport.responseBody = jsonEncode(<String, dynamic>{
        'id': 'q-7',
        'exam_id': 'exam-9',
        'question_text': 'A pull request may be merged before its checks pass.',
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
          questionText: 'A pull request may be merged before its checks pass.',
          correctTextAnswer: 'False',
        ),
      );

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      // The shape `questions_answer_key_shape` accepts for 'true_false': the key
      // is the word, lowercased, and there is no option index at all.
      expect(body['question_type'], 'true_false');
      expect(body['correct_text_answer'], 'false');
      expect(body['correct_option'], isNull);
      expect(body['options'], isEmpty);
      expect(body['exam_id'], 'exam-9');
      expect(question.answerSummary, 'False');
    });

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

    test('a signed-out console refuses instead of writing a stray row',
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
    });

    test('a PostgREST refusal becomes a sentence a lecturer can act on',
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
            questionText: 'Explain the difference between a stack and a queue.',
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
    });

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

    test('the upgrade migration carries the same DDL and the new submit_exam',
        () {
      final migration = migrationSql();
      if (migration == null) return;

      expect(
        migration,
        contains(
          'drop constraint if exists questions_question_type_check',
        ),
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
    test('the log table, the RPC and the dedupe index agree with the client',
        () {
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
      expect(sql, contains('and (e.starts_at is null or now() >= e.starts_at)'));
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
          'message': "Could not find the 'starts_at' column of 'exams' in the "
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
