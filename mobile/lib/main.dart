import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/services/permission_service.dart';
import 'core/services/supabase_service.dart';
import 'core/widgets/setup_required_page.dart';
import 'features/auth/data/repositories/profile_repository_impl.dart';
import 'features/auth/presentation/providers/profile_provider.dart';
import 'features/auth/presentation/widgets/role_gate.dart';
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
    debugPrint('Startup permission pass failed, continuing without it: $error');
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
      title: 'Exam Proctor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      // `RoleGate` is the whole router today: signed out -> login, then
      // `users.role` picks the student portal or the supervisor console. Swap in
      // go_router config (/login, /exams, /exam/:id, /dashboard/:examId) when
      // deep links matter — every page takes plain constructor args.
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



