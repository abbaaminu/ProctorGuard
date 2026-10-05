// Browser-guard smoke target — not part of the app.
//
// `lib/core/services/web_guards_web.dart` and
// `lib/core/services/network_status_web.dart` only exist in a web build (both are
// behind a conditional import), so this throwaway entrypoint exists to force that
// code through the real browser toolchain without a router or an exam session:
//
//   flutter build web -t tool/web_guard_smoke.dart
//
// If it builds, the DOM half of the guards and of the connectivity probe still
// compiles. On the Dart VM the same code resolves to `UnsupportedWebGuards` /
// `NoNetworkStatus`, which is why this file analyzes cleanly on every platform.
import 'package:flutter/widgets.dart';

import 'package:proctorguard/core/services/lockdown_bootstrap.dart';
import 'package:proctorguard/core/services/network_status.dart';
import 'package:proctorguard/core/services/web_guards.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The pre-boot half of the browser lockdown: `web/index.html` blocks the
  // clipboard against this call, so the smoke build has to be able to make it
  // (`lockdown_bootstrap_web.dart`, web builds only).
  final bootstrap = LockdownBootstrap();
  debugPrint('lockdown bootstrap supported: ${bootstrap.isSupported}');
  bootstrap.markAppBooted();

  final guards = WebGuards();
  guards.events.listen((event) => debugPrint('guard event: $event'));
  debugPrint('web guards supported: ${guards.isSupported}');

  final entered = await guards.enterFullscreen();
  debugPrint('fullscreen engaged: $entered (now ${guards.isFullscreen})');
  await guards.exitFullscreen();
  guards.dispose();

  // Same check for the offline layer's probe: `navigator.onLine` plus the
  // window's `online`/`offline` events (`network_status_web.dart`).
  final network = NetworkStatus();
  network.changes.listen((online) => debugPrint('network: $online'));
  debugPrint('network probe supported: ${network.isSupported} '
      '(online: ${network.isOnline})');
  network.dispose();

  runApp(const SizedBox.shrink());
}
