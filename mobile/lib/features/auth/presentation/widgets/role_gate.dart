import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart';
import '../../../admin/presentation/pages/admin_dashboard_page.dart';
import '../../../authoring/presentation/pages/lecturer_console_page.dart';
import '../../../dashboard/presentation/pages/supervisor_exam_picker_page.dart';
import '../../../exam/presentation/pages/student_exam_portal_page.dart';
import '../../domain/entities/user_profile.dart';
import '../../domain/repositories/profile_repository.dart';
import '../pages/login_page.dart';
import '../providers/profile_provider.dart';

/// Post-login router: reads `profiles.role` for the authenticated account and
/// hands the session to the matching home.
///
///   `student`               -> [StudentExamPortalPage]    (published exams ->
///                              exam session)
///   `supervisor`            -> [SupervisorExamPickerPage] (pick an exam ->
///                              live monitor)
///   `lecturer`              -> [LecturerConsolePage]      (author a paper's
///                              questions -> mark what came back; the live
///                              monitor is one tap away in its app bar)
///   `admin`                 -> [AdminDashboardPage]        (create accounts,
///                              manage roles)
///
/// Lecturers and supervisors share `is_staff()` in the database, which is what
/// lets both read every attempt (the roster of any sitting, so a monitor can be
/// opened for any exam). They differ where the work differs: a lecturer owns the
/// papers they wrote - only the author may edit a question, award marks on an
/// essay (`grade_submission()` re-checks it) or read the evidence recorded on
/// that paper (the `owns_exam()` arm of `logs_select_own_or_supervisor` and of
/// the reset audit policy) - while a supervisor runs any sitting and reads every
/// paper's evidence. Lecturers therefore land on the authoring console, and reach
/// the monitor through it.
///
/// The reset control is not one of the differences: `canResetAttempts` is the
/// schema's own rule — `is_attempt_resetter()` names `admin`, `supervisor` **and
/// `lecturer`**, because the paper's author is the one who has to repair a wrong
/// key or a mis-aimed disqualification — asked through [UserRole.canResetAttempts]
/// so the gate and the live monitor cannot answer it differently. The narrower
/// tier that remains is the *intervention* one: `is_exam_supervisor()` still
/// guards writing to somebody else's attempt row in place.
///
/// Auth events are what drive the rebuild, so the session the SDK restores from
/// storage after a browser refresh lands here too.
class RoleGate extends ConsumerWidget {
  const RoleGate({
    super.key,
    this.signedInChanges,
    this.currentUserId,
    this.signOut,
  });

  /// Injectable for tests; defaults to the Supabase singleton.
  final Stream<bool>? signedInChanges;

  /// Returns the signed-in auth user id, or `null` when signed out.
  final String? Function()? currentUserId;

  /// Sign-out offered by the error state, so a broken profile row can never
  /// trap a user on a dead screen.
  final Future<AuthOutcome> Function()? signOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userIdOf =
        currentUserId ?? () => SupabaseService.instance.currentUserId;

    return StreamBuilder<bool>(
      stream: signedInChanges ?? SupabaseService.instance.signedInChanges,
      builder: (context, snapshot) {
        final userId = userIdOf();
        if (userId == null) return const LoginPage();

        return ref.watch(userProfileProvider(userId)).when(
              loading: () => const _ProfileLoading(),
              error: (error, _) => _ProfileError(
                message: error is ProfileLookupException
                    ? error.message
                    : 'Could not load your profile.',
                onRetry: () => ref.invalidate(userProfileProvider(userId)),
                onSignOut: () => _signOut(context, ref, userId),
              ),
              data: (profile) => switch (profile.role) {
                UserRole.student => StudentExamPortalPage(
                    studentName: profile.displayName,
                    onSignOut: () => _signOut(context, ref, userId),
                  ),
                UserRole.supervisor => SupervisorExamPickerPage(
                    supervisorName: profile.displayName,
                    canResetAttempts: profile.role.canResetAttempts,
                    onSignOut: () => _signOut(context, ref, userId),
                  ),
                // A lecturer lands on the console that owns the work only they
                // can do: authoring a paper and marking its answers. Their
                // invigilation tools (the live monitor, and a reset control they
                // are refused by the schema) are one tap away in that console's
                // app bar, so `is_staff()`'s shared reading rights are still
                // reachable — see `LecturerConsolePage._openMonitor`.
                UserRole.lecturer => LecturerConsolePage(
                    lecturerName: profile.displayName,
                    onSignOut: () => _signOut(context, ref, userId),
                  ),
                UserRole.admin => AdminDashboardPage(
                    adminName: profile.displayName,
                    // The signed-in id, so the page can recognise this admin's
                    // own roster row without a second trip to the SDK.
                    adminId: userId,
                    onSignOut: () => _signOut(context, ref, userId),
                  ),
              },
            );
      },
    );
  }

  Future<void> _signOut(
    BuildContext context,
    WidgetRef ref,
    String userId,
  ) async {
    final outcome = await (signOut ?? SupabaseService.instance.signOut)();
    if (!context.mounted) return;

    // Drop the cached profile either way: after a successful sign-out the next
    // account must not inherit this role, and after a failure a retry should
    // re-read the row rather than serve the old error.
    ref.invalidate(userProfileProvider(userId));

    if (!outcome.ok) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(outcome.message ?? 'Sign-out failed. Try again.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
    }
  }
}

/// Shown while `public.profiles` is being read — deliberately a full screen with a
/// label, since this is the moment between "signed in" and "knows where to go".
///
/// This screen covers the repository's silent retry window too:
/// `ProfileRepositoryImpl.getProfile` looks again (on an increasing delay) when
/// the first read finds no row, because a fresh session can be emitted a moment
/// before the `handle_new_user` trigger's row is visible to that query. So the
/// screen can legitimately be up for a second or two, and after [hintDelay] it
/// says so rather than looking frozen. It never turns into the error screen by
/// itself — only a real [ProfileLookupException] does that.
class _ProfileLoading extends StatefulWidget {
  const _ProfileLoading();

  /// Long enough that an ordinary load never shows the hint, short enough that a
  /// retry in progress does.
  static const Duration hintDelay = Duration(milliseconds: 1500);

  @override
  State<_ProfileLoading> createState() => _ProfileLoadingState();
}

class _ProfileLoadingState extends State<_ProfileLoading> {
  /// One-shot: cancelled as soon as the loading screen goes away, so no timer is
  /// left behind when the profile resolves (or errors) before it fires.
  Timer? _hintUntilSlow;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _hintUntilSlow = Timer(_ProfileLoading.hintDelay, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _hintUntilSlow?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Loading your profile…'),
            if (_slow) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  'Still trying — your profile row can take a moment to appear '
                  'after sign-in.',
                  key: const Key('profile-loading-hint'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Role lookup failed (offline, no `profiles` row, unknown role value). Retryable,
/// and always offers a way out.
class _ProfileError extends StatelessWidget {
  const _ProfileError({
    required this.message,
    required this.onRetry,
    required this.onSignOut,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.person_off_outlined,
                    size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 12),
                Text('We could not load your profile',
                    style: theme.textTheme.titleLarge,
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('profile-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('profile-sign-out'),
                  onPressed: onSignOut,
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
