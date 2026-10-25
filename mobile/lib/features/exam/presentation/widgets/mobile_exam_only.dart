import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Whether an exam attempt may be sat on the platform this build is running on.
///
/// The exam surface is only a *proctored* attempt where the app itself can do
/// the proctoring, and a browser cannot do any of it:
///
///  * **presence** — `google_mlkit_face_detection` has no web implementation and
///    the web camera plugin cannot hand over frames for one either, so a browser
///    attempt has no face check at all unless the page that embeds it happens to
///    run its own detector (`WebFaceSignalSource`).
///  * **the pin** — `startLockTask()` is an Android API and screen pinning does
///    not exist inside a tab; `WebExamGuard` can only *witness* a tab switch and
///    log `app_minimized`, never prevent it.
///  * **the device** — `HardwareIntegrityService` reads the Android display
///    manager. In a browser there is nothing to read, and the second display a
///    student was moved off is their own monitor.
///
/// An attempt opened in a browser would therefore be recorded as a proctored one
/// while being unproctored in fact, which is the one outcome the dashboard must
/// never show a school. The exam is sat on the phone, where the camera, the
/// microphone, the kiosk pin and the integrity probe are all real.
///
/// [isWeb] mirrors `PermissionService({bool? isWeb})`: a Dart VM widget test
/// cannot become a browser, so the rule has to be reachable without compiling
/// for web. Production passes nothing and gets [kIsWeb].
bool examRunsOnPlatform({bool? isWeb}) => !(isWeb ?? kIsWeb);

/// What the student is told instead of an exam, kept beside the rule so the exam
/// screen and the exam list cannot drift apart on it.
const String examMobileOnlyTitle = 'Open this exam in the ProctorGuard app';

const String examMobileOnlyBody =
    'Exams are proctored from the ProctorGuard mobile app: the phone\'s own '
    'camera, microphone and screen pin are what record the attempt, and a '
    'browser cannot provide them. No attempt has been started here.';

const String examMobileOnlyHint =
    'Install ProctorGuard on your phone, sign in with the same account and open '
    'the exam there.';

/// The whole screen a browser gets instead of an exam attempt.
///
/// A page rather than a dialog because the route can be reached without the exam
/// list (a resumed attempt, a restored navigator stack, a shared link): whichever
/// way it is built, the browser gets this instead of a paper it cannot be
/// proctored on.
class MobileExamOnlyPage extends StatelessWidget {
  const MobileExamOnlyPage({super.key, this.onLeave});

  /// The "Back to my exams" action, or null when the route cannot pop.
  final VoidCallback? onLeave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('exam-mobile-only'),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.phone_iphone,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    examMobileOnlyTitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    examMobileOnlyBody,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    examMobileOnlyHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (onLeave != null) ...[
                    const SizedBox(height: 24),
                    OutlinedButton.icon(
                      onPressed: onLeave,
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back to my exams'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Says the same thing from the exam list, *before* an attempt is created.
///
/// The refusal has to happen here rather than only on the exam screen: this is the
/// call site that runs `startOrResumeSubmission`, and an attempt row created for a
/// browser would sit on the supervisor's dashboard as `ongoing` for a sitting the
/// student was then told to finish on a phone they never opened it on.
Future<void> showMobileExamOnlyDialog(
  BuildContext context, {
  bool? isWeb,
}) {
  if (examRunsOnPlatform(isWeb: isWeb)) return Future<void>.value();

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('exam-mobile-only-dialog'),
      icon: const Icon(Icons.phone_iphone),
      title: const Text(examMobileOnlyTitle),
      content: Text('$examMobileOnlyBody\n\n$examMobileOnlyHint'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
