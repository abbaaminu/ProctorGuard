import 'dart:math';

/// Randomness behind [uuidV4]. `Random.secure()` is what the platform CSPRNG
/// exposes on web (crypto.getRandomValues) and on mobile/desktop alike.
final Random _secureRandom = Random.secure();

/// A version-4 (random) UUID in the canonical `8-4-4-4-12` hex form.
///
/// Why hand-rolled instead of the `uuid` package: the only identifier this app
/// has to mint is one per proctoring violation, and its job is narrow - it is the
/// **idempotency key** that lets `OfflineSyncService` retry a violation whose
/// network call failed without double-counting the strike server-side
/// (`proctoring_logs.client_event_id`). A dozen dependency-free lines, Wasm-safe
/// and testable, beat a package for that.
///
/// [random] is injectable so tests can pin the shape instead of the value.
String uuidV4([Random? random]) {
  final rng = random ?? _secureRandom;
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256), growable: false);

  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant (10xx)

  final hex =
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
