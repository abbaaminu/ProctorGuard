import 'package:exam_proctor/core/services/supabase_service.dart';
import 'package:exam_proctor/core/widgets/setup_required_page.dart';
import 'package:exam_proctor/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web startup failure this guards against is a blank page: these tests pin
/// the "render something actionable instead" behaviour.
void main() {
  group('startup screens', () {
    testWidgets('unconfigured build shows setup steps instead of a blank page',
        (tester) async {
      await tester.pumpWidget(
        const ExamProctorApp(supabaseStatus: SupabaseInitStatus.notConfigured),
      );
      await tester.pump();

      expect(find.text('Supabase is not configured'), findsOneWidget);
      expect(find.textContaining('--dart-define=SUPABASE_URL'), findsOneWidget);
    });

    testWidgets('failed initialisation is reported', (tester) async {
      await tester.pumpWidget(
        const ExamProctorApp(supabaseStatus: SupabaseInitStatus.failed),
      );
      await tester.pump();

      expect(find.text('Supabase failed to initialise'), findsOneWidget);
    });

    testWidgets('warns when the runtime refuses local storage', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SetupRequiredPage(
            status: SupabaseInitStatus.ready,
            storageBlocked: true,
          ),
        ),
      );

      expect(find.textContaining('blocks local storage'), findsOneWidget);
    });
  });
}
