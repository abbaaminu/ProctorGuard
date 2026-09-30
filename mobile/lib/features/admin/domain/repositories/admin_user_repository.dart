import '../../../auth/domain/entities/user_profile.dart';
import '../entities/managed_account.dart';

/// A failure the administrator should read verbatim.
///
/// [message] is always user-facing prose: the repository translates
/// PostgREST/Edge-Function/network failures into it so the page can put it
/// straight in a SnackBar instead of the raw server string.
class AdminAccountException implements Exception {
  const AdminAccountException(this.message);

  final String message;

  @override
  String toString() => 'AdminAccountException: $message';
}

/// Account management for an admin: create a staff/student login, list every
/// profile, and move somebody between roles.
///
/// Only an `admin` can use any of it. The write paths enforce that twice: the
/// server (`admin-create-user` checks the caller's role before touching the
/// service_role key) and the database (`profiles_admin_all` + the
/// `guard_user_role_change()` trigger, which only lets an admin or the
/// service_role rewrite `role`).
abstract class AdminUserRepository {
  /// Creates an auth account *and* its `profiles` row through the
  /// `admin-create-user` Edge Function.
  ///
  /// The account comes back already email-confirmed, so [password] is the
  /// temporary password to hand over at sign-in. Throws
  /// [AdminAccountException] when the caller is not an admin, when the email is
  /// taken, or when the request never reached the server.
  Future<ManagedAccount> createAccount({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
  });

  /// Every profile row the caller may read — an admin reads all of them
  /// (`profiles_select_own_or_staff`), so this is the full roster.
  Future<List<ManagedAccount>> listAccounts();

  /// Moves an existing account to a different role.
  ///
  /// Throws [AdminAccountException] when the caller may not write that row, or
  /// when [userId] no longer exists.
  Future<void> updateRole({required String userId, required UserRole role});
}
