import 'package:flutter/services.dart' show StringCodec;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/widgets/refresh_on_resume.dart';
import 'package:proctorguard/features/exam/presentation/providers/exam_providers.dart';

/// Coming back to the app re-reads the screens it shares with everybody else.
///
/// Those providers are plain `FutureProvider`s and keep their first answer —
/// which is what makes a second visit instant, and also why a change made on
/// another device (a paper published from a laptop, an account created by an
/// administrator) stayed invisible until the student found the refresh button.
/// A resume is the moment the user is entitled to expect "now", so it is the one
/// lifecycle event that drops those answers. Both halves are pinned here: a
/// resume refreshes, and merely leaving the app does not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A provider whose every *build* is counted, so "was it re-read?" is a number
  /// rather than an assumption about Riverpod's internals.
  var builds = 0;
  late AutoDisposeFutureProvider<int> probe;

  setUp(() {
    builds = 0;
    probe = FutureProvider.autoDispose<int>((ref) async {
      builds++;
      return builds;
    });
  });

  Widget harness() => ProviderScope(
        child: RefreshOnResume(
          providers: <ProviderOrFamily>[probe],
          child: Consumer(
            builder: (context, ref, _) {
              ref.watch(probe);
              return const SizedBox();
            },
          ),
        ),
      );

  /// Sends the platform messages the engine sends, one state at a time.
  ///
  /// The sequence matters: `AppLifecycleListener` asserts on a transition the
  /// platform would never make (it will not accept `resumed -> paused`), so the
  /// walk out and back is the same one Android performs.
  Future<void> send(WidgetTester tester, List<String> states) async {
    for (final state in states) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/lifecycle',
        const StringCodec().encodeMessage(state),
        (_) {},
      );
    }
  }

  const toBackground = <String>[
    'AppLifecycleState.inactive',
    'AppLifecycleState.hidden',
    'AppLifecycleState.paused',
  ];
  const toForeground = <String>[
    'AppLifecycleState.hidden',
    'AppLifecycleState.inactive',
    'AppLifecycleState.resumed',
  ];

  testWidgets('a resume re-reads the providers it was given', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(builds, 1);

    await send(tester, toBackground);
    await tester.pumpAndSettle();
    expect(
      builds,
      1,
      reason: 'leaving the app is not a refresh point — the permission dialog, '
          'the camera prompt and the notification shade all pass through it',
    );

    await send(tester, toForeground);
    await tester.pumpAndSettle();
    expect(
      builds,
      2,
      reason: 'coming back is: the provider is rebuilt, which is what makes a '
          'paper published while the app was away appear without a refresh tap',
    );
  });

  testWidgets('a second resume is a second re-read', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    for (var round = 0; round < 2; round++) {
      await send(tester, <String>[...toBackground, ...toForeground]);
      await tester.pumpAndSettle();
    }

    expect(builds, 3, reason: 'one rebuild for the first build, one per resume');
  });

  test('the default set is the shared lists', () {
    // The one the student portal and the supervisor picker share: if this ever
    // dropped out, a paper published while the app was in the background would
    // be back to needing the refresh button.
    expect(refreshOnResume, contains(publishedExamsProvider));
    expect(refreshOnResume, isNotEmpty);
  });
}
