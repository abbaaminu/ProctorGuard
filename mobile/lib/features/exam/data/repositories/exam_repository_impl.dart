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
    try {
      await _client.rpc('merge_submission_answer', params: {
        'p_submission_id': submissionId,
        'p_question_id': questionId,
        'p_selected_option': selectedOption,
      });
    } on PostgrestException catch (error) {
      if (error.code == '55000') throw const AnswerWriteRejected();
      rethrow;
    }
  }

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {
    // Same merge semantics for free text: the server stores it as a JSON string
    // under the question id and `submit_exam` compares it case-insensitively
    // after trimming, so "  http " scores for "HTTP".
    try {
      await _client.rpc('merge_submission_text_answer', params: {
        'p_submission_id': submissionId,
        'p_question_id': questionId,
        'p_answer': answer,
      });
    } on PostgrestException catch (error) {
      if (error.code == '55000') throw const AnswerWriteRejected();
      rethrow;
    }
  }

  @override
  Future<void> submitExam(String submissionId) async {
    // Server-side grading: `submit_exam` computes `score` from the stored
    // answers (sum of `questions.points` for correct ones) and flips the status
    // in one transaction. It is the *only* way to close an attempt now that
    // there is no student UPDATE policy on exam_submissions — a patched client
    // cannot write its own score. Idempotent, so a retry is safe.
    await _client.rpc('submit_exam', params: {
      'p_submission_id': submissionId,
    });
  }

  @override
  Future<void> markDisqualified(String submissionId) async {
    // Normally a side effect of register_violation(); kept as the client-side
    // redundancy path (offline queue flush after reconnect, or a strike whose
    // log row never reached the server). `p_disqualified` never grades, and the
    // RPC is idempotent for an attempt that is already closed.
    await _client.rpc('submit_exam', params: {
      'p_submission_id': submissionId,
      'p_disqualified': true,
    });
  }
}
