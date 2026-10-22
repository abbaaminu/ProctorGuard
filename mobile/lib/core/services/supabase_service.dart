import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show kIsWeb, visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/proctor_log.dart';

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
      proctorLog('SupabaseService: initialisation failed: $error\n$stackTrace');
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
      proctorLog('SupabaseService: $what failed: $error\n$stackTrace');
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
  /// being logged or the 3-strike escalation from running.
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

