import 'package:proctorguard/features/proctoring/domain/entities/proctoring_risk.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/presentation/widgets/violation_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the full-screen proctoring warning, which is deliberately
/// free of camera/Supabase dependencies so it can be pumped directly.
///
/// The risk chip on it is not decoration: it is the student's copy of the number
/// the supervisor's grid shows for the same attempt, so these tests check that
/// what the overlay prints is the [`ProctoringRisk`] it was handed, and that the
/// caption spells out what the chip's tooltip would have said (a phone cannot
/// hover).
void main() {
  /// The overlay with every argument a caller must supply, so each test only has
  /// to state what it is actually about.
  Widget overlay({
    ViolationType? type = ViolationType.lookingAway,
    int warningCount = 1,
    bool isFinal = false,
    ProctoringRisk risk = ProctoringRisk.none,
    VoidCallback? onDismiss,
  }) => MaterialApp(
    home: ViolationOverlay(
      type: type,
      warningCount: warningCount,
      isFinal: isFinal,
      risk: risk,
      onDismiss: onDismiss ?? () {},
    ),
  );

  testWidgets('shows the current strike count and the violation message',
      (tester) async {
    var dismissed = false;

    await tester.pumpWidget(
      overlay(warningCount: 2, onDismiss: () => dismissed = true),
    );

    expect(find.text('Warning 2 / 3'), findsOneWidget);
    expect(find.text('Please keep your eyes on the screen.'), findsOneWidget);

    await tester.tap(find.text('I understand, continue'));
    expect(dismissed, isTrue);
  });

  testWidgets('locks down after the third strike with no continue button',
      (tester) async {
    await tester.pumpWidget(
      overlay(
        type: ViolationType.multipleFaces,
        warningCount: 3,
        isFinal: true,
      ),
    );

    expect(find.text('Exam Terminated'), findsOneWidget);
    expect(find.text('Exit'), findsOneWidget);
    expect(find.text('I understand, continue'), findsNothing);
  });

  testWidgets('prints the attempt\'s own risk index and what it is made of',
      (tester) async {
    // Three strikes, two distinct signals, one of them serious: 3*20 + 1*10 +
    // 1*15 = 85, which is the score a supervisor would be looking at too.
    final risk = ProctoringRisk.fromViolations(const <ViolationType>[
      ViolationType.multipleFaces,
      ViolationType.noFace,
      ViolationType.noFace,
    ]);

    await tester.pumpWidget(
      overlay(
        type: ViolationType.noFace,
        warningCount: 3,
        isFinal: true,
        risk: risk,
      ),
    );

    expect(find.byKey(const Key('violation-risk')), findsOneWidget);
    expect(find.text('Critical risk · 85'), findsOneWidget);
    // The tooltip is unreachable on a phone, so the same sentence is on screen.
    expect(
      find.text('3 violations across 2 signals, 1 of them serious'),
      findsOneWidget,
    );
  });

  testWidgets('a phone in landscape can still reach the button', (tester) async {
    // 640x360 dp: the shortest viewport a proctored exam actually runs in. The
    // block is taller than that once the chip is in it, so it has to scroll
    // rather than overflow - the button is the only way back to the exam.
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(overlay(warningCount: 2));

    expect(tester.takeException(), isNull);
    await tester.dragUntilVisible(
      find.text('I understand, continue'),
      find.byType(SingleChildScrollView),
      const Offset(0, -40),
    );
    expect(find.text('I understand, continue'), findsOneWidget);
  });
}
