import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/admin/presentation/providers/admin_providers.dart';
import '../../features/authoring/presentation/providers/question_authoring_providers.dart';
import '../../features/dashboard/presentation/providers/dashboard_providers.dart';
import '../../features/exam/presentation/providers/exam_providers.dart';

/// The screens that show data somebody else can change while they are open.
///
/// Every entry is a *list* or a *report*: a paper published from another device,
/// a roster that gained an account, a paper that just gained its first attempt.
/// Re-reading them is cheap and idempotent, which is what makes them safe to
/// refresh whenever the app has reason to believe the answer may have moved —
/// see [RefreshOnResume].
///
/// Deliberately not the family providers (`examQuestionsProvider`,
/// `examAttemptsProvider`, …): those belong to one screen, which already
/// invalidates them after every edit it makes, and a resume is not that screen.
final List<ProviderOrFamily> refreshOnResume = <ProviderOrFamily>[
  publishedExamsProvider,
  managedAccountsProvider,
  myAuthoredExamsProvider,
  analyticsReportProvider,
];

/// Re-reads the shared screens' data when the app comes back to the foreground.
///
/// Why this exists: those providers are plain `FutureProvider`s, so once they
/// have an answer they keep it. That is what makes returning to a screen
/// instant, and it is also why a change made elsewhere — a lecturer publishing a
/// paper on a laptop, an administrator creating an account — did not show up
/// until the student pressed the refresh button. Coming back to the app is the
/// moment the user has reason to expect "now", so that is when the cached
/// answers are dropped: cheap, bounded (four small queries), and it also lets a
/// screen that failed while the network was down recover on its own instead of
/// waiting for a tap on Try again.
///
/// Deliberately **not** on every lifecycle event: `inactive` fires for a
/// permission dialog, the camera prompt and the notification shade, and
/// re-fetching four lists for each of those would be noise. Only `resumed` — the
/// app is on screen and in front of the user again — is a refresh point.
///
/// Nothing here touches the exam session screen: it owns no cached list, and its
/// own provider is `autoDispose` keyed by submission. What a resume *can* reach
/// is the list under it (the portal), which is a harmless re-read.
class RefreshOnResume extends ConsumerStatefulWidget {
  const RefreshOnResume({super.key, required this.child, this.providers});

  final Widget child;

  /// What a resume invalidates, defaulting to [refreshOnResume]. Injectable so a
  /// widget test can assert the behaviour against a provider of its own (the
  /// default list cannot be a `const` default parameter — it names providers).
  final List<ProviderOrFamily>? providers;

  @override
  ConsumerState<RefreshOnResume> createState() => _RefreshOnResumeState();
}

class _RefreshOnResumeState extends ConsumerState<RefreshOnResume> {
  /// A live listener rather than `WidgetsBindingObserver` bookkeeping: it
  /// registers in its own constructor and unregisters in `dispose`, so there is
  /// no way for this widget to leave an observer behind.
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    for (final provider in widget.providers ?? refreshOnResume) {
      ref.invalidate(provider);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
