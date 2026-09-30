import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart' show SupabaseService;
import '../../../../core/widgets/responsive_layout.dart';
import '../../../auth/domain/entities/user_profile.dart';
import '../../domain/entities/managed_account.dart';
import '../../domain/repositories/admin_user_repository.dart';
import '../providers/admin_providers.dart';

/// The admin home: create staff/student accounts and manage the roles of the
/// ones that already exist.
///
/// Only reachable with `profiles.role = 'admin'` ([_RoleGate] routes here on
/// that role, and every call this page makes is refused server-side for anyone
/// else), so the page itself does not re-check: it shows the failure it gets
/// back instead. Both halves are needed — the gate decides *where a user
/// lands*, the database decides *what they may do*.
///
/// Creating an account is the one thing that cannot be a plain PostgREST call:
/// `auth.users` is owned by Supabase Auth and `profiles_insert_self_student`
/// rejects any role but 'student', so the page goes through the
/// `admin-create-user` Edge Function, which holds the service_role key and
/// performs both writes ([AdminUserRepository.createAccount]).
class AdminDashboardPage extends ConsumerStatefulWidget {
  const AdminDashboardPage({
    super.key,
    this.adminName,
    this.adminId,
    this.onSignOut,
  });

  /// Greeting name; the gate passes the signed-in profile's `full_name`.
  final String? adminName;

  /// The signed-in admin's own id, so their row can be recognised in the
  /// roster. Defaults to the Supabase session's user id.
  final String? adminId;

  /// Sign-out shown in the app bar (the gate owns the Supabase call).
  final VoidCallback? onSignOut;

  @override
  ConsumerState<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends ConsumerState<AdminDashboardPage> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  /// Defaults to the role the seeded accounts are mostly made of: creating a
  /// *student* is what the public sign-up form is for, so an admin opening this
  /// page is usually provisioning staff.
  UserRole _role = UserRole.lecturer;

  bool _submitting = false;
  bool _obscurePassword = true;

  /// The id whose role change is in flight, so exactly one row is disabled.
  String? _busyId;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validateFullName(String? value) =>
      (value ?? '').trim().isEmpty ? "Enter the person's full name" : null;

  String? _validateEmail(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return 'Enter an email address';
    // Deliberately loose: the Edge Function and Supabase Auth both validate
    // again, and a clever regex here would only reject valid addresses.
    final looksLikeEmail =
        email.contains('@') && email.split('@').last.contains('.');
    return looksLikeEmail ? null : 'Enter a valid email address';
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter a temporary password';
    if (password.length < adminMinPasswordLength) {
      return 'Use at least $adminMinPasswordLength characters';
    }
    return null;
  }

  void _showMessage(String message, {bool isError = true}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // One message at a time: a stale error must not stack up behind a new one.
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  /// The signed-in admin's own id — their roster row cannot be re-roled from
  /// here (demoting yourself would lock you out of the page that undoes it).
  String? get _selfId => widget.adminId ?? SupabaseService.instance.currentUserId;

  Future<void> _createAccount() async {
    if (_submitting) return; // a double tap must not create two accounts
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final email = _emailController.text.trim();
    final fullName = _fullNameController.text.trim();
    // Not trimmed: the server hashes the password verbatim.
    final password = _passwordController.text;

    setState(() => _submitting = true);
    try {
      final account = await ref.read(adminUserRepositoryProvider).createAccount(
            email: email,
            password: password,
            fullName: fullName,
            role: _role,
          );
      if (!mounted) return;

      // The roster is the only proof the account exists, so refetch it rather
      // than insert a local row that the server might not agree with.
      ref.invalidate(managedAccountsProvider);

      // Clear the credentials, keep the role: several lecturers in a row is the
      // normal case.
      _formKey.currentState?.reset();
      _fullNameController.clear();
      _emailController.clear();
      _passwordController.clear();

      _showMessage(
        'Created ${account.displayName} as a ${account.role.label.toLowerCase()}. '
        'Hand over the temporary password, then have them change it.',
        isError: false,
      );
    } on AdminAccountException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _changeRole(ManagedAccount account, UserRole role) async {
    if (role == account.role || _busyId != null) return;

    setState(() => _busyId = account.id);
    try {
      await ref.read(adminUserRepositoryProvider).updateRole(
            userId: account.id,
            role: role,
          );
      if (!mounted) return;
      ref.invalidate(managedAccountsProvider);
      _showMessage(
        '${account.displayName} is now a ${role.label.toLowerCase()}.',
        isError: false,
      );
    } on AdminAccountException catch (error) {
      _showMessage(error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = SupabaseService.instance.currentUser?.email;
    final name = (widget.adminName ?? fallback ?? '').trim();
    final gutter = ResponsiveSizing.horizontalPadding(context);
    // Desktop / tablet landscape: the form and the roster side by side. Phones
    // stack them, form first — creating an account is the primary action.
    final sideBySide = ResponsiveSizing.isExpanded(context);

    final form = _CreateAccountCard(
      formKey: _formKey,
      fullNameController: _fullNameController,
      emailController: _emailController,
      passwordController: _passwordController,
      role: _role,
      submitting: _submitting,
      obscurePassword: _obscurePassword,
      onRoleChanged: (role) => setState(() => _role = role),
      onTogglePassword: () =>
          setState(() => _obscurePassword = !_obscurePassword),
      onSubmit: _createAccount,
      validateFullName: _validateFullName,
      validateEmail: _validateEmail,
      validatePassword: _validatePassword,
    );

    final roster = _RosterSection(
      selfId: _selfId,
      busyId: _busyId,
      onRefresh: () => ref.invalidate(managedAccountsProvider),
      onChangeRole: _changeRole,
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            key: const Key('admin-refresh'),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(managedAccountsProvider),
            icon: const Icon(Icons.refresh),
          ),
          if (widget.onSignOut != null)
            IconButton(
              key: const Key('admin-sign-out'),
              tooltip: 'Sign out',
              onPressed: widget.onSignOut,
              icon: const Icon(Icons.logout),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Welcome' : 'Welcome, $name',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Create staff or student accounts and manage the roles of the '
                  'ones that already exist.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: sideBySide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(gutter),
                          child: form,
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      // Scrolls on its own: on a laptop a large roster is taller
                      // than the window, and an unscrollable Column there would
                      // overflow instead of letting the admin reach the last row.
                      Expanded(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.all(gutter),
                          child: roster,
                        ),
                      ),
                    ],
                  )
                : ListView(
                    padding: EdgeInsets.all(gutter),
                    children: [
                      form,
                      const SizedBox(height: 24),
                      roster,
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// The "create an account" form.
///
/// Stateless and controller-injected: the page owns the text controllers, the
/// selected role and the submitting flag, this widget only renders them — the
/// same split as the login page, so a widget test can drive every branch
/// without a backend.
class _CreateAccountCard extends StatelessWidget {
  const _CreateAccountCard({
    required this.formKey,
    required this.fullNameController,
    required this.emailController,
    required this.passwordController,
    required this.role,
    required this.submitting,
    required this.obscurePassword,
    required this.onRoleChanged,
    required this.onTogglePassword,
    required this.onSubmit,
    required this.validateFullName,
    required this.validateEmail,
    required this.validatePassword,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController fullNameController;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final UserRole role;
  final bool submitting;
  final bool obscurePassword;
  final ValueChanged<UserRole> onRoleChanged;
  final VoidCallback onTogglePassword;
  final VoidCallback onSubmit;
  final FormFieldValidator<String> validateFullName;
  final FormFieldValidator<String> validateEmail;
  final FormFieldValidator<String> validatePassword;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.person_add_alt_1_outlined,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text('Create an account', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'The address is confirmed straight away, so the person can sign '
                'in with the password you set here.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('admin-full-name'),
                controller: fullNameController,
                enabled: !submitting,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  prefixIcon: Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: validateFullName,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('admin-email'),
                controller: emailController,
                enabled: !submitting,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.alternate_email),
                  border: OutlineInputBorder(),
                ),
                validator: validateEmail,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('admin-password'),
                controller: passwordController,
                enabled: !submitting,
                obscureText: obscurePassword,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Temporary password',
                  helperText: 'At least $adminMinPasswordLength characters.',
                  prefixIcon: const Icon(Icons.key_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    onPressed: submitting ? null : onTogglePassword,
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    tooltip:
                        obscurePassword ? 'Show password' : 'Hide password',
                  ),
                ),
                validator: validatePassword,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<UserRole>(
                key: const Key('admin-role'),
                // `initialValue`, not the deprecated `value`: the field owns the
                // selection the user taps, and the page re-renders it from
                // `role` whenever that changes.
                initialValue: role,
                decoration: const InputDecoration(
                  labelText: 'Role',
                  prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final value in UserRole.values)
                    DropdownMenuItem<UserRole>(
                      value: value,
                      child: Text(value.label),
                    ),
                ],
                onChanged: submitting
                    ? null
                    : (value) {
                        if (value != null) onRoleChanged(value);
                      },
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('admin-submit'),
                // Null while in flight: disabled is the first line of defence
                // against a double submit (see _createAccount).
                onPressed: submitting ? null : onSubmit,
                child: submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The account roster: every profile row the caller may read, each with the
/// menu that moves it to another role.
class _RosterSection extends ConsumerWidget {
  const _RosterSection({
    required this.selfId,
    required this.busyId,
    required this.onRefresh,
    required this.onChangeRole,
  });

  final String? selfId;
  final String? busyId;
  final VoidCallback onRefresh;
  final void Function(ManagedAccount account, UserRole role) onChangeRole;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accounts = ref.watch(managedAccountsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Accounts', style: theme.textTheme.titleMedium),
            const SizedBox(width: 8),
            accounts.maybeWhen(
              data: (rows) => Text(
                '(${rows.length})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('admin-reload-accounts'),
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Reload'),
            ),
          ],
        ),
        accounts.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => _RosterMessage(
            icon: Icons.error_outline,
            message: error is AdminAccountException
                ? error.message
                : 'Could not load the accounts.',
            onRetry: onRefresh,
          ),
          data: (rows) => rows.isEmpty
              ? const _RosterMessage(
                  icon: Icons.group_outlined,
                  message: 'No accounts to show yet.',
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final account in rows)
                      _AccountTile(
                        account: account,
                        isSelf: selfId != null && account.id == selfId,
                        busy: busyId == account.id,
                        onChangeRole: (role) => onChangeRole(account, role),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The empty/error state of the roster. Kept out of [ListTile] so a message is
/// never mistaken for an account.
class _RosterMessage extends StatelessWidget {
  const _RosterMessage({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(icon, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ],
      ),
    );
  }
}

/// One roster row: name, address, current role — and, for everybody but the
/// signed-in admin, the menu that moves them to another role.
class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isSelf,
    required this.busy,
    required this.onChangeRole,
  });

  final ManagedAccount account;

  /// The signed-in admin's own row: shown, but not editable (see [_selfId]).
  final bool isSelf;

  final bool busy;
  final ValueChanged<UserRole> onChangeRole;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      key: Key('admin-account-${account.id}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Text(_initials(account.displayName)),
      ),
      title: Text(account.displayName),
      // An unnamed account *is* its e-mail address, so do not print it twice.
      subtitle: account.displayName == account.email
          ? null
          : Text(account.email),
      trailing: busy
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : isSelf
              ? Tooltip(
                  message:
                      'You cannot change your own role — another admin has to.',
                  child: Chip(label: Text('${account.role.label} (you)')),
                )
              : PopupMenuButton<UserRole>(
                  key: Key('admin-role-${account.id}'),
                  tooltip: 'Change role',
                  onSelected: onChangeRole,
                  itemBuilder: (context) => [
                    for (final role in UserRole.values)
                      PopupMenuItem<UserRole>(
                        value: role,
                        // The current role is listed ticked but not selectable:
                        // picking it again would be a pointless round trip.
                        enabled: role != account.role,
                        child: Row(
                          children: [
                            Icon(
                              role == account.role
                                  ? Icons.check
                                  : Icons.circle_outlined,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(role.label),
                          ],
                        ),
                      ),
                  ],
                  child: Chip(
                    label: Text(account.role.label),
                    avatar: const Icon(Icons.expand_more, size: 18),
                  ),
                ),
    );
  }
}

/// "Dr. Ada Nwosu" -> "DN", "Bello" -> "B", and "?" for an unnamed row.
String _initials(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return '?';
  final first = words.first[0];
  return (words.length == 1 ? first : '$first${words.last[0]}').toUpperCase();
}
