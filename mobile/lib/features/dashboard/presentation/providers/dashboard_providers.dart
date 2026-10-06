import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/analytics_report.dart';
import '../../domain/repositories/dashboard_repository.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => throw UnimplementedError(
    'dashboardRepositoryProvider must be overridden with a '
    'DashboardRepository (see main.dart / ProviderScope overrides).',
  ),
);

/// The staff analytics report. Invalidate to refresh; the page also does that
/// for itself from its refresh control, and `RefreshOnResume` does it when the
/// app comes back to the foreground.
///
/// `autoDispose`, so reopening the page reads the report again rather than
/// showing the copy it cached the first time.
final analyticsReportProvider = FutureProvider.autoDispose<AnalyticsReport>(
  (ref) => ref.watch(dashboardRepositoryProvider).getAnalytics(),
);

const int analyticsWindowDays = 30;
