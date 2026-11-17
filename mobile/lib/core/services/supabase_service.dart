import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show kIsWeb, visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'crash_reporting.dart';
import '../utils/proctor_log.dart';
import '../utils/read_timeout.dart';

/// Contract for the evidence uploader that the proctoring notifier depends on.
///
/// Declared here (rather than passing the singleton around) so the notifier
/// can be unit-tested with a fake and stays free of Supabase wiring.
///
/// Returns the snapshot's **storage path** inside
/// [SupabaseService.snapshotBucket] (`<submissionId>/<actionType>_<epochMs>.jpg`),
/// not a URL: the bucket is private, so a URL has to be minted when somebody
/// authorized actually looks at the still (see
/// [SupabaseService.signedSnapshotUrl]).
typedef SnapshotUploader = Future<String?> Function({
  required String submissionId,
  required String actionType,
  required Uint8List bytes,
});

/// Supabase connection settings, resolved from compile-time `--dart-define`
/// values — the only configuration mechanism that also works on Flutter Web,
/// where there is no `.env` file to read at runtime.
class SupabaseConfig {
  const SupabaseConfig({required this.url, required this.publishableKey});

  final String url;
  final String publishableKey;

  /// Reads `--dart-define=SUPABASE_URL` and
  /// `--dart-define=SUPABASE_PUBLISHABLE_KEY`, falling back to the legacy
  /// `SUPABASE_ANON_KEY` name, and returns null when the build wasn't
  /// configured.
  ///
  /// Returning null instead of forwarding empty strings matters:
  /// `Supabase.initialize` asserts on a missing key, and an assertion failure
  /// before `runApp` is precisely the blank-page startup failure this guards
  /// against.
  static SupabaseConfig? fromEnvironment() => resolveFromEnvironment().config;

  /// [fromEnvironment] with the rejection reason kept, which is what
  /// `SupabaseService.init` reports to the setup screen.
  static SupabaseConfigResolution resolveFromEnvironment() => resolveFromValues(
        url: const String.fromEnvironment('SUPABASE_URL'),
        publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
        anonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
      );

  /// Same fallback order as [fromEnvironment] with the values injected, so the
  /// precedence is testable — compile-time defines cannot be faked at runtime.
  static SupabaseConfig? fromValues({
    required String url,
    required String publishableKey,
    required String anonKey,
  }) =>
      resolveFromValues(
        url: url,
        publishableKey: publishableKey,
        anonKey: anonKey,
      ).config;

  /// [fromValues] with the rejection reason kept. One implementation, so the
  /// key-precedence rule cannot drift between the two.
  static SupabaseConfigResolution resolveFromValues({
    required String url,
    required String publishableKey,
    required String anonKey,
  }) =>
      resolveWithReason(
        url: url,
        publishableKey:
            publishableKey.trim().isEmpty ? anonKey : publishableKey,
      );

  /// Validation rules, kept separate from [fromEnvironment] so they can be
  /// unit-tested without compile-time defines.
  ///
  /// Returns null for every rejection; [resolveWithReason] is the same call with
  /// the *reason* attached.
  static SupabaseConfig? resolve({
    required String url,
    required String publishableKey,
  }) =>
      resolveWithReason(url: url, publishableKey: publishableKey).config;

  /// [resolve], with the rejection reason kept.
  ///
  /// The reason exists because every rejection used to produce the same
  /// sentence — "no URL/key, or they are still placeholders" — which is wrong
  /// (and unactionable) for a build that *did* set both, but over `http://`. That
  /// is the case this whole validator is here for: a plain-http URL sends the
  /// publishable key and the student's access token in clear text on every
  /// request, so it is refused rather than quietly used.
  static SupabaseConfigResolution resolveWithReason({
    required String url,
    required String publishableKey,
  }) {
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final cleanKey = publishableKey.trim();

    if (!_isUsable(cleanUrl)) {
      return const SupabaseConfigResolution.rejected(
        'SUPABASE_URL is empty or still the placeholder from the docs.',
      );
    }
    if (!_isUsable(cleanKey)) {
      return const SupabaseConfigResolution.rejected(
        'SUPABASE_PUBLISHABLE_KEY is empty or still the placeholder from the '
        'docs.',
      );
    }

    final uri = Uri.tryParse(cleanUrl);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      return const SupabaseConfigResolution.rejected(
        'SUPABASE_URL must be an absolute origin such as '
        'https://<project-ref>.supabase.co.',
      );
    }
    if (!_isSecureOrigin(uri)) {
      return const SupabaseConfigResolution.rejected(
        'SUPABASE_URL must be https:// - a plain http:// origin sends the '
        'publishable key and the exam session token in clear text over a network '
        'the school does not control. A loopback development server (localhost, '
        '127.0.0.1, or the Android emulator host 10.0.2.2) is the only exception.',
      );
    }

    return SupabaseConfigResolution.ready(
      SupabaseConfig(url: cleanUrl, publishableKey: cleanKey),
    );
  }

  /// Whether [uri] is an origin the app may send credentials to (see
  /// [resolveWithReason]): https anywhere, http only on this machine.
  static bool _isSecureOrigin(Uri uri) {
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    return _isLoopbackHost(uri.host);
  }

  /// True for the hosts that *are* this machine: a local `supabase start` stack,
  /// or the Android emulator's alias for the host's loopback (`10.0.2.2`).
  ///
  /// Spelled out rather than resolved through `dart:io`'s `InternetAddress`,
  /// because this file is compiled for the web as well and `dart:io` does not
  /// exist there.
  static bool _isLoopbackHost(String host) {
    // `Uri.host` keeps IPv6 in brackets on some platforms and not others.
    final lower = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
    return lower == 'localhost' ||
        lower == '::1' ||
        lower == '10.0.2.2' ||
        lower.startsWith('127.');
  }

  /// Rejects empty values and the placeholders copied out of docs/examples, so
  /// a half-filled command fails loudly at boot instead of pointing silently at
  /// `https://your-project.supabase.co`.
  static bool _isUsable(String value) {
    if (value.isEmpty) return false;
    final lower = value.toLowerCase();
    const placeholders = [
      'your-project',
      'your-anon-key',
      'your-publishable-key',
      'your_url',
      'your_key',
      'replace-me',
      'changeme',
    ];
    for (final placeholder in placeholders) {
      if (lower.contains(placeholder)) return false;
    }
    return true;
  }

  /// Key the SDK persists the session under, matching supabase_flutter's own
  /// default (`sb-<project-ref>-auth-token`) so existing sessions keep working.
  String get sessionKey {
    final host = Uri.tryParse(url)?.host ?? '';
    return 'sb-${host.split('.').first}-auth-token';
  }

  /// Unknown leftovers for the startup screen: never log the key itself.
  @override
  String toString() => 'SupabaseConfig($url, key: ${publishableKey.length} chars)';
}

/// The outcome of validating a build's Supabase settings: either a usable
/// [config], or the [reason] the build was refused.
///
/// Both halves matter at boot. `status` alone cannot explain itself (a missing
/// URL, a placeholder key and an `http://` origin all end up "not configured"),
/// and the setup screen has to tell a deployer which of the three they are
/// looking at.
class SupabaseConfigResolution {
  const SupabaseConfigResolution.ready(SupabaseConfig this.config) : reason = null;

  const SupabaseConfigResolution.rejected(String this.reason) : config = null;

  final SupabaseConfig? config;
  final String? reason;

  bool get isReady => config != null;
}

/// How far initialisation got, so the UI can explain itself instead of showing
/// a blank screen.
enum SupabaseInitStatus { ready, notConfigured, failed }

/// Outcome of an auth call, so UI code never has to catch platform, storage or
/// network exceptions itself.
class AuthOutcome {
  const AuthOutcome.success()
      : ok = true,
        message = null;
  const AuthOutcome.failure(this.message) : ok = false;

  final bool ok;
  final String? message;
}

/// What `claim_session()` answered (schema.sql §1b).
///
/// Three states, because "the server refused this device" and "the server could
/// not be asked" must not be the same thing: only [accepted] `false` signs a
/// device out. A transient failure, an old token without a `session_id` claim, or
/// a project that has not run `20261111090000_single_session.sql` yet all come
/// back [measured] `false` and are treated as "carry on", which mirrors the way
/// the SQL gate fails open.
class SessionClaim {
  const SessionClaim._({
    required this.accepted,
    required this.measured,
    this.activeSessionId,
    this.claimedAt,
    this.replacedSessionId,
  });

  /// Nobody was asked (or the answer was unreadable): carry on.
  const SessionClaim.unmeasured() : this._(accepted: true, measured: false);

  /// Reads the single row a `setof` RPC returns. Anything unexpected — an empty
  /// array, a missing `accepted` column, a project where the function is not
  /// deployed — degrades to [SessionClaim.unmeasured] rather than guessing.
  factory SessionClaim.fromRpc(dynamic response) {
    if (response is! List || response.isEmpty) {
      return const SessionClaim.unmeasured();
    }
    final row = response.first;
    if (row is! Map) return const SessionClaim.unmeasured();
    final accepted = row['accepted'];
    if (accepted is! bool) return const SessionClaim.unmeasured();
    final claimedAt = row['claimed_at'];
    return SessionClaim._(
      accepted: accepted,
      measured: true,
      activeSessionId: row['active_session_id'] as String?,
      claimedAt: claimedAt is String
          ? DateTime.tryParse(claimedAt)
          : claimedAt is DateTime
              ? claimedAt
              : null,
      replacedSessionId: row['replaced_session_id'] as String?,
    );
  }

  /// Whether this device now holds the account's single active session.
  final bool accepted;

  /// Whether the server actually answered. `false` means "unknown", not "no".
  final bool measured;

  /// The session id that holds the account — this device's when [accepted].
  final String? activeSessionId;

  /// When that session took the account (server clock); kept across a re-claim.
  final DateTime? claimedAt;

  /// The session this claim displaced, null on a first claim or a repeat.
  final String? replacedSessionId;
}

/// The server refused a write because a newer sign-in holds the account
/// (`PT409`, schema.sql §1b) — the device was superseded, not disconnected.
///
/// Distinct from an offline failure on purpose: retrying will never succeed, and
/// the student has to sign in again, so the queue stops retrying it.
class SessionSupersededException implements Exception {
  const SessionSupersededException();

  @override
  String toString() => sessionSupersededMessage;
}

/// What a device that lost the account is told before it is signed out.
const String sessionSupersededMessage =
    'You signed in on another device, so this one has been signed out.';

/// Thin wrapper around the Supabase client so the rest of the app never
/// imports `supabase_flutter` directly (keeps the data layer swappable and
/// testable).
///
/// Web notes: [init] resolves `--dart-define` values and never throws, because a
/// startup exception in a browser is a blank page; the SDK touches
/// `window.localStorage` while initialising and browsers can refuse that
/// (private mode, partitioned storage, sandboxed iframes), so the storage is
/// probed first and persistence is turned off deliberately when it is missing.
/// Auth callbacks arrive in the URL; PKCE plus `detectSessionInUri` exchange
/// them for a session and the SDK then clears the parameters.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  /// Private bucket holding violation snapshots (see schema.sql §6).
  ///
  /// Private on purpose: a snapshot is a photograph of a student's face, and a
  /// public bucket makes every stored still readable by anyone who ever sees a
  /// link - including one scraped out of a log export or a screenshot of the
  /// console. Storage serves nothing from it without a signature; the app mints
  /// one on demand ([signedSnapshotUrl]) and the RLS policy on
  /// `storage.objects` still decides who may ask.
  static const String snapshotBucket = 'proctor-snapshots';

  /// How long a minted snapshot URL stays valid.
  ///
  /// Minutes, not days: long enough for a supervisor to open the still they just
  /// clicked, short enough that a leaked URL is worthless by the time anyone
  /// finds it. A URL is only ever a view of the object - the object itself is
  /// still behind the bucket's policy, and a fresh one can be minted at any
  /// time by anyone the policy admits.
  static const Duration snapshotUrlTtl = Duration(minutes: 10);

  SupabaseClient? _client;
  SupabaseInitStatus _status = SupabaseInitStatus.notConfigured;
  String? _initError;
  bool _canPersistSession = true;

  /// The origin [_client] was built for, so [init] can tell a repeat call (fine)
  /// from a second backend (refused). Null while there is no client.
  String? _initialisedUrl;

  StreamSubscription<AuthState>? _authSubscription;
  final StreamController<AuthState> _authStates =
      StreamController<AuthState>.broadcast();

  /// Whether [init] produced a usable client.
  bool get isReady => _client != null;

  SupabaseInitStatus get status => _status;

  /// Readable reason when [status] isn't [SupabaseInitStatus.ready].
  String? get initError => _initError;

  /// False when the runtime refused local storage: sessions are in-memory only,
  /// so a browser refresh signs the user out (everything else still works).
  bool get sessionPersistenceAvailable => _canPersistSession;

  /// The client, or null when the app booted without a backend. Startup paths
  /// must use this — the former `late final client` threw
  /// `LateInitializationError` whenever configuration was missing.
  SupabaseClient? get clientOrNull => _client;

  /// The client, for code that genuinely cannot work without one.
  SupabaseClient get client {
    final client = _client;
    if (client == null) {
      throw StateError(
        'Supabase client unavailable ($_status): ${_initError ?? 'not configured'}',
      );
    }
    return client;
  }

  User? get currentUser => _client?.auth.currentUser;
  String? get currentUserId => _client?.auth.currentUser?.id;
  Session? get currentSession => _client?.auth.currentSession;
  bool get isSignedIn => currentUser != null;

  /// Auth events; stream errors are logged rather than forwarded.
  Stream<AuthState> get authStateChanges => _authStates.stream;

  /// Signed-in status, re-emitted on every auth event — including the session
  /// the SDK restores from storage after a browser refresh. Typed `bool` so
  /// widgets do not need to import `supabase_flutter`.
  Stream<bool> get signedInChanges async* {
    yield isSignedIn;
    await for (final _ in _authStates.stream) {
      yield isSignedIn;
    }
  }

  /// Redirect target for web/OAuth flows: the origin the app is served from.
  /// Register it under Authentication → URL Configuration → Redirect URLs.
  String? get authRedirectUrl => kIsWeb ? Uri.base.origin : null;

  /// Initialises the client. **Never throws**: failures surface through
  /// [status] and [initError] so `main()` keeps booting and the UI can explain
  /// them.
  ///
  /// Idempotent. A second call reports the status already reached instead of
  /// re-running the boot: `Supabase.initialize` returns the instance it built the
  /// first time, so re-initialising cannot produce a *new* backend, and a call
  /// naming a different URL is refused loudly rather than silently re-pointing a
  /// running app whose repositories are already bound to the first client.
  Future<SupabaseInitStatus> init({SupabaseConfig? config}) async {
    final resolution = config != null
        ? SupabaseConfigResolution.ready(config)
        : SupabaseConfig.resolveFromEnvironment();
    final settings = resolution.config;

    if (settings == null) {
      _status = SupabaseInitStatus.notConfigured;
      // The validator's own words: "not configured" covers a missing URL, a
      // placeholder key *and* a plain-http origin, and only the reason tells a
      // deployer which one to fix.
      _initError = resolution.reason ??
          'No SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY in this build.';
      proctorLog('SupabaseService: $_initError');
      return _status;
    }

    if (_client != null) {
      if (_initialisedUrl != null && _initialisedUrl != settings.url) {
        proctorLog(
          'SupabaseService: already initialised against $_initialisedUrl; '
          'ignoring a second init for ${settings.url}.',
        );
      }
      return _status;
    }

    _canPersistSession = await _probeSessionStorage(settings);

    try {
      final app = await Supabase.initialize(
        url: settings.url,
        publishableKey: settings.publishableKey,
        authOptions: FlutterAuthClientOptions(
          // PKCE keeps tokens out of the URL fragment while still handling the
          // `?code=...` / `#access_token=...` callbacks a provider sends back.
          authFlowType: AuthFlowType.pkce,
          detectSessionInUri: true,
          persistSession: _canPersistSession,
          // With storage blocked the default stores throw, so keep the PKCE
          // verifier in memory for this tab.
          pkceAsyncStorage: _canPersistSession ? null : _MemoryAsyncStorage(),
        ),
        realtimeClientOptions: const RealtimeClientOptions(eventsPerSecond: 10),
      );

      _client = app.client;
      _initialisedUrl = settings.url;
      _status = SupabaseInitStatus.ready;
      _initError = null;
      _listenToAuthState();
      proctorLog('SupabaseService: ready at ${settings.url} '
          '(session persistence: $_canPersistSession)');
    } catch (error, stackTrace) {
      _client = null;
      _status = SupabaseInitStatus.failed;
      _initError = error.toString();
      await CrashReporting.captureException(
        error,
        stackTrace,
        context: 'SupabaseService initialization failed',
      );
    }
    return _status;
  }

  /// Reads through the same storage the SDK uses during initialisation, so a
  /// browser that refuses it is detected *before* it can abort startup.
  static Future<bool> _probeSessionStorage(SupabaseConfig settings) async {
    if (!kIsWeb) return true; // mobile/desktop storage is reliable

    try {
      final storage = SharedPreferencesLocalStorage(
        persistSessionKey: settings.sessionKey,
      );
      await storage.initialize();
      await storage.hasAccessToken(); // blocked storage throws right here
      return true;
    } catch (error) {
      proctorLog('SupabaseService: browser storage unavailable ($error) — '
          'continuing without session persistence.');
      return false;
    }
  }

  /// Signs in with email/password. Every failure mode (wrong password,
  /// unconfirmed email, offline, blocked storage) comes back as an
  /// [AuthOutcome] instead of an exception at the call site.
  Future<AuthOutcome> signInWithPassword({
    required String email,
    required String password,
  }) =>
      _guardAuth('sign-in', () async {
        final auth = _client?.auth;
        if (auth == null) return _notConfigured;
        await auth.signInWithPassword(email: email.trim(), password: password);
        return const AuthOutcome.success();
      });

  /// Emails a magic link / OTP that returns to [redirectTo] (defaults to the
  /// web origin — see [authRedirectUrl]).
  Future<AuthOutcome> sendMagicLink({
    required String email,
    String? redirectTo,
  }) =>
      _guardAuth('magic link', () async {
        final auth = _client?.auth;
        if (auth == null) return _notConfigured;
        await auth.signInWithOtp(
          email: email.trim(),
          emailRedirectTo: redirectTo ?? authRedirectUrl,
        );
        return const AuthOutcome.success();
      });

  /// Re-validates the persisted session (browser refresh, stale token) without
  /// throwing: a failed refresh just means "not signed in any more".
  Future<AuthOutcome> refreshSession() =>
      _guardAuth('session refresh', () async {
        final auth = _client?.auth;
        if (auth == null) return _notConfigured;
        final response = await auth.refreshSession();
        return response.session == null
            ? const AuthOutcome.failure('Session expired — please sign in again.')
            : const AuthOutcome.success();
      });

  Future<AuthOutcome> signOut() =>
      _guardAuth('sign-out', () async {
        final auth = _client?.auth;
        if (auth == null) return _notConfigured;
        await auth.signOut();
        return const AuthOutcome.success();
      });

  /// Revokes every *other* device's session for this account, keeping this one.
  ///
  /// [signOut] is a local sign-out, so without this a second device leaves the
  /// first one holding a refresh token it can still spend. Called right after a
  /// sign-in completes and deliberately **not awaited** there: the sign-in is
  /// already over, and a slower round trip must not hold up the role gate. The
  /// authoritative half of "one login per account" is the `active_sessions` gate
  /// in schema.sql §1b, which works even if this call fails.
  Future<AuthOutcome> signOutOtherDevices() =>
      _guardAuth('sign-out of other devices', () async {
        final auth = _client?.auth;
        if (auth == null) return _notConfigured;
        await auth.signOut(scope: SignOutScope.others);
        return const AuthOutcome.success();
      });

  /// Claims the account's single active session for this device (schema.sql
  /// §1b): the server answers whether this token still holds the account.
  ///
  /// Never throws, and never returns a hard "no" it cannot back up — a project
  /// without the migration (`PGRST202`), a token with no `session_id` claim
  /// (`22023`), a dropped connection or a request still unanswered after
  /// [defaultReadTimeout] all come back [SessionClaim.unmeasured]. Only an
  /// explicit `false` means another device signed in later and this one has to go.
  ///
  /// The deadline matters more here than it does for a page read: the widget that
  /// calls this starts its 30-second watch only once the attempt has settled, so
  /// an answer that never arrives used to mean an account nobody was watching.
  Future<SessionClaim> claimSession({String? deviceLabel}) async {
    final client = _client;
    if (client == null) return const SessionClaim.unmeasured();
    try {
      // One row, answered in milliseconds when the stack is healthy, and safe to
      // ask again for the same session (`claim_session` is idempotent for a token
      // that already holds the account), so an abandoned request costs nothing.
      final response = await withReadTimeout(
        () => client.rpc(
          'claim_session',
          params: {'p_device_label': deviceLabel},
        ),
        timeout: _sessionReadTimeout,
      );
      return SessionClaim.fromRpc(response);
    } on PostgrestException catch (error) {
      // A project that has not had
      // `supabase/migrations/20261111090000_single_session.sql` applied answers
      // `PGRST202`/`42883` here, and a token the auth server did not mint a
      // `session_id` for raises `22023`. Neither is a reason to lock a student out
      // of an exam, so both are reported and carried on from - but the first one
      // means nothing on this project enforces the rule until the migration is
      // applied, which is exactly what this line is for.
      final undeployed = error.code == 'PGRST202' || error.code == '42883';
      proctorLog(
        'SupabaseService: claim_session answered ${error.code}'
        '${undeployed ? ' - supabase/migrations/20261111090000_single_session.sql '
            'is not applied to this project, so no session is claimed' : ''}'
        ' (${error.message})',
      );
      return const SessionClaim.unmeasured();
    } catch (error) {
      proctorLog('SupabaseService: claim_session failed: $error');
      return const SessionClaim.unmeasured();
    }
  }

  /// Asks the server whether this token still holds the account (§1b).
  ///
  /// `null` means "could not ask" — no client, offline, an answer that did not
  /// arrive within [defaultReadTimeout], or the function is not deployed — and
  /// every caller treats that as "carry on", exactly like the SQL gate does for a
  /// request with no claim row.
  Future<bool?> isCurrentSession() async {
    final client = _client;
    if (client == null) return null;
    try {
      // A `null`, an empty body or a project answering something else entirely is
      // "could not ask", never "no": the gate signs a device out on `false` alone.
      // The deadline is shorter than the gate's own 30-second poll, so a dead
      // socket loses its turn instead of holding the next one shut.
      final response = await withReadTimeout(
        () => client.rpc('is_current_session'),
        timeout: _sessionReadTimeout,
      );
      return response is bool ? response : null;
    } catch (error) {
      proctorLog('SupabaseService: is_current_session unavailable: $error');
      return null;
    }
  }

  static const AuthOutcome _notConfigured =
      AuthOutcome.failure('Backend not configured — see the setup screen.');

  /// Single safety net for auth calls: platform, channel and storage failures
  /// become [AuthOutcome.failure] instead of crashing the UI — which is what
  /// used to happen on web when storage was restricted.
  Future<AuthOutcome> _guardAuth(
    String what,
    Future<AuthOutcome> Function() action,
  ) async {
    try {
      return await action();
    } on AuthException catch (error) {
      return AuthOutcome.failure(error.message); // expected, user-actionable
    } catch (error, stackTrace) {
      await CrashReporting.captureException(
        error,
        stackTrace,
        context: 'SupabaseService $what failed unexpectedly',
      );
      return AuthOutcome.failure(
        '$what failed. Check your connection and try again.',
      );
    }
  }

  /// Wires the singleton's public auth stream to the SDK's.
  ///
  /// Called on every successful [init] and replaces any previous subscription
  /// instead of stacking a second one on the same controller (which would make
  /// every event appear twice). After [dispose] the stream is closed, so there is
  /// nothing left to wire.
  void _listenToAuthState() {
    final auth = _client?.auth;
    if (auth == null) return;
    if (_authStates.isClosed) return; // disposed: the stream is gone

    // Not awaited: this is a synchronous teardown of the previous listener, and
    // `init` must not be able to hang on a client that is going away.
    unawaited(_authSubscription?.cancel());
    _authSubscription = listenToAuthState(
      auth.onAuthStateChange,
      onState: (state) {
        proctorLog('SupabaseService: auth event ${state.event.name}');
        if (!_authStates.isClosed) _authStates.add(state);
      },
      onError: (error) =>
          proctorLog('SupabaseService: auth stream error: $error'),
    );
  }

  /// Wires an auth-state stream defensively: errors go to [onError] and the
  /// subscription keeps listening (`cancelOnError: false`), so a failed token
  /// refresh after a long offline period cannot surface as an unhandled stream
  /// error — a genuine web crash source. Extracted so the contract is testable
  /// without a live client.
  @visibleForTesting
  static StreamSubscription<AuthState> listenToAuthState(
    Stream<AuthState> stream, {
    required void Function(AuthState state) onState,
    required void Function(Object error) onError,
  }) =>
      stream.listen(
        onState,
        onError: (Object error, StackTrace _) => onError(error),
        cancelOnError: false,
      );

  /// How long [claimSession] and [isCurrentSession] wait for an answer.
  ///
  /// A field rather than the constant alone for the reason `read_timeout.dart`
  /// gives: a test that has to wait twelve seconds to watch a deadline fire is a
  /// test nobody runs. Null everywhere but a test, where the default applies.
  @visibleForTesting
  Duration? debugSessionReadTimeout;

  Duration get _sessionReadTimeout =>
      debugSessionReadTimeout ?? defaultReadTimeout;

  /// Points the singleton at a client built over a fake HTTP transport so tests
  /// can assert the exact PostgREST/Storage payloads. Production code must never
  /// call this.
  @visibleForTesting
  void debugSetClient(SupabaseClient? client) {
    _client = client;
    // A double has no genesis origin, so a later `init` must not read it as
    // "already initialised against <url>" (see [init]).
    _initialisedUrl = null;
    _status = client == null
        ? SupabaseInitStatus.notConfigured
        : SupabaseInitStatus.ready;
  }

  /// Releases the auth listener; the singleton normally lives for the whole run,
  /// tests call this to avoid leaking subscriptions.
  ///
  /// The client itself is kept: disposing the SDK's client is the SDK's business,
  /// and [init] is documented to be a no-op once a client exists.
  Future<void> dispose() async {
    await _authSubscription?.cancel();
    _authSubscription = null;
    if (!_authStates.isClosed) await _authStates.close();
  }

  /// Path convention the Storage policies (and the supervisor console) rely on:
  /// `<submission_id>/<action_type>_<epoch-ms>.jpg`.
  ///
  /// Epoch-ms keeps the name unique per violation (the notifier already
  /// debounces to one log every ~2s) without pulling in a uuid package, and the
  /// first folder is the exact segment `proctor-snapshots` upload policies match
  /// against `exam_submissions.id`.
  static String snapshotPath({
    required String submissionId,
    required String actionType,
    DateTime? at,
  }) =>
      '$submissionId/${actionType}_${(at ?? DateTime.now()).millisecondsSinceEpoch}.jpg';

  /// The bucket-relative object path that a stored
  /// `proctoring_logs.snapshot_url` value points at.
  ///
  /// Rows written by this build hold the path itself (`<sub>/<file>.jpg`), because
  /// the bucket is private and a signed URL would expire long before the evidence
  /// is reviewed. Rows written while the bucket was public hold
  /// `/storage/v1/object/public/proctor-snapshots/<sub>/<file>.jpg`, and a
  /// console-minted one holds `/storage/v1/object/sign/...` with a token in the
  /// query - all three resolve to the same object here, which is what lets a
  /// pre-migration attempt still be purged, signed and reviewed.
  ///
  /// Returns `null` for anything that is not a snapshot reference: an empty
  /// string, a bare bucket name, a path with no folder, or a URL that belongs to
  /// somewhere else entirely (the dashboard used to write a placeholder one).
  static String? snapshotObjectPath(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return null;

    final segments = uri.pathSegments;
    // Both URL shapes carry the bucket as a *segment*, so the object is whatever
    // follows it - and the query string (a signed URL's token) is already gone by
    // the time `pathSegments` exists.
    final bucketIndex = segments.indexOf(snapshotBucket);
    if (bucketIndex >= 0) {
      return bucketIndex == segments.length - 1
          ? null
          : segments.skip(bucketIndex + 1).join('/');
    }

    // A bucket-relative path: no scheme, no host, and at least a folder and a
    // file. Anything else is a URL for a different bucket or no snapshot at all.
    if (uri.hasScheme || uri.hasAuthority || segments.length < 2) return null;
    return segments.join('/');
  }

  /// Uploads violation evidence as `<submissionId>/<actionType>_<epochMs>.jpg`
  /// into the private [snapshotBucket], and returns the **path** to store on the
  /// `proctoring_logs` row.
  ///
  /// The path layout is what the Storage policies key off: the first folder must
  /// be the submission id, and the policy only allows it while that submission
  /// is the caller's own and still `ongoing`.
  ///
  /// The return value is a path rather than a URL because the bucket is private
  /// and a signed URL is short-lived by design: the row has to outlive every URL
  /// minted from it, so it keeps the one identifier that never goes stale and the
  /// URL is produced when somebody actually reads the evidence
  /// ([signedSnapshotUrl]).
  ///
  /// Returns `null` — never throws — when the upload cannot happen (offline,
  /// policy rejection, quota): a missing picture must not stop the violation from
  /// being logged or the weighted escalation from running.
  Future<String?> uploadViolationSnapshot({
    required String submissionId,
    required String actionType,
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    if (bytes.isEmpty) return null;

    final client = _client;
    if (client == null) return null; // unconfigured build: nothing to upload to

    // Single source of truth for the path convention (see [snapshotPath]).
    final path = snapshotPath(
      submissionId: submissionId,
      actionType: actionType,
    );

    try {
      final storage = client.storage.from(snapshotBucket);
      await storage.uploadBinary(
        path,
        bytes,
        fileOptions: FileOptions(
          contentType: contentType,
          cacheControl: '3600', // evidence never changes; let the CDN hold it
        ),
      );
      return path;
    } catch (error) {
      proctorLog('Snapshot upload failed for $path: $error');
      return null;
    }
  }

  /// Mints a short-lived read URL for a snapshot this caller is allowed to see.
  ///
  /// [path] is a stored `snapshot_url` value: the object path
  /// [uploadViolationSnapshot] returned, or - for a row written before the bucket
  /// went private - a full `/object/public/...` URL. Both are normalised through
  /// [snapshotObjectPath], so the console and a reset keep working across the
  /// migration.
  ///
  /// The bucket's RLS policy is still the authority: this signs what the signed-in
  /// user may read (the owning student, or staff), and Storage refuses the rest.
  /// Returns `null` - never throws - when there is no client, the value is not a
  /// snapshot reference, or Storage refuses.
  Future<String?> signedSnapshotUrl(String path, {Duration? ttl}) async {
    final client = _client;
    if (client == null) return null;

    final object = snapshotObjectPath(path);
    if (object == null) return null;

    try {
      return await client.storage
          .from(snapshotBucket)
          .createSignedUrl(object, (ttl ?? snapshotUrlTtl).inSeconds);
    } catch (error) {
      proctorLog('Could not sign snapshot $object: $error');
      return null;
    }
  }
}

/// In-memory [GotrueAsyncStorage] for the PKCE code verifier, used only when the
/// runtime refuses local storage: keeps the redirect exchange working for this
/// tab instead of throwing.
class _MemoryAsyncStorage implements GotrueAsyncStorage {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> getItem({required String key}) async => _values[key];

  @override
  Future<void> setItem({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> removeItem({required String key}) async {
    _values.remove(key);
  }
}
