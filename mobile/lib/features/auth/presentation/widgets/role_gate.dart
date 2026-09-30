import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart';
import '../../../admin/presentation/pages/admin_dashboard_page.dart';
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
///   `supervisor`, `lecturer`-> [SupervisorExamPickerPage] (pick an exam ->
///                              live monitor)
///   `admin`                 -> [AdminDashboardPage]        (create accounts,
///                              manage roles)
///
/// Lecturers share the supervisor console: `is_staff()` treats them alike for
/// reading profiles and monitoring a session, and the two roles differ only in
/// what the institution calls them.
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
                UserRole.supervisor || UserRole.lecturer =>
                  SupervisorExamPickerPage(
                    supervisorName: profile.displayName,
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

/// Shown while `public.users` is being read — deliberately a full screen with a
/// label, since this is the moment between "signed in" and "knows where to go".
class _ProfileLoading extends StatelessWidget {
  const _ProfileLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading your profile…'),
          ],
        ),
      ),
    );
  }
}

/// Role lookup failed (offline, no `users` row, unknown role value). Retryable,
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
