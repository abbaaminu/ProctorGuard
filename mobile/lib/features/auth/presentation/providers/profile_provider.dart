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

/// How long the gate waits for a profile before it stops waiting.
///
/// The repository's own window is ~25 s at the outside - five attempts, each given
/// `ProfileRepositoryImpl.defaultAttemptTimeout`, separated by
/// `ProfileRepositoryImpl.defaultRetryDelays` (0.25 + 0.75 + 1.5 + 3 s) - so this
/// bound exists only to catch a lookup that gets stuck somewhere the repository
/// cannot see. It was ten seconds, which was shorter than the repository's own
/// worst case: a cold start, a laptop waking up or a project coming out of pause
/// therefore showed "Loading your profile took too long" for a connection that was
/// still resolving (the false failure seen in live testing), and the retries that
/// had been added for exactly that case never got to finish. Thirty seconds is
/// "something is genuinely wrong": a socket that never answers, a paused project,
/// or a trigger that raised and will never write the row. Without a bound the
/// future simply stays pending - there is no error to catch because nothing failed
/// - and the gate spins on "Loading your profile…" with no retry and no way out but
/// killing the app.
const Duration profileLoadTimeout = Duration(seconds: 30);

/// The message the timeout produces, kept next to the bound so the two are read
/// together (and so a test can assert what the student is actually told).
const String profileTimeoutMessage =
    'Loading your profile took too long. Check your connection and try again — '
    'if this keeps happening, ask your administrator to check your account.';

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
///
/// [profileLoadTimeout] is the backstop for the case where *nothing* comes back:
/// the repository's retries are bounded, but a request that never answers is
/// not, and a pending future is not an error the gate can render. The timeout
/// turns it into an ordinary [ProfileLookupException], so the loading screen
/// becomes the retryable error screen (Try again re-reads the row; Sign out is
/// still offered) instead of an endless spinner. The abandoned lookup is not
/// cancelled — a late `_ensureOwnRow` may still create the row — it is only no
/// longer waited on.
final userProfileProvider = FutureProvider.autoDispose.family<UserProfile, String>(
  (ref, userId) => ref
      .watch(profileRepositoryProvider)
      .getProfile(userId)
      .timeout(
        profileLoadTimeout,
        onTimeout: () => throw const ProfileLookupException(
          profileTimeoutMessage,
        ),
      ),
);
