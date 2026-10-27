import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../../core/widgets/desktop_only_web_guard.dart'
    show browserIdentity, isMobileBrowser;

/// Whether an exam attempt may be sat on the platform this build is running on.
///
/// Three answers, because there are three kinds of host:
///
///  * **the Android app** — yes. It is the host an attempt is designed around:
///    ML Kit's on-device face detector, `startLockTask()` screen pinning, and
///    `HardwareIntegrityService` reading the display manager.
///  * **a desktop browser** (Windows, macOS, Linux) — yes. It is how a student
///    without an Android phone sits the paper: the browser has a real camera
///    (`camera_web`), the browser guards (`WebExamGuard`: fullscreen, tab/blur,
///    clipboard, developer tools), audio level metering, and the shipped
///    `web/proctor_face_detector.js` plus the host-page `proctorGuardFaceSignal`
///    bridge for face signals. The hardware gate names the smaller surface
///    before the exam (`faceDetectionInactive`), so nothing here is passed off as
///    a phone attempt.
///  * **a phone or tablet browser** — no. A touch-sized browser is a second-class
///    host for the proctoring surface: no kiosk pin, no OS-level integrity probe,
///    and a screen the student can leave with a gesture. That is the case the
///    [MobileExamOnlyPage] and the dialog below speak to, and they name the
///    Android app as the way to sit the exam.
///
/// The browser answer is about the **device**, not the window: it is the same
/// rule the app-wide `DesktopOnlyWebGuard` applies to the whole web build
/// (`isMobileBrowser` in `core/widgets/desktop_only_web_guard.dart`), so a
/// desktop browser resized narrow is still allowed to sit the exam — the width
/// limit is the administrative console's, not the exam's.
///
/// [isWeb], [userAgent], [browserPlatform] and [maxTouchPoints] mirror the
/// guard's overrides: a Dart VM widget test cannot become a browser, so the rule
/// has to be reachable without compiling for web. Production passes nothing and
/// gets [kIsWeb] and the real `navigator` values.
bool examRunsOnPlatform({
  bool? isWeb,
  String? userAgent,
  String? browserPlatform,
  int? maxTouchPoints,
}) {
  // Native builds — the Android app above all — are the product, and nothing
  // here has an opinion about them.
  if (!(isWeb ?? kIsWeb)) return true;

  final browser = browserIdentity();
  return !isMobileBrowser(
    userAgent: userAgent ?? browser.userAgent,
    platform: browserPlatform ?? browser.platform,
    maxTouchPoints: maxTouchPoints ?? browser.maxTouchPoints,
  );
}

/// What the student is told instead of an exam, kept beside the rule so the exam
/// screen and the exam list cannot drift apart on it.
const String examMobileOnlyTitle = 'Sit this exam in the ProctorGuard app';

const String examMobileOnlyBody =
    'This browser is on a phone or a tablet, where an exam cannot be proctored: '
    'the ProctorGuard Android app records the attempt with its own camera, its '
    'microphone and its screen pin. No attempt has been started here.';

const String examMobileOnlyHint =
    'Install ProctorGuard on your Android phone, sign in with the same account '
    'and open the exam there. If you have a computer, open the exam in Chrome or '
    'Edge — a desktop browser can sit it.';

/// The whole screen a phone or tablet browser gets instead of an exam attempt.
///
/// A page rather than a dialog because the route can be reached without the exam
/// list (a resumed attempt, a restored navigator stack, a shared link): whichever
/// way it is built, that browser gets this instead of a paper it cannot be
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
/// phone or tablet browser would sit on the supervisor's dashboard as `ongoing`
/// for a sitting the student was then told to finish in the app they never opened
/// it on.
///
/// The browser facts are forwarded to [examRunsOnPlatform] unchanged; see its own
/// doc for why a desktop browser is not refused.
Future<void> showMobileExamOnlyDialog(
  BuildContext context, {
  bool? isWeb,
  String? userAgent,
  String? browserPlatform,
  int? maxTouchPoints,
}) {
  if (examRunsOnPlatform(
    isWeb: isWeb,
    userAgent: userAgent,
    browserPlatform: browserPlatform,
    maxTouchPoints: maxTouchPoints,
  )) {
    return Future<void>.value();
  }

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
