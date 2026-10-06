import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/admin_user_repository_impl.dart';
import '../../domain/entities/managed_account.dart';
import '../../domain/repositories/admin_user_repository.dart';

/// The admin account repository.
///
/// Throws until overridden — `main()` overrides it with
/// `AdminUserRepositoryImpl(Supabase.instance.client)`, the same arrangement as
/// `profileRepositoryProvider`, so a widget test can inject a fake without a
/// backend.
final adminUserRepositoryProvider = Provider<AdminUserRepository>(
  (ref) => throw UnimplementedError(
    'adminUserRepositoryProvider must be overridden with an '
    'AdminUserRepository (see main.dart / ProviderScope overrides).',
  ),
);

/// Every account the signed-in admin may see (`profiles_select_own_or_staff`
/// scopes the rows server-side). Invalidate it to refetch — after creating an
/// account, after re-roling one, from the refresh button, and when the app comes
/// back to the foreground (`RefreshOnResume`).
///
/// `autoDispose`, so reopening the dashboard reads the roster again instead of
/// showing the copy it cached the first time.
final managedAccountsProvider = FutureProvider.autoDispose<List<ManagedAccount>>(
  (ref) => ref.watch(adminUserRepositoryProvider).listAccounts(),
);

/// The temporary-password floor, exposed for the page's validator.
const int adminMinPasswordLength = AdminUserRepositoryImpl.minPasswordLength;
