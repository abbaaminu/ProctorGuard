import 'dart:convert';
import 'dart:typed_data';

import 'package:exam_proctor/core/services/supabase_service.dart';
import 'package:exam_proctor/features/exam/data/repositories/exam_repository_impl.dart';
import 'package:exam_proctor/features/exam/domain/entities/submission.dart';
import 'package:exam_proctor/features/proctoring/data/repositories/proctoring_repository_impl.dart';
import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the client ↔ database contract from `supabase/schema.sql` so the Flutter
/// side cannot drift from the unified production schema:
///  * `register_violation` argument names/values and its returned
///    `warning_count` / `disqualified` fields;
///  * the five `action_type` strings the check constraint allows;
///  * the `proctor-snapshots` upload path convention and JPEG content type.
class _RecordingTransport extends http.BaseClient {
  final List<http.BaseRequest> requests = <http.BaseRequest>[];
  final List<String> bodies = <String>[];
  String responseBody = '[]';

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    bodies.add(request is http.Request ? utf8.decode(request.bodyBytes) : '');
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(responseBody)),
      200,
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
          timestamp: DateTime.utc(2026, 1, 1),
          snapshotUrl: 'https://mock.supabase.co/storage/v1/object/public/'
              'proctor-snapshots/sub-1/looking_away_1.jpg',
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
      });
      expect(body['p_submission_id'], 'sub-1');
      expect(body['p_action_type'], 'looking_away');
      expect(body['p_snapshot_url'], contains('/proctor-snapshots/sub-1/'));

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
        ],
      );
    });
  });

  group('submit_exam RPC payload', () {
    test('submitExam asks the server to grade and close the attempt',
        () async {
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

    test('markDisqualified flags the close so the server never grades',
        () async {
      transport.responseBody =
          '[{"result_status":"disqualified","final_score":null}]';
      final repo = ExamRepositoryImpl(client);

      await repo.markDisqualified('sub-1');

      expect(transport.requests.single.url.path, '/rest/v1/rpc/submit_exam');

      final body = jsonDecode(transport.bodies.single) as Map<String, dynamic>;
      expect(body.keys.toSet(), <String>{'p_submission_id', 'p_disqualified'});
      expect(body['p_disqualified'], isTrue);
    });

    test('closing an attempt never PATCHes exam_submissions directly',
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
    test('POSTs JPEG bytes to <submission_id>/<action_type>_<epoch-ms>.jpg',
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
        contains('/storage/v1/object/public/proctor-snapshots/sub-1/no_face_'),
      );
      expect(url, endsWith('.jpg'));

      final stamp = int.parse(
        RegExp(r'no_face_(\d+)\.jpg').firstMatch(url!)!.group(1)!,
      );
      expect(stamp, inInclusiveRange(before, after));
    });

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
}
