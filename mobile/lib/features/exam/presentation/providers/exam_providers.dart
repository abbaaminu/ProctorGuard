import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../domain/entities/exam.dart';

/// Published exams, newest first — the list behind the student portal and the
/// supervisor picker.
///
/// One provider for both homes so they agree on what "available" means:
/// `exams.is_published`, with RLS already scoping the rows to what the caller
/// may see. Invalidate it to refresh (pull-to-refresh, or a retry button).
final publishedExamsProvider = FutureProvider<List<Exam>>(
  (ref) => ref.watch(examRepositoryProvider).getPublishedExams(),
);
