import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../authoring/presentation/providers/question_authoring_providers.dart';
import '../../../supervision/presentation/providers/supervision_providers.dart';
import '../../domain/entities/attempt_evidence.dart';
import '../../domain/repositories/evidence_repository.dart';

/// The Evidence repository.
///
/// Throws until overridden — `main()` binds it to
/// `EvidenceRepositoryImpl(Supabase.instance.client)`, the same arrangement as
/// every other repository, so a widget test can inject a fake without a backend
/// and the screen never reaches for a global.
final evidenceRepositoryProvider = Provider<EvidenceRepository>(
  (ref) => throw UnimplementedError(
    'evidenceRepositoryProvider must be overridden with an '
    'EvidenceRepository (see main.dart / ProviderScope overrides).',
  ),
);

/// Every incident on one paper, grouped per attempt.
///
/// Keyed by exam id, `autoDispose`, invalidated by the page's own refresh
/// control: reopening the screen asks the database again rather than showing the
/// sitting as it looked before the last attempt was written.
final examEvidenceProvider = FutureProvider.autoDispose
    .family<List<AttemptEvidence>, String>(
      (ref, examId) =>
          ref.watch(evidenceRepositoryProvider).listExamEvidence(examId),
    );

/// The papers the Evidence screen may offer, from the list each portal already
/// loads.
///
/// Deliberately a reuse rather than a new query: the lecturer's console already
/// watches `myAuthoredExamsProvider` (their own papers, drafts included) and the
/// administrator's "Assign supervisors" screen already watches
/// `supervisionExamsProvider` (every paper an administrator may act on, drafts
/// included). Both read through the caller's own policies, so the picker cannot
/// offer a paper the RPC would then refuse.
///
/// A family rather than two providers so the page has one thing to watch and a
/// test has one thing to override.
final evidenceExamOptionsProvider = FutureProvider.autoDispose
    .family<List<EvidenceExamOption>, EvidenceAudience>((ref, audience) async {
      switch (audience) {
        case EvidenceAudience.lecturer:
          final papers = await ref.watch(myAuthoredExamsProvider.future);
          return <EvidenceExamOption>[
            for (final paper in papers)
              EvidenceExamOption(id: paper.exam.id, title: paper.exam.title),
          ];
        case EvidenceAudience.admin:
          final papers = await ref.watch(supervisionExamsProvider.future);
          return <EvidenceExamOption>[
            for (final paper in papers)
              EvidenceExamOption(id: paper.id, title: paper.title),
          ];
      }
    });
