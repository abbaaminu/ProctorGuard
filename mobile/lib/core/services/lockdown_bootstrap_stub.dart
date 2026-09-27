import 'lockdown_bootstrap.dart';

/// Creates the boot signal for platforms that have no page to signal.
LockdownBootstrap createLockdownBootstrap() => const UnsupportedLockdownBootstrap();

/// No-op signal for Android, iOS, desktop - and for the Dart VM, which is what
/// `flutter test` runs on.
///
/// There is no `index.html` and no pre-boot JavaScript on these platforms:
/// Android has lock task mode plus a native copy/paste block instead (see
/// `KioskService`), and nothing else has a browser to lock down.
class UnsupportedLockdownBootstrap implements LockdownBootstrap {
  const UnsupportedLockdownBootstrap();

  @override
  bool get isSupported => false;

  @override
  void markAppBooted() {}
}
