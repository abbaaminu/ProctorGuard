// Browser-guard smoke target — not part of the app.
//
// `lib/core/services/web_guards_web.dart` only exists in a web build (it is
// behind a conditional import), so this throwaway entrypoint exists to force that
// code through the real browser toolchain without a router or an exam session:
//
//   flutter build web -t tool/web_guard_smoke.dart
//
// If it builds, the DOM half of the guards still compiles. On the Dart VM the
// same code resolves to `UnsupportedWebGuards`, which is why this file analyzes
// cleanly on every platform.
import 'package:flutter/widgets.dart';

import 'package:exam_proctor/core/services/web_guards.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final guards = WebGuards();
  guards.events.listen((event) => debugPrint('guard event: $event'));
  debugPrint('web guards supported: ${guards.isSupported}');

  final entered = await guards.enterFullscreen();
  debugPrint('fullscreen engaged: $entered (now ${guards.isFullscreen})');
  await guards.exitFullscreen();
  guards.dispose();

  runApp(const SizedBox.shrink());
}
