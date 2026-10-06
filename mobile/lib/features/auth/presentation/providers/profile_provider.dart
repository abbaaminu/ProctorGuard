import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';

/// Bound in `main()` through `ProviderScope.overrides` once a Supabase client
/// exists — the same pattern as the exam/proctoring repositories, so the gate
/// and its tests never reach for a global.
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  throw UnimplementedError(
    'Override in ProviderScope with ProfileRepositoryImpl(client)',
  );
});

/// The signed-in account's profile, keyed by **auth** user id so signing in as
/// somebody else resolves a fresh row instead of reusing the previous one.
///
/// `FutureProvider` gives the gate its three states for free: loading (spinner),
/// error (retryable message) and data (route on `role`).
///
/// The loading state is the one that covers the sign-in race: the repository
/// keeps looking for a row that is not there *yet* (`ProfileRepositoryImpl`), so
/// this future stays pending through those attempts and the gate shows its
/// spinner rather than an error about a profile that is about to exist.
final userProfileProvider = FutureProvider.family<UserProfile, String>(
  (ref, userId) => ref.watch(profileRepositoryProvider).getProfile(userId),
);
