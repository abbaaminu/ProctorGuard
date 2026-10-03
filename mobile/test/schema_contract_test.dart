import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:exam_proctor/core/services/supabase_service.dart';
import 'package:exam_proctor/features/admin/data/repositories/admin_user_repository_impl.dart';
import 'package:exam_proctor/features/admin/domain/entities/managed_account.dart';
import 'package:exam_proctor/features/admin/domain/repositories/admin_user_repository.dart';
import 'package:exam_proctor/features/admin/presentation/providers/admin_providers.dart';
import 'package:exam_proctor/features/auth/domain/entities/user_profile.dart';
import 'package:exam_proctor/features/exam/data/repositories/exam_repository_impl.dart';
import 'package:exam_proctor/features/exam/domain/entities/question.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/exam/domain/repositories/exam_repository.dart';
import 'package:exam_proctor/features/proctoring/data/repositories/proctoring_repository_impl.dart';
import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
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

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(request is http.Request ? utf8.decode(request.bodyBytes) : '');
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
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
          snapshotUrl:
              'https://mock.supabase.co/storage/v1/object/public/'
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

      expect(sql, contains('clock_timestamp() < s.started_at'));
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

      await repo.submitExam('sub-1');

      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/rest/v1/rpc/submit_exam');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{'p_submission_id'});
      expect(body['p_submission_id'], 'sub-1');
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

    test('deleteAccount invokes the server-side account deletion function',
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
    });
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
        'fill_in_the_blank',
      ]);
      expect(
        QuestionType.fromDb('fill_in_the_blank'),
        QuestionType.fillInTheBlank,
      );
      expect(
        QuestionType.fromDb('multiple_choice'),
        QuestionType.multipleChoice,
      );
    });

    test('an unknown or missing type falls back instead of throwing', () {
      // A row must not be able to take the whole exam screen down through the
      // question feed.
      expect(QuestionType.fromDb('essay'), QuestionType.multipleChoice);
      expect(QuestionType.fromDb(null), QuestionType.multipleChoice);
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
