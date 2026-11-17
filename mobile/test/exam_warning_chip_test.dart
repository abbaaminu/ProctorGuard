import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/exam/presentation/widgets/exam_session_widgets.dart';

/// The "N of 3 warnings" chip in the exam chrome.
///
/// It counts the server's weighted score, not the rows it holds - and the score
/// can pass the threshold without the attempt ending if the rows behind it were
/// refused by the backend (see `ViolationWriteRejected` and the sync banner).
/// "6 of 3" is then what the student read: a fraction whose numerator is a sum
/// and whose denominator is a door.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('never reads past the threshold it measures', (tester) async {
    await tester.pumpWidget(
      host(const ExamWarningChip(count: 6, total: 3, noted: 2)),
    );

    expect(find.text('3 of 3 warnings · 2 noted'), findsOneWidget);
    expect(
      find.text('6 of 3 warnings · 2 noted'),
      findsNothing,
      reason: 'the extra signals are on the record and in the risk index; the '
          'chip cannot claim the attempt is past a door it has already passed',
    );
  });

  testWidgets('still counts every point below the threshold', (tester) async {
    await tester.pumpWidget(host(const ExamWarningChip(count: 1, total: 3)));

    expect(find.text('1 of 3 warnings'), findsOneWidget);
  });

  testWidgets('noted signals stay beside the counted ones', (tester) async {
    await tester.pumpWidget(
      host(const ExamWarningChip(count: 0, total: 3, noted: 2)),
    );

    expect(find.text('0 of 3 warnings · 2 noted'), findsOneWidget);
  });
}
