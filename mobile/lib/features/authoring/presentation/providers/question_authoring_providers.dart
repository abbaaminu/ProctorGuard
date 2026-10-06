import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/attempt_grading.dart';
import '../../domain/entities/authored_exam.dart';
import '../../domain/entities/authored_question.dart';
import '../../domain/repositories/question_authoring_repository.dart';

/// The authoring/grading repository.
///
/// Throws until overridden — `main()` binds it to
/// `QuestionAuthoringRepositoryImpl(Supabase.instance.client)`, the same
/// arrangement as the other repositories, so a widget test can inject a fake
/// without a backend and the console never reaches for a global.
final questionAuthoringRepositoryProvider =
    Provider<QuestionAuthoringRepository>(
  (ref) => throw UnimplementedError(
    'questionAuthoringRepositoryProvider must be overridden with a '
    'QuestionAuthoringRepository (see main.dart / ProviderScope overrides).',
  ),
);

/// The papers the signed-in account owns, newest first.
///
/// Invalidate after anything that changes the list *or* the counts on it —
/// creating a paper, publishing one, authoring a question (the tile counts
/// questions), or deleting either. The console also does that for itself when it
/// returns from a paper's question or marking screen, and `RefreshOnResume` does
/// it when the app comes back to the foreground.
///
/// `autoDispose`, so reopening the console reads the papers again rather than
/// showing the copy it cached the first time.
final myAuthoredExamsProvider = FutureProvider.autoDispose<List<AuthoredExam>>(
  (ref) => ref.watch(questionAuthoringRepositoryProvider).listMyExams(),
);

/// One paper's questions, answer keys included. Invalidate after every edit.
final examQuestionsProvider =
    FutureProvider.autoDispose.family<List<AuthoredQuestion>, String>(
  (ref, examId) =>
      ref.watch(questionAuthoringRepositoryProvider).listQuestions(examId),
);

/// Every handed-in attempt against one paper, each carrying the whole paper so
/// the grading screen can render it without a second read. Invalidate after
/// saving marks.
final examAttemptsProvider =
    FutureProvider.autoDispose.family<List<AttemptGrading>, String>(
  (ref, examId) =>
      ref.watch(questionAuthoringRepositoryProvider).listAttempts(examId),
);
