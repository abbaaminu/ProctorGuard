import 'package:supabase_flutter/supabase_flutter.dart';

import '../../domain/entities/exam.dart';
import '../../domain/entities/question.dart';
import '../../domain/entities/submission.dart';
import '../../domain/repositories/exam_repository.dart';

class ExamRepositoryImpl implements ExamRepository {
  final SupabaseClient _client;
  ExamRepositoryImpl(this._client);

  @override
  Future<List<Exam>> getPublishedExams() async {
    final rows = await _client
        .from('exams')
        .select()
        .eq('is_published', true)
        .order('created_at', ascending: false);
    return (rows as List).map((r) => Exam.fromMap(r)).toList();
  }

  @override
  Future<List<Question>> getQuestions(String examId) async {
    // Uses the safe view — correct_option never reaches the device.
    final rows = await _client
        .from('questions_public')
        .select()
        .eq('exam_id', examId);
    return (rows as List).map((r) => Question.fromMap(r)).toList();
  }

  @override
  Future<Submission> startOrResumeSubmission(String examId) async {
    final studentId = _client.auth.currentUser!.id;

    final existing = await _client
        .from('exam_submissions')
        .select()
        .eq('exam_id', examId)
        .eq('student_id', studentId)
        .maybeSingle();

    if (existing != null) return Submission.fromMap(existing);

    final inserted = await _client
        .from('exam_submissions')
        .insert({'exam_id': examId, 'student_id': studentId, 'status': 'ongoing'})
        .select()
        .single();
    return Submission.fromMap(inserted);
  }

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {
    // jsonb_set merges the single answer without clobbering others written
    // concurrently (e.g. answer autosave firing while user moves on).
    await _client.rpc('merge_submission_answer', params: {
      'p_submission_id': submissionId,
      'p_question_id': questionId,
      'p_selected_option': selectedOption,
    });
  }

  @override
  Future<void> submitExam(String submissionId) async {
    await _client
        .from('exam_submissions')
        .update({'status': 'submitted', 'submitted_at': DateTime.now().toIso8601String()})
        .eq('id', submissionId)
        .eq('status', 'ongoing'); // no-op if already disqualified
  }

  @override
  Future<void> markDisqualified(String submissionId) async {
    // Normally a side effect of register_violation(); exposed here for
    // client-side redundancy (e.g. offline queue flush after reconnect).
    await _client
        .from('exam_submissions')
        .update({'status': 'disqualified', 'submitted_at': DateTime.now().toIso8601String()})
        .eq('id', submissionId)
        .eq('status', 'ongoing');
  }
}
