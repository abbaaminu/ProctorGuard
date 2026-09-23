import 'package:exam_proctor/features/proctoring/domain/entities/violation.dart';
import 'package:exam_proctor/features/proctoring/presentation/widgets/violation_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the full-screen proctoring warning, which is deliberately
/// free of camera/Supabase dependencies so it can be pumped directly.
void main() {
  testWidgets('shows the current strike count and the violation message',
      (tester) async {
    var dismissed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: ViolationOverlay(
          type: ViolationType.lookingAway,
          warningCount: 2,
          isFinal: false,
          onDismiss: () => dismissed = true,
        ),
      ),
    );

    expect(find.text('Warning 2 / 3'), findsOneWidget);
    expect(find.text('Please keep your eyes on the screen.'), findsOneWidget);

    await tester.tap(find.text('I understand, continue'));
    expect(dismissed, isTrue);
  });

  testWidgets('locks down after the third strike with no continue button',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ViolationOverlay(
          type: ViolationType.multipleFaces,
          warningCount: 3,
          isFinal: true,
          onDismiss: () {},
        ),
      ),
    );

    expect(find.text('Exam Terminated'), findsOneWidget);
    expect(find.text('Exit'), findsOneWidget);
    expect(find.text('I understand, continue'), findsNothing);
  });
}
