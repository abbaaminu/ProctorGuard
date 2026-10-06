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
/// `autoDispose` on top of that keeps a *finished* lookup from outliving the
/// session it belonged to: signing out drops the family entry, so the next
/// sign-in reads `profiles` again instead of being handed the previous answer —
/// including the previous *error*, which used to make a transient failure look
/// permanent ("we could not load your profile" every time, until Try again).
///
/// The loading state is the one that covers the sign-in race: the repository
/// keeps looking for a row that is not there *yet* (`ProfileRepositoryImpl`), so
/// this future stays pending through those attempts and the gate shows its
/// spinner rather than an error about a profile that is about to exist. If it is
/// still absent at the end of that window the repository gives the account its
/// own student row back (see `_ensureOwnRow`) before the gate is ever shown an
/// error.
final userProfileProvider = FutureProvider.autoDispose.family<UserProfile, String>(
  (ref, userId) => ref.watch(profileRepositoryProvider).getProfile(userId),
);
