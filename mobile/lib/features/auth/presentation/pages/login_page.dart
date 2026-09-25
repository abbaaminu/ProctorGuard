import 'package:flutter/material.dart';

import '../../../../core/services/supabase_service.dart';
import '../../../../core/widgets/responsive_layout.dart';

/// Signature of the auth call the form performs.
///
/// Injected rather than reached for through the singleton, so widget tests can
/// drive every branch (success, wrong password, timeout) without a backend —
/// the same reason the exam page's dependencies are injectable.
typedef SignInRequest = Future<AuthOutcome> Function({
  required String email,
  required String password,
});

/// Email/password sign-in for students and supervisors.
///
/// The call goes through [SupabaseService.signInWithPassword], which performs
/// the actual `auth.signInWithPassword(email:, password:)` and converts every
/// failure mode (wrong password, unconfirmed email, offline, browser storage
/// refused) into an [AuthOutcome] instead of an exception. That message is what
/// the error SnackBar shows.
///
/// Success needs no navigation: the caller (`_RoleGate` in `main.dart`) listens
/// to [SupabaseService.signedInChanges] and swaps this screen for the role home
/// as soon as the session exists.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.signIn});

  /// Overridable for tests; defaults to the Supabase-backed implementation.
  final SignInRequest? signIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _submitting = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String? _validateEmail(String? value) =>
      (value ?? '').trim().isEmpty ? 'Enter your email address' : null;

  String? _validatePassword(String? value) =>
      (value ?? '').trim().isEmpty ? 'Enter your password' : null;

  Future<void> _signIn() async {
    if (_submitting) return; // a double tap must not fire two sign-ins
    if (!(_formKey.currentState?.validate() ?? false)) return;

    // Both fields are trimmed before the call: mobile keyboards happily append
    // a trailing space, and the server compares them verbatim.
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    setState(() => _submitting = true);
    try {
      final outcome = await (widget.signIn ??
          SupabaseService.instance.signInWithPassword)(
        email: email,
        password: password,
      );
      if (!mounted) return;
      if (!outcome.ok) {
        _showMessage(_friendly(outcome.message));
        return;
      }
      _showMessage('Signed in as $email', isError: false);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// Supabase's raw messages, phrased for a student. The credential failure is
  /// deliberately the same for "no such user" and "wrong password" — that is
  /// what the server returns, and it should not become an oracle for which
  /// emails are registered.
  static String _friendly(String? message) {
    final text = (message ?? '').trim();
    if (text.isEmpty) {
      return 'Sign-in failed. Check your email and password and try again.';
    }
    final lower = text.toLowerCase();
    if (lower.contains('invalid login credentials')) {
      return 'Incorrect email or password.';
    }
    if (lower.contains('email not confirmed')) {
      return 'Confirm your email address first — check your inbox for the link.';
    }
    return text;
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
        duration: Duration(seconds: isError ? 6 : 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A larger brand mark once the viewport is wider than a large phone.
    final wide =
        ResponsiveSizing.viewportOf(context).width >= Breakpoints.medium;

    return Scaffold(
      // `ResponsiveScrollView` replaces the old
      // `Center > SingleChildScrollView > ConstrainedBox(maxWidth: 420)`: it
      // fills the viewport (no wasted top gap), scrolls as soon as the on-screen
      // keyboard or a short landscape window makes the form taller than the
      // screen, and clamps the form to a readable column instead of stretching a
      // phone layout across a monitor. Gutters grow with the viewport.
      body: SafeArea(
        child: ResponsiveScrollView(
          maxWidth: 440,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.school_outlined,
                  size: wide ? 64 : 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 12),
                Text(
                  'Exam Proctor',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Sign in to take or supervise an exam',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  key: const Key('login-email'),
                  controller: _emailController,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.alternate_email),
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateEmail,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('login-password'),
                  controller: _passwordController,
                  enabled: !_submitting,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      // Exam passwords get typed on phones: let the student
                      // check what they typed before submitting.
                      onPressed: _submitting
                          ? null
                          : () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      tooltip: _obscurePassword
                          ? 'Show password'
                          : 'Hide password',
                    ),
                  ),
                  validator: _validatePassword,
                  onFieldSubmitted: (_) => _signIn(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('login-submit'),
                  // Null while in flight: disabled is the first line of
                  // defence against a double submit (see _signIn).
                  onPressed: _submitting ? null : _signIn,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Sign in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
