import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/services/session_gate.dart';
import '../../../../core/services/supabase_service.dart';
import '../../../../core/utils/proctor_log.dart';

/// Key on the "signed out because another device signed in" message, so a test
/// can find it without matching the whole sentence.
const Key sessionSupersededMessageKey = Key('session-superseded-message');

/// Holds up the one-login rule from the client side (schema.sql §1b).
///
/// Three jobs, all of them about the *same* session:
///
/// 1. After a sign-in, ask the server to revoke the account's other refresh
///    tokens ([SupabaseService.signOutOtherDevices]). Not awaited: the sign-in is
///    already complete, and `signOut()` in this app is a *local* sign-out, so
///    without this an older device would keep a usable token.
/// 2. Claim the account's single active session for this device
///    ([SupabaseService.claimSession]). A refusal means another device signed in
///    later and this one is already locked out of every write, so it signs out
///    immediately instead of letting the student fill in an exam that cannot be
///    saved.
/// 3. Keep asking, every [sessionCheckInterval] and on every resume, whether
///    this token still holds the account (see [SessionGate]) — a superseded
///    device keeps a valid access token until `exp`, which is far too long for a
///    student to sit on a dead exam screen.
///
/// Placed directly under `MaterialApp`'s `home:` so the message it shows survives
/// the tree flipping back to the login page.
class SessionLiveness extends StatefulWidget {
  const SessionLiveness({
    super.key,
    required this.child,
    this.signedInChanges,
    this.signOutOtherDevices,
    this.claimSession,
    this.isCurrentSession,
    this.signOut,
    this.message = sessionSupersededMessage,
  });

  final Widget child;

  /// Signed-in status; defaults to [SupabaseService.signedInChanges].
  final Stream<bool>? signedInChanges;

  /// Defaults to [SupabaseService.signOutOtherDevices].
  final Future<AuthOutcome> Function()? signOutOtherDevices;

  /// Defaults to [SupabaseService.claimSession].
  final Future<SessionClaim> Function({String? deviceLabel})? claimSession;

  /// Defaults to [SupabaseService.isCurrentSession] — the polled question.
  final Future<bool?> Function()? isCurrentSession;

  /// The **local** sign-out used when this device loses the account; defaults to
  /// [SupabaseService.signOut].
  final Future<AuthOutcome> Function()? signOut;

  /// What the student is told. A signed-out device cannot retry, so the message
  /// has to explain why they are back at the login screen.
  final String message;

  @override
  State<SessionLiveness> createState() => _SessionLivenessState();
}

class _SessionLivenessState extends State<SessionLiveness> {
  late final SessionGate _gate;
  StreamSubscription<bool>? _authChanges;
  AppLifecycleListener? _lifecycle;

  /// What the last auth event said. A token refresh re-emits the same `true`,
  /// and that must not re-claim the session or restart the poll.
  bool _signedIn = false;

  @override
  void initState() {
    super.initState();

    // The overrides are read through `widget` at call time rather than captured,
    // so a parent that rebuilds with a different fake is honoured.
    _gate = SessionGate(
      isCurrent: () =>
          (widget.isCurrentSession ?? SupabaseService.instance.isCurrentSession)(),
      onSuperseded: _onSuperseded,
    );
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _authChanges =
        (widget.signedInChanges ?? SupabaseService.instance.signedInChanges)
            .listen(_onAuthChanged);
  }

  @override
  void dispose() {
    unawaited(_authChanges?.cancel());
    _authChanges = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _gate.dispose();
    super.dispose();
  }

  Future<AuthOutcome> _requestSignOutOthers() =>
      (widget.signOutOtherDevices ??
          SupabaseService.instance.signOutOtherDevices)();

  Future<SessionClaim> _requestClaim(String? deviceLabel) =>
      (widget.claimSession ?? SupabaseService.instance.claimSession)(
        deviceLabel: deviceLabel,
      );

  Future<AuthOutcome> _requestSignOut() =>
      (widget.signOut ?? SupabaseService.instance.signOut)();

  void _onAuthChanged(bool signedIn) {
    if (!mounted) return;
    final wasSignedIn = _signedIn;
    _signedIn = signedIn;

    if (!signedIn) {
      // Signed out by the student, or by this widget. Either way there is no
      // session left to police.
      _gate.stop();
      return;
    }
    if (wasSignedIn) return; // a refresh, not a new sign-in
    unawaited(_onSignedIn());
  }

  Future<void> _onSignedIn() async {
    unawaited(_requestSignOutOthers());

    final claim = await _requestClaim(sessionDeviceLabel());
    if (!mounted || !_signedIn) return;

    if (!claim.accepted) {
      // Another device signed in later (ordering is by token `iat`), so this one
      // is already refused on every write: sign out now rather than at the first
      // answer the student tries to save.
      await _onSuperseded();
      return;
    }
    _gate.start();
  }

  void _onResume() {
    if (!mounted || !_signedIn) return;
    // The app may have been in the background for hours, which is exactly when
    // another device signs in: ask before the student touches anything.
    unawaited(_gate.check());
  }

  Future<void> _onSuperseded() async {
    _gate.stop();
    final outcome = await _requestSignOut();
    if (!outcome.ok) {
      proctorLog('SessionLiveness: local sign-out failed: ${outcome.message}');
    }
    if (!mounted) return;

    // `signOut()` above is a local sign-out, so the tree is already heading back
    // to the login page; the root messenger is what keeps the explanation on
    // screen across that flip.
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(widget.message, key: sessionSupersededMessageKey),
          duration: const Duration(seconds: 8),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
