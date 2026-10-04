import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/proctor_log.dart';

/// The tiny async string store the offline layer persists through.
///
/// One interface, three reasons: `shared_preferences` is what production uses
/// (localStorage on web, SharedPreferences/NSUserDefaults on mobile), the memory
/// implementation is what tests use, and the indirection is what lets
/// [SharedPreferencesStore] degrade instead of throwing when a runtime has no
/// working storage at all.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// Non-persistent store for tests (and for a session whose device storage is
/// unavailable): values live exactly as long as this object does.
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore({Map<String, String>? values})
      : _values = <String, String>{...?values};

  final Map<String, String> _values;

  /// Snapshot of everything written, for test assertions.
  @visibleForTesting
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> remove(String key) async => _values.remove(key);
}

/// `shared_preferences`-backed store that **never throws**.
///
/// Two failure modes are expected rather than exceptional:
///  * a `flutter test` binding has no plugin behind the channel
///    (`MissingPluginException`), and
///  * a browser can refuse `localStorage` (private mode, partitioned or
///    sandboxed storage) - the same condition `SupabaseService` probes for before
///    it lets the SDK persist a session.
///
/// In both cases the store latches onto its in-memory map and says so once: the
/// exam keeps running with answers cached for this session, rather than failing a
/// save because the disk is unavailable.
class SharedPreferencesStore implements KeyValueStore {
  SharedPreferencesStore({
    @visibleForTesting SharedPreferences? preferences,
    this.prefix = defaultPrefix,
  }) {
    _preferences = preferences;
  }

  /// Namespace so an offline queue can never collide with another plugin's key
  /// (or with `sb-<ref>-auth-token`, which the Supabase SDK owns).
  static const String defaultPrefix = 'proctorguard.';

  final String prefix;

  SharedPreferences? _preferences;

  /// Set once the platform refused storage: every later call goes to [_fallback]
  /// without touching the channel again.
  bool _unavailable = false;

  /// Mirror of everything written this session. It is both the fallback store
  /// and a read cache, so a read cannot be slower than a write.
  final Map<String, String> _fallback = <String, String>{};

  /// False when values are only kept for the lifetime of this object.
  bool get isPersistent => !_unavailable && _preferences != null;

  @override
  Future<String?> read(String key) async {
    final preferences = await _resolve();
    if (preferences != null) {
      try {
        final value = preferences.getString('$prefix$key');
        if (value != null) return value;
      } catch (error) {
        _degrade('read', error);
      }
    }
    return _fallback[key];
  }

  @override
  Future<void> write(String key, String value) async {
    // The in-memory copy is written first and unconditionally: whatever happens
    // below, the value the caller just stored is not lost during this session.
    _fallback[key] = value;

    final preferences = await _resolve();
    if (preferences == null) return;
    try {
      await preferences.setString('$prefix$key', value);
    } catch (error) {
      _degrade('write', error);
    }
  }

  @override
  Future<void> remove(String key) async {
    _fallback.remove(key);

    final preferences = await _resolve();
    if (preferences == null) return;
    try {
      await preferences.remove('$prefix$key');
    } catch (error) {
      _degrade('remove', error);
    }
  }

  Future<SharedPreferences?> _resolve() async {
    final existing = _preferences;
    if (existing != null) return existing;
    if (_unavailable) return null;

    try {
      return _preferences = await SharedPreferences.getInstance();
    } catch (error) {
      _degrade('open', error);
      return null;
    }
  }

  void _degrade(String operation, Object error) {
    if (!_unavailable) {
      proctorLog(
        'ProctorGuard: local storage unavailable on $operation ($error) - '
        'cached answers stay in memory for this session.',
      );
    }
    _unavailable = true;
    _preferences = null;
  }
}

/// The app's persistence for the offline layer.
///
/// Not `autoDispose`: one store for the whole run, so a queue written during one
/// exam is still there when the student comes back to it.
final keyValueStoreProvider =
    Provider<KeyValueStore>((ref) => SharedPreferencesStore());
