import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/exam/domain/repositories/exam_repository.dart';
import '../../features/proctoring/domain/repositories/proctoring_repository.dart';
import '../services/key_value_store.dart';
import '../services/network_status.dart';
import '../services/offline_sync_service.dart';

/// Composition root for the data + offline layers.
///
/// These two repository providers used to be declared next to the proctoring
/// notifier, with a note that "in the real project they'd live in core/di
/// alongside SupabaseService.instance.client". They moved here when the offline
/// queue arrived: `OfflineSyncService` needs both repositories, and
/// `ProctoringNotifier` needs the service, so keeping the repositories and the
/// service in the same file is what keeps the import graph acyclic.
///
/// `main()` still overrides both with the Supabase-backed implementations, and
/// `proctoring_provider.dart` re-exports them, so every existing import site
/// keeps working unchanged.
final examRepositoryProvider = Provider<ExamRepository>((ref) {
  throw UnimplementedError('Override in ProviderScope with ExamRepositoryImpl(client)');
});

final proctoringRepositoryProvider = Provider<ProctoringRepository>((ref) {
  throw UnimplementedError('Override in ProviderScope with ProctoringRepositoryImpl(client)');
});

/// The app-wide offline layer: local answer cache, answer/violation retry queues
/// and the [SyncState] the exam banner renders.
///
/// Not `autoDispose`: one queue for the whole run, so work cached during an exam
/// survives leaving the screen, a refresh and (because it is on disk) a restart.
final offlineSyncServiceProvider = Provider<OfflineSyncService>((ref) {
  final service = OfflineSyncService(
    exams: ref.watch(examRepositoryProvider),
    proctoring: ref.watch(proctoringRepositoryProvider),
    store: ref.watch(keyValueStoreProvider),
    // The probe is owned by the service: it disposes it with everything else.
    network: NetworkStatus(),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// How the proctoring notifier delivers violations: the durable queue above.
final violationOutboxProvider =
    Provider<ViolationOutbox>((ref) => ref.watch(offlineSyncServiceProvider));
