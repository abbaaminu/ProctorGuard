import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../auth/domain/entities/user_profile.dart';
import '../../domain/entities/managed_account.dart';
import '../../domain/repositories/admin_user_repository.dart';

/// Supabase-backed [AdminUserRepository].
///
/// Two halves, on purpose:
///   - creating an account goes through the `admin-create-user` Edge Function,
///     because only the service_role key can write `auth.users` (and only that
///     key may insert a `profiles` row whose role is not 'student');
///   - listing and re-roling are plain PostgREST calls, authorised by the
///     `profiles_admin_all` policy and the `guard_user_role_change()` trigger.
class AdminUserRepositoryImpl implements AdminUserRepository {
  AdminUserRepositoryImpl(this._client);

  static const String createAccountFunction = 'admin-create-user';
  static const String deleteAccountFunction = 'admin-delete-user';
  static const String resetPasswordFunction = 'admin-reset-password';

  /// Supabase Auth's default minimum, mirrored by the Edge Function.
  static const int minPasswordLength = 6;

  final SupabaseClient _client;

  @override
  Future<ManagedAccount> createAccount({
    required String email,
    required String password,
    required String fullName,
    required UserRole role,
  }) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        createAccountFunction,
        body: {
          'email': email.trim(),
          // Never trimmed: leading/trailing spaces can be part of a password,
          // and the server hashes it verbatim.
          'password': password,
          'full_name': fullName.trim(),
          'role': role.dbValue,
        },
      );
    } on FunctionException catch (error) {
      // Covers FunctionsHttpException (the function answered 4xx/5xx with
      // `{ error }`), FunctionsRelayException and FunctionsFetchException
      // (status 0 — the request never reached the server at all).
      throw AdminAccountException(_messageFromFunctionError(error));
    } catch (_) {
      throw const AdminAccountException(
        'Could not reach the server. Check your connection and try again.',
      );
    }

    final data = response.data;
    if (data is Map<String, dynamic>) {
      // Defensive: a function that answers 200 with `{ error }` (a proxy, or an
      // older deployment) must not be mistaken for a created account.
      final error = data['error'];
      if (error is String && error.isNotEmpty) {
        throw AdminAccountException(error);
      }
      try {
        return ManagedAccount.fromMap(data);
      } catch (_) {
        throw const AdminAccountException(
          'The account was created, but the server response could not be read. '
          'Refresh the list to check.',
        );
      }
    }
    throw const AdminAccountException(
      'The server returned an unexpected response. Refresh the list to check.',
    );
  }

  @override
  Future<List<ManagedAccount>> listAccounts() async {
    final rows = await _guard(() async {
      final data = await _client
          .from('profiles')
          .select()
          // Oldest first: the seeded/bootstrap admin stays at the top, which is
          // where an administrator looks for "the account that made mine".
          .order('created_at', ascending: true);
      return (data as List).cast<Map<String, dynamic>>();
    });

    try {
      return rows.map(ManagedAccount.fromMap).toList();
    } catch (_) {
      throw const AdminAccountException(
        'Some accounts could not be read: the roster carries a role this build '
        'does not know about. Update the app and try again.',
      );
    }
  }

  @override
  Future<void> updateRole({
    required String userId,
    required UserRole role,
  }) async {
    await _guard(() async {
      // `.select()` makes PostgREST return the updated row, so "no row matched"
      // (a deleted account, or a caller who is not an admin) is distinguishable
      // from a successful update instead of silently reporting success.
      final data = await _client
          .from('profiles')
          .update({'role': role.dbValue})
          .eq('id', userId)
          .select();
      if ((data as List).isEmpty) {
        throw const AdminAccountException(
          'That account could not be updated — it may have been deleted. '
          'Refresh the list and try again.',
        );
      }
    });
  }

  @override
  Future<void> resetPassword({
    required String userId,
    required String password,
  }) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        resetPasswordFunction,
        // The function accepts `userId`/`accountId` too; `id` is the spelling
        // the table uses, and `admin-delete-user` already takes.
        body: {'id': userId, 'password': password},
      );
    } on FunctionException catch (error) {
      throw AdminAccountException(_messageFromResetFunctionError(error));
    } catch (_) {
      throw const AdminAccountException(
        'Could not reach the server. Check your connection and try again.',
      );
    }

    final data = response.data;
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is String && error.isNotEmpty) {
        throw AdminAccountException(error);
      }
      // The changed account's own id, echoed back: proof the function answered
      // about the row this call named rather than about somebody else's.
      if (data['id'] == userId) return;
    }
    throw const AdminAccountException(
      'The password may not have been changed: the server response could not '
      'be read. Sign in as that account to check, or reset it again.',
    );
  }

  @override
  Future<void> deleteAccount({required String userId}) async {
    final FunctionResponse response;
    try {
      response = await _client.functions.invoke(
        deleteAccountFunction,
        body: {'id': userId},
      );
    } on FunctionException catch (error) {
      throw AdminAccountException(
        _messageFromDeleteFunctionError(error),
      );
    } catch (_) {
      throw const AdminAccountException(
        'Could not reach the server. Check your connection and try again.',
      );
    }

    final data = response.data;
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is String && error.isNotEmpty) {
        throw AdminAccountException(error);
      }
      if (data['id'] == userId) return;
    }
    throw const AdminAccountException(
      'The server returned an unexpected response. Refresh the list to check.',
    );
  }

  /// Runs a PostgREST call and converts every failure into
  /// [AdminAccountException], so the page has one error type to render.
  ///
  /// An [AdminAccountException] raised inside [action] passes through unchanged
  /// (it is already written for the administrator).
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AdminAccountException {
      rethrow;
    } on PostgrestException catch (error) {
      throw AdminAccountException(_messageFromPostgrest(error));
    } catch (_) {
      throw const AdminAccountException(
        'Could not reach the server. Check your connection and try again.',
      );
    }
  }

  /// Reads the `{ error }` body the Edge Function answers with.
  static String _messageFromFunctionError(FunctionException error) {
    if (error.status == 0) {
      return 'Could not reach the server. Check your connection and try again.';
    }
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
    if (details is String && details.trim().isNotEmpty) {
      // A non-JSON error body (a proxy page, or a 404 from an un-deployed
      // function) — better to show it than a bare status code.
      return details.trim();
    }
    if (error.status == 404) {
      return 'The $createAccountFunction function is not deployed on this '
          'project (see supabase/functions/admin-create-user).';
    }
    if (error.status == 401 || error.status == 403) {
      return 'Only an administrator can create accounts.';
    }
    return 'The server refused the request (${error.status}). Try again.';
  }

  static String _messageFromDeleteFunctionError(FunctionException error) {
    if (error.status == 0) {
      return 'Could not reach the server. Check your connection and try again.';
    }
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
    if (details is String && details.trim().isNotEmpty) {
      return details.trim();
    }
    if (error.status == 404) {
      return 'The $deleteAccountFunction function is not deployed on this '
          'project (see supabase/functions/admin-delete-user).';
    }
    if (error.status == 401 || error.status == 403) {
      return 'Only an administrator can delete accounts.';
    }
    return 'The server refused the request (${error.status}). Try again.';
  }

  /// Reads the `{ error }` body `admin-reset-password` answers with.
  ///
  /// Same shape as the other two, and the same caveat about the 404 branch: the
  /// function *itself* answers 404 with `{ error }` for an account that is gone,
  /// and that message is read by the branch above — so reaching the 404 here
  /// means the response carried no JSON body at all, which is what an
  /// un-deployed function (or a proxy) returns.
  static String _messageFromResetFunctionError(FunctionException error) {
    if (error.status == 0) {
      return 'Could not reach the server. Check your connection and try again.';
    }
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
    if (details is String && details.trim().isNotEmpty) {
      return details.trim();
    }
    if (error.status == 404) {
      return 'The $resetPasswordFunction function is not deployed on this '
          'project (see supabase/functions/admin-reset-password).';
    }
    if (error.status == 401 || error.status == 403) {
      return 'Only an administrator can reset passwords.';
    }
    return 'The server refused the request (${error.status}). Try again.';
  }

  static String _messageFromPostgrest(PostgrestException error) {
    // 42501 is "insufficient privilege": a policy or the role-change trigger
    // rejected the write because the caller is not an admin.
    if (error.code == '42501' || error.message.contains('row-level security')) {
      return 'Only an administrator may change accounts.';
    }
    return error.message;
  }
}
