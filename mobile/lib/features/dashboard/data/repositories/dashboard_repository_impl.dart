import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/analytics_report.dart';
import '../../domain/entities/submission_reset_result.dart';
import '../../domain/repositories/dashboard_repository.dart';

class DashboardRepositoryImpl implements DashboardRepository {
  DashboardRepositoryImpl(this._client);

  static const snapshotBucket = 'proctor-snapshots';
  static const analyticsWindow = Duration(days: 30);
  static const pageSize = 500;

  final SupabaseClient _client;

  @override
  Future<AnalyticsReport> getAnalytics() async {
    final since = DateTime.now().toUtc().subtract(analyticsWindow).toIso8601String();
    try {
      final results = await Future.wait([
        _readAll((from, to) async => (await _client
                .from('exams')
                .select('id, title')
                .order('id')
                .range(from, to))
            .cast<Map<String, dynamic>>()),
        _readAll((from, to) async => (await _client
                .from('exam_submissions')
                .select('id, exam_id, status, score')
                .order('id')
                .range(from, to))
            .cast<Map<String, dynamic>>()),
        _readAll((from, to) async => (await _client
                .from('proctoring_logs')
                .select('submission_id')
                .gte('timestamp', since)
                .order('id')
                .range(from, to))
            .cast<Map<String, dynamic>>()),
      ]);

      final exams = results[0];
      final submissions = results[1];
      final logs = results[2];
      final examBySubmission = <String, String>{
        for (final row in submissions)
          row['id'] as String: row['exam_id'] as String,
      };
      final incidentsByExam = <String, int>{};
      for (final log in logs) {
        final examId = examBySubmission[log['submission_id']];
        if (examId != null) {
          incidentsByExam.update(examId, (count) => count + 1, ifAbsent: () => 1);
        }
      }

      final rollups = exams.map((exam) {
        final id = exam['id'] as String;
        final attempts = submissions.where((row) => row['exam_id'] == id);
        var ongoing = 0;
        var completed = 0;
        var disqualified = 0;
        var scoredCount = 0;
        var scoreTotal = 0.0;
        for (final attempt in attempts) {
          switch (attempt['status']) {
            case 'ongoing':
              ongoing++;
            case 'submitted':
              completed++;
            case 'disqualified':
              disqualified++;
          }
          final score = attempt['score'];
          if (score is num) {
            scoredCount++;
            scoreTotal += score.toDouble();
          }
        }
        return ExamAnalytics(
          examId: id,
          title: exam['title'] as String,
          attempts: ongoing + completed + disqualified,
          ongoing: ongoing,
          completed: completed,
          disqualified: disqualified,
          incidents: incidentsByExam[id] ?? 0,
          averageScore: scoredCount == 0 ? null : scoreTotal / scoredCount,
          scoredAttempts: scoredCount,
        );
      }).toList()
        ..sort((a, b) {
          final incidents = b.incidents.compareTo(a.incidents);
          return incidents != 0
              ? incidents
              : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });

      return AnalyticsReport(rollups);
    } on PostgrestException catch (error) {
      throw DashboardException('Could not load analytics: ${error.message}');
    } catch (error) {
      throw DashboardException('Could not load analytics: $error');
    }
  }

  @override
  Future<SubmissionResetResult> resetSubmission(String submissionId) async {
    final List<Map<String, dynamic>> logs;
    try {
      logs = await _readAll((from, to) async => (await _client
              .from('proctoring_logs')
              .select('snapshot_url')
              .eq('submission_id', submissionId)
              .order('id')
              .range(from, to))
          .cast<Map<String, dynamic>>());
    } on PostgrestException catch (error) {
      throw DashboardException('Could not read attempt evidence: ${error.message}');
    } catch (error) {
      throw DashboardException('Could not read attempt evidence: $error');
    }

    final paths = logs
        .map((row) => row['snapshot_url'])
        .whereType<String>()
        .map(_snapshotPath)
        .whereType<String>()
        .toSet()
        .toList();

    final List<dynamic> deleted;
    try {
      deleted = await _client
          .from('exam_submissions')
          .delete()
          .eq('id', submissionId)
          .select('id');
    } on PostgrestException catch (error) {
      throw DashboardException('Could not reset the attempt: ${error.message}');
    } catch (error) {
      throw DashboardException('Could not reset the attempt: $error');
    }
    if (deleted.isEmpty) {
      throw const DashboardException(
        'The server deleted nothing. The attempt may already be cleared, or '
        'your account may not be allowed to reset it.',
      );
    }

    if (paths.isEmpty) {
      return SubmissionResetResult(incidents: logs.length, snapshots: 0);
    }

    try {
      final removed =
          await _client.storage.from(snapshotBucket).remove(paths);
      return SubmissionResetResult(
        incidents: logs.length,
        snapshots: removed.length,
      );
    } on StorageException catch (error) {
      return SubmissionResetResult(
        incidents: logs.length,
        snapshots: 0,
        storageWarning:
            '${paths.length} snapshot image(s) could not be removed: ${error.message}',
      );
    } catch (error) {
      return SubmissionResetResult(
        incidents: logs.length,
        snapshots: 0,
        storageWarning:
            '${paths.length} snapshot image(s) could not be removed: $error',
      );
    }
  }

  Future<List<Map<String, dynamic>>> _readAll(
    Future<List<Map<String, dynamic>>> Function(int from, int to) readPage,
  ) async {
    final rows = <Map<String, dynamic>>[];
    while (true) {
      final page = await readPage(rows.length, rows.length + pageSize - 1);
      rows.addAll(page);
      if (page.length < pageSize) return rows;
    }
  }

  static String? _snapshotPath(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final segments = uri.pathSegments;
    final bucketIndex = segments.indexOf(snapshotBucket);
    if (bucketIndex < 0 || bucketIndex == segments.length - 1) return null;
    return segments.skip(bucketIndex + 1).join('/');
  }
}
