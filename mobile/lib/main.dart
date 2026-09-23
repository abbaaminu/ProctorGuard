import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/services/permission_service.dart';
import 'core/services/supabase_service.dart';
import 'core/widgets/setup_required_page.dart';
import 'features/auth/presentation/pages/login_page.dart';
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
  // permissions a platform lacks (the Android-only overlay permission on web);
  // this guard is belt-and-braces.
  try {
    await PermissionService().requestAll();
  } catch (error) {
    debugPrint('Startup permission pass failed, continuing without it: $error');
  }

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
          proctoringRepositoryProvider
              .overrideWithValue(ProctoringRepositoryImpl(client)),
      ],
      child: ExamProctorApp(supabaseStatus: supabaseStatus),
    ),
  );
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
      // Replace with go_router config wiring: /login, /exams, /exam/:id,
      // /dashboard/:examId — omitted here for brevity, each page above
      // takes plain constructor args so any router works.
      home: supabaseStatus == SupabaseInitStatus.ready
          ? const _RoleGate()
          : SetupRequiredPage(
              status: supabaseStatus,
              detail: service.initError,
              storageBlocked: !service.sessionPersistenceAvailable,
            ),
    );
  }
}

/// Reads `users.role` for the authenticated user and routes to the
/// student exam list or the supervisor dashboard picker accordingly.
class _RoleGate extends StatelessWidget {
  const _RoleGate();

  @override
  Widget build(BuildContext context) {
    // Rebuilds on every auth event, so the session the SDK restores from
    // storage after a browser refresh lands here too.
    return StreamBuilder<bool>(
      stream: SupabaseService.instance.signedInChanges,
      builder: (context, snapshot) {
        final user = SupabaseService.instance.currentUser;
        if (user == null) {
          return const LoginPage();
        }
        // return const ExamListPage(); // student
        // or SupervisorExamPickerPage(); // supervisor, based on users.role
        return const Scaffold(
          body: Center(child: Text('Role-based home goes here')),
        );
      },
    );
  }
}

