import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/analytics_report.dart';
import '../../domain/repositories/dashboard_repository.dart';

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => throw UnimplementedError(
    'dashboardRepositoryProvider must be overridden with a '
    'DashboardRepository (see main.dart / ProviderScope overrides).',
  ),
);

final analyticsReportProvider = FutureProvider<AnalyticsReport>(
  (ref) => ref.watch(dashboardRepositoryProvider).getAnalytics(),
);

const int analyticsWindowDays = 30;
