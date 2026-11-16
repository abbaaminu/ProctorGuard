import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/supabase_service.dart';
import '../../../../core/utils/read_timeout.dart';
import '../../domain/entities/exam.dart';
import '../../domain/entities/exam_submit_result.dart';
import '../../domain/entities/question.dart';
import '../../domain/entities/submission.dart';
import '../../domain/repositories/exam_repository.dart';

class ExamRepositoryImpl implements ExamRepository {
  ExamRepositoryImpl(this._client, {this.readTimeout = defaultReadTimeout});

  final SupabaseClient _client;

  /// The deadline on [getPublishedExams] and [getQuestions] - the two reads a
  /// page waits on with nothing else it can show. See
  /// `core/utils/read_timeout.dart`.
  ///
  /// Everything else here writes: `startOrResumeSubmission` inserts an attempt,
  /// the answer RPCs and `submit_exam` write to one. Those are not abandoned on
  /// a deadline, because after a timeout the client cannot tell "the server
  /// refused" from "the server applied it and the answer was lost", and
  /// re-sending `submit_exam` on that guess would hand in twice.
  final Duration readTimeout;

  @override
  Future<List<Exam>> getPublishedExams() async {
    final rows = await withReadTimeout<PostgrestList>(
      () => _client
          .from('exams')
          .select()
          .eq('is_published', true)
          .order('created_at', ascending: false),
      timeout: readTimeout,
    );
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(Exam.fromMap)
        .toList();
  }

  @override
  Future<List<Question>> getQuestions(String examId) async {
    // Uses the safe view — correct_option never reaches the device.
    final rows = await withReadTimeout<PostgrestList>(
      () => _client.from('questions_public').select().eq('exam_id', examId),
      timeout: readTimeout,
    );
    return (rows as List)
        .cast<Map<String, dynamic>>()
        .map(Question.fromMap)
        .toList();
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
      throw _mapAnswerWriteError(error);
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
      throw _mapAnswerWriteError(error);
    }
  }

  @override
  Future<ExamSubmitResult> submitExam(String submissionId) async {
    // Server-side grading: `submit_exam` computes `score` from the stored
    // answers (sum of `questions.points` for correct ones) and flips the status
    // in one transaction. It is the *only* way to close an attempt now that
    // there is no student UPDATE policy on exam_submissions — a patched client
    // cannot write its own score. Idempotent, so a retry is safe.
    //
    // It answers with `(result_status, final_score)`, which is the mark the
    // student is shown straight away when the paper has no essay on it.
    try {
      final response = await _client.rpc('submit_exam', params: {
        'p_submission_id': submissionId,
      });
      return ExamSubmitResult.fromRpc(response);
    } on PostgrestException catch (error) {
      // The one write a superseded device must not mistake for a network
      // failure: handing in is not retried by the queue, so it is reported as
      // what it is.
      if (error.code == 'PT409') throw const SessionSupersededException();
      rethrow;
    }
  }

  @override
  Future<void> markDisqualified(String submissionId) async {
    // Normally a side effect of register_violation(); kept as the client-side
    // redundancy path (offline queue flush after reconnect, or a strike whose
    // log row never reached the server). `p_disqualified` never grades, and the
    // RPC is idempotent for an attempt that is already closed.
    try {
      await _client.rpc('submit_exam', params: {
        'p_submission_id': submissionId,
        'p_disqualified': true,
      });
    } on PostgrestException catch (error) {
      if (error.code == 'PT409') throw const SessionSupersededException();
      rethrow;
    }
  }

  /// Turns the two codes the write RPCs use to refuse an answer into the errors
  /// the UI already understands, and hands anything else back untouched.
  ///
  /// `55000` is "this attempt is closed" ([AnswerWriteRejected]) and `PT409` is
  /// "another device signed in" ([SessionSupersededException], schema.sql §1b) —
  /// the queue treats the first as a permanent rejection and the second as a
  /// sign-out, so the two must not collapse into one another.
  Exception _mapAnswerWriteError(PostgrestException error) {
    if (error.code == '55000') return const AnswerWriteRejected();
    if (error.code == 'PT409') return const SessionSupersededException();
    return error;
  }
}
