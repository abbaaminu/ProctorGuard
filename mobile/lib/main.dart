import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/services/lockdown_bootstrap.dart';
import 'core/services/permission_service.dart';
import 'core/services/supabase_service.dart';
import 'core/utils/proctor_log.dart';
import 'core/widgets/setup_required_page.dart';
import 'features/admin/data/repositories/admin_user_repository_impl.dart';
import 'features/admin/presentation/providers/admin_providers.dart';
import 'features/auth/data/repositories/profile_repository_impl.dart';
import 'features/auth/presentation/providers/profile_provider.dart';
import 'features/auth/presentation/widgets/role_gate.dart';
import 'features/authoring/data/repositories/question_authoring_repository_impl.dart';
import 'features/authoring/presentation/providers/question_authoring_providers.dart';
import 'features/dashboard/data/repositories/dashboard_repository_impl.dart';
import 'features/dashboard/presentation/providers/dashboard_providers.dart';
import 'features/exam/data/repositories/exam_repository_impl.dart';
import 'features/proctoring/data/repositories/proctoring_repository_impl.dart';
import 'features/proctoring/presentation/providers/proctoring_provider.dart';

/// Boot order is deliberate on web: `--dart-define` values are compiled into
/// the build, so the Supabase client can be built before the first frame — but
/// **nothing here may throw**, because an exception before `runApp` is exactly
/// the blank white page this structure avoids. [SupabaseService.init] reports
/// status instead, and `SetupRequiredPage` explains what is missing.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final supabaseStatus = await SupabaseService.instance.init();

  // Request camera/mic/overlay up front so the permission prompts don't
  // interrupt the flow right as an exam is starting. The service already skips
  // permissions a platform lacks (the Android-only overlay permission on web).
  //
  // Deliberately NOT awaited: an OS permission dialog stays on screen until the
  // student answers it, and blocking the first frame on that is exactly the
  // blank-page startup failure this boot order exists to avoid. `ExamTakingPage`
  // re-checks the critical statuses before opening the camera anyway, so an
  // unproctored session can never start silently.
  unawaited(requestStartupPermissions());

  final client = SupabaseService.instance.clientOrNull;

  // The web lockdown script (`web/index.html`) blocks the clipboard, the context
  // menu and the developer-tools shortcuts from the moment the page loads - the
  // window in which this app is not running yet, which a reload reopens. This is
  // the signal that ends that presumption, and it is deliberately sent here, one
  // statement before the first frame: everything before it is the app's own
  // startup (the engine, `SupabaseService.init`, the loader), where nothing on
  // the page is the student's yet. From here on only an armed exam locks the
  // page; what the script denied while it was waiting is queued, not lost, and
  // the exam that arms the lockdown claims it.
  //
  // Synchronous and never throwing: a no-op off the web, and a host without the
  // bootstrap script is simply not told anything (see [LockdownBootstrap]).
  LockdownBootstrap().markAppBooted();

  runApp(
    ProviderScope(
      overrides: [
        // Only bind the repositories when there is a backend. Otherwise the
        // providers keep their explicit "override me" throw and the setup
        // screen explains why, instead of some page crashing later.
        if (client != null)
          examRepositoryProvider.overrideWithValue(ExamRepositoryImpl(client)),
        if (client != null)
          profileRepositoryProvider
              .overrideWithValue(ProfileRepositoryImpl(client)),
        if (client != null)
          proctoringRepositoryProvider
              .overrideWithValue(ProctoringRepositoryImpl(client)),
        if (client != null)
          adminUserRepositoryProvider
              .overrideWithValue(AdminUserRepositoryImpl(client)),
        if (client != null)
          dashboardRepositoryProvider
              .overrideWithValue(DashboardRepositoryImpl(client)),
        if (client != null)
          questionAuthoringRepositoryProvider
              .overrideWithValue(QuestionAuthoringRepositoryImpl(client)),
      ],
      child: ExamProctorApp(supabaseStatus: supabaseStatus),
    ),
  );
}

/// Fire-and-forget startup permission pass (see [main]).
///
/// Every failure is logged rather than thrown: this runs outside any caller's
/// await, so a thrown error would only surface as an unhandled async error.
Future<void> requestStartupPermissions() async {
  try {
    await PermissionService().requestAll();
  } catch (error) {
    proctorLog('Startup permission pass failed, continuing without it: $error');
  }
}

class ExamProctorApp extends StatelessWidget {
  const ExamProctorApp({super.key, required this.supabaseStatus});

  /// Injected rather than read from the singleton, so every startup state is
  /// reachable from widget tests.
  final SupabaseInitStatus supabaseStatus;

  @override
  Widget build(BuildContext context) {
    final service = SupabaseService.instance;

    return MaterialApp(
      // The app's own name metadata: Android uses it for the task-switcher entry,
      // the web build for the browser tab. The launcher label is `android:label`
      // and the web/iOS names are `web/index.html` (`<title>`,
      // `apple-mobile-web-app-title`), `web/manifest.json` and the Info.plist
      // checklist in `ios/README.md` - `android_manifest_contract_test.dart` pins
      // all of them to one name, because the app tells a student whose microphone
      // was refused to go and allow "ProctorGuard" (`audio_monitor.dart`).
      title: 'ProctorGuard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      // `RoleGate` is the whole router today: signed out -> login, then
      // `profiles.role` picks the student portal, the staff console or the admin
      // staff console. Swap in go_router config when deep links matter —
      // every page takes plain constructor args.
      home: supabaseStatus == SupabaseInitStatus.ready
          ? const RoleGate()
          : SetupRequiredPage(
              status: supabaseStatus,
              detail: service.initError,
              storageBlocked: !service.sessionPersistenceAvailable,
            ),
    );
  }
}
