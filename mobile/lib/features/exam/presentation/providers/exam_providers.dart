import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../proctoring/presentation/providers/proctoring_provider.dart';
import '../../domain/entities/exam.dart';

/// Published exams, newest first — the list behind the student portal and the
/// supervisor picker.
///
/// One provider for both homes so they agree on what "available" means:
/// `exams.is_published`, with RLS already scoping the rows to what the caller
/// may see. Invalidate it to refresh (pull-to-refresh, the app bar's refresh
/// button), which the callers also do for themselves after anything that can
/// change the list — finishing an attempt, closing a monitor — and which
/// `RefreshOnResume` does when the app comes back to the foreground.
///
/// `autoDispose`, so a screen that is closed and reopened reads the database
/// again rather than being handed the answer it cached the first time.
final publishedExamsProvider = FutureProvider.autoDispose<List<Exam>>(
  (ref) => ref.watch(examRepositoryProvider).getPublishedExams(),
);
