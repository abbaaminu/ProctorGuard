import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../exam/domain/entities/exam.dart';
import '../../../exam/domain/entities/submission.dart';
import '../../domain/entities/attempt_grading.dart';
import '../../domain/entities/authored_exam.dart';
import '../../domain/entities/authored_question.dart';
import '../../domain/repositories/question_authoring_repository.dart';

/// `public.questions` as its owner reads it. [questionColumns] carries the two
/// answer keys on purpose — this is the one client surface they belong on, and
/// the reason the console reads the table rather than `questions_public`.
class QuestionAuthoringRepositoryImpl implements QuestionAuthoringRepository {
  QuestionAuthoringRepositoryImpl(
    this._client, {
    this.currentUserId,
  });

  final SupabaseClient _client;

  /// Injectable for tests, the same seam `RoleGate.currentUserId` uses: the
  /// default (null) reads the SDK's session, and nothing else in this class knows
  /// where the id came from.
  final String? Function()? currentUserId;

  static const questionColumns =
      'id, exam_id, question_text, question_type, options, '
      'correct_option, correct_text_answer, points, created_at';

  /// The signed-in account whose papers these are. Read per call rather than
  /// cached, so a console left open across a sign-out cannot write as the
  /// previous user.
  String get _userId {
    final id = currentUserId?.call() ?? _client.auth.currentUser?.id;
    if (id == null) {
      throw const AuthoringException(
        'You are signed out. Sign in again to open the authoring console.',
      );
    }
    return id;
  }

  @override
  Future<List<AuthoredExam>> listMyExams() async {
    final rows = await _guard(() async {
      final data = await _client
          .from('exams')
          .select(
            'id, title, created_by, duration_minutes, is_published, '
            'created_at, questions(count), exam_submissions(count)',
          )
          // The *mine* filter, and the same condition the write policies ask:
          // `exams_select` would otherwise hand every member of staff every
          // paper in the institution, which is not what this console is.
          .eq('created_by', _userId)
          .order('created_at', ascending: false);
      return (data as List).cast<Map<String, dynamic>>();
    });

    try {
      return rows.map(AuthoredExam.fromMap).toList();
    } catch (_) {
      throw const AuthoringException(
        'One of your papers could not be read. Refresh the console and try '
        'again, and update the app if it keeps happening.',
      );
    }
  }

  @override
  Future<AuthoredExam> createExam({
    required String title,
    required int durationMinutes,
    required bool isPublished,
  }) async {
    final row = await _guard(() async {
      final data = await _client
          .from('exams')
          .insert(<String, dynamic>{
            'title': title.trim(),
            // `exams_insert_supervisor_only` requires this to be the caller's
            // own id *and* a staff role, so it is sent as the session's id rather
            // than anything the caller typed.
            'created_by': _userId,
            'duration_minutes': durationMinutes,
            'is_published': isPublished,
          })
          .select('id, title, created_by, duration_minutes, is_published')
          .single();
      return data;
    });

    try {
      // A paper that has just been created has no questions and no attempts by
      // definition, so the two counts are known here rather than fetched.
      return AuthoredExam(
        exam: Exam.fromMap(row),
        questionCount: 0,
        attemptCount: 0,
      );
    } catch (_) {
      throw const AuthoringException(
        'The paper was created, but the server response could not be read. '
        'Refresh the console to find it.',
      );
    }
  }

  @override
  Future<void> setPublished({
    required String examId,
    required bool isPublished,
  }) async {
    await _guard(() async {
      // `.select('id')` turns "no row matched" (somebody else's paper, or one
      // that has been deleted) into an empty list this can report, instead of a
      // silent success.
      final data = await _client
          .from('exams')
          .update(<String, dynamic>{'is_published': isPublished})
          .eq('id', examId)
          .select('id');
      if ((data as List).isEmpty) {
        throw const AuthoringException(
          'That paper could not be updated — it may have been deleted, or it may '
          'not be yours. Refresh the console and try again.',
        );
      }
    });
  }

  @override
  Future<void> deleteExam(String examId) async {
    await _guard(() async {
      // Deleting the paper is what cascades: its questions, every attempt
      // against it, their answers, their marks and their incident rows all go
      // with it. The console says so before calling this.
      final data =
          await _client.from('exams').delete().eq('id', examId).select('id');
      if ((data as List).isEmpty) {
        throw const AuthoringException(
          'That paper could not be deleted — it may already be gone, or it may '
          'not be yours. Refresh the console and try again.',
        );
      }
    });
  }

  @override
  Future<List<AuthoredQuestion>> listQuestions(String examId) async {
    final rows = await _guard(() async {
      final data = await _client
          .from('questions')
          .select(questionColumns)
          .eq('exam_id', examId)
          // Written order, which is the order the paper presents: a question
          // list that reshuffles itself between visits reads like a bug.
          .order('created_at', ascending: true);
      return (data as List).cast<Map<String, dynamic>>();
    });

    try {
      return rows.map(AuthoredQuestion.fromMap).toList();
    } catch (_) {
      throw const AuthoringException(
        'A question on this paper carries a shape this build does not know '
        'about. Update the app and try again.',
      );
    }
  }

  @override
  Future<AuthoredQuestion> createQuestion({
    required String examId,
    required QuestionDraft draft,
  }) async {
    // The same shape rules the editor already checked; the database checks them
    // again (`questions_answer_key_shape`), which is what makes a stale console
    // refuse rather than store something half-formed.
    final problem = draft.problem;
    if (problem != null) throw AuthoringException(problem);

    final row = await _guard(() async {
      final data = await _client
          .from('questions')
          .insert(<String, dynamic>{...draft.toRow(), 'exam_id': examId})
          .select(questionColumns)
          .single();
      return data;
    });

    try {
      return AuthoredQuestion.fromMap(row);
    } catch (_) {
      throw const AuthoringException(
        'The question was saved, but the server response could not be read. '
        'Refresh the paper to see it.',
      );
    }
  }

  @override
  Future<AuthoredQuestion> updateQuestion({
    required String questionId,
    required QuestionDraft draft,
  }) async {
    final problem = draft.problem;
    if (problem != null) throw AuthoringException(problem);

    final row = await _guard(() async {
      final data = await _client
          .from('questions')
          .update(draft.toRow())
          .eq('id', questionId)
          .select(questionColumns);
      final rows = (data as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) {
        throw const AuthoringException(
          'That question could not be updated — it may have been deleted, or the '
          'paper may not be yours. Refresh the paper and try again.',
        );
      }
      return rows.first;
    });

    try {
      return AuthoredQuestion.fromMap(row);
    } catch (_) {
      throw const AuthoringException(
        'The question was updated, but the server response could not be read. '
        'Refresh the paper to check it.',
      );
    }
  }

  @override
  Future<void> deleteQuestion(String questionId) async {
    await _guard(() async {
      // Any marks already awarded to this question go with it (the cascade on
      // `question_grades.question_id`), and `score` is *not* recomputed for the
      // attempts that had answered it. The console warns before calling this.
      final data = await _client
          .from('questions')
          .delete()
          .eq('id', questionId)
          .select('id');
      if ((data as List).isEmpty) {
        throw const AuthoringException(
          'That question could not be deleted — it may already be gone. Refresh '
          'the paper and try again.',
        );
      }
    });
  }

  @override
  Future<List<AttemptGrading>> listAttempts(String examId) async {
    // The paper first: the marks on an attempt are only meaningful next to the
    // questions they belong to, and the questions carry the keys and the weights.
    final questions = await listQuestions(examId);

    final submissions = await _guard(() async {
      final data = await _client
          .from('exam_submissions')
          .select('id, student_id, exam_id, answers, status, score, started_at')
          .eq('exam_id', examId)
          // An attempt still in progress is not listed: its answers can change
          // under the marks, and `grade_submission()` refuses it anyway.
          .neq('status', 'ongoing')
          .order('submitted_at', ascending: false);
      return (data as List).cast<Map<String, dynamic>>();
    });

    if (submissions.isEmpty) return const <AttemptGrading>[];

    final submissionIds =
        submissions.map((row) => row['id'] as String).toList(growable: false);
    final studentIds = submissions
        .map((row) => row['student_id'] as String)
        .toSet()
        .toList(growable: false);

    final grades = await _gradesFor(submissionIds);
    final names = await _namesFor(studentIds);

    return submissions.map((row) {
      final submission = Submission.fromMap(row);
      final name = names[submission.studentId];
      return AttemptGrading(
        submission: submission,
        studentName: (name == null || name.isEmpty)
            ? _shortId(submission.studentId)
            : name,
        lines: _linesFor(
          questions,
          submission.answers,
          grades[submission.id] ?? const <String, Map<String, dynamic>>{},
        ),
      );
    }).toList();
  }

  /// Every mark awarded on the given attempts, grouped by attempt and then by
  /// question. One read for the whole list: a per-attempt query would be N round
  /// trips for a screen that shows all of them at once.
  Future<Map<String, Map<String, Map<String, dynamic>>>> _gradesFor(
    List<String> submissionIds,
  ) async {
    final rows = await _guard(() async {
      final data = await _client
          .from('question_grades')
          .select('submission_id, question_id, awarded, feedback, graded_at')
          .inFilter('submission_id', submissionIds);
      return (data as List).cast<Map<String, dynamic>>();
    });

    final bySubmission = <String, Map<String, Map<String, dynamic>>>{};
    for (final row in rows) {
      final submissionId = row['submission_id'] as String?;
      final questionId = row['question_id'] as String?;
      if (submissionId == null || questionId == null) continue;
      bySubmission.putIfAbsent(submissionId,
          () => <String, Map<String, dynamic>>{})[questionId] = row;
    }
    return bySubmission;
  }

  /// `profiles.full_name` for the students whose papers are being marked, in one
  /// read (`profiles_select_own_or_staff` covers the staff tier). A row that
  /// cannot be read is not an error — the caller falls back to a short id so no
  /// attempt is ever anonymous.
  Future<Map<String, String>> _namesFor(List<String> studentIds) async {
    if (studentIds.isEmpty) return const <String, String>{};

    final rows = await _guard(() async {
      final data = await _client
          .from('profiles')
          .select('id, full_name, email')
          .inFilter('id', studentIds);
      return (data as List).cast<Map<String, dynamic>>();
    });

    final names = <String, String>{};
    for (final row in rows) {
      final id = row['id'] as String?;
      if (id == null) continue;
      final fullName = (row['full_name'] as String? ?? '').trim();
      final email = (row['email'] as String? ?? '').trim();
      names[id] = fullName.isNotEmpty ? fullName : email;
    }
    return names;
  }

  /// Joins a paper's questions to one attempt's answers and marks, in paper
  /// order. A question with nothing stored under it is a line with
  /// `rawAnswer == null` rather than a missing row: "unanswered" is a state the
  /// grading screen has to show.
  List<GradeLine> _linesFor(
    List<AuthoredQuestion> questions,
    Map<String, dynamic> answers,
    Map<String, Map<String, dynamic>> grades,
  ) =>
      questions.map((question) {
        final grade = grades[question.id];
        return GradeLine(
          question: question,
          rawAnswer: answers[question.id],
          awarded: (grade?['awarded'] as num?)?.toDouble(),
          feedback: grade?['feedback'] as String?,
          gradedAt: Submission.parseTimestamp(grade?['graded_at']),
        );
      }).toList(growable: false);

  /// The fallback label when a student's profile row cannot be read. Matches the
  /// live monitor's `Student <id>` convention, so one attempt is recognisable
  /// across both screens.
  static String _shortId(String id) {
    final first = id.split('-').first;
    return 'Student $first';
  }

  @override
  Future<GradingOutcome> saveGrades({
    required String submissionId,
    required Map<String, dynamic> grades,
  }) async {
    final row = await _guard(() async {
      // The RPC is the only writer of `question_grades` and the only writer of
      // the part of `score` a person influenced: it validates every mark against
      // the question's weight, upserts, and recomputes the total. Nothing here
      // computes marks — the console reports what the server answered.
      final data = await _client.rpc(
        'grade_submission',
        params: <String, dynamic>{
          'p_submission_id': submissionId,
          'p_grades': grades,
        },
      );

      // `returns table` comes back as a one-row array.
      if (data is List && data.isNotEmpty && data.first is Map) {
        return (data.first as Map).cast<String, dynamic>();
      }
      if (data is Map) return data.cast<String, dynamic>();

      throw const AuthoringException(
        'The server answered without a total. Reload the attempt to check '
        'whether the marks were saved.',
      );
    });

    return GradingOutcome.fromMap(row);
  }

  /// Runs a call and converts every failure into [AuthoringException], so the
  /// console has one error type to render.
  ///
  /// An [AuthoringException] raised inside [action] passes through unchanged (it
  /// is already written for a lecturer).
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AuthoringException {
      rethrow;
    } on PostgrestException catch (error) {
      throw AuthoringException(_messageFromPostgrest(error));
    } catch (_) {
      throw const AuthoringException(
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  /// Turns a PostgREST refusal into a sentence, with the two cases a lecturer can
  /// actually act on named rather than summarised as "permission denied".
  static String _messageFromPostgrest(PostgrestException error) {
    switch (error.code) {
      case '42501':
        return 'Only the owner of a paper can change it or mark its answers. '
            'Sign in as its author, or ask an administrator.';
      case '23514':
        // A check constraint: `questions_answer_key_shape` or the type list.
        return 'The server refused that question shape. Every option needs '
            'text, exactly one answer key is allowed, and marks cannot be '
            'negative.';
      case '23505':
        return 'That has already been saved. Refresh the screen to see it.';
      case '42883':
      case 'PGRST202':
        // The RPC is missing: the upgrade migration has not been applied.
        return 'This project has no grading function yet. Run '
            'supabase/migrations/question_types_and_grading.sql, then try again.';
      case '42P01':
        return 'This project is missing the grading tables. Run '
            'supabase/migrations/question_types_and_grading.sql, then try again.';
      case '55000':
      case '22023':
      case 'P0002':
        // Raised by `grade_submission()` with a sentence already written for a
        // person ("submission … is still in progress").
        return error.message;
    }
    return error.message;
  }
}
