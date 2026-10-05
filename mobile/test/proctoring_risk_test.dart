import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/proctoring/domain/entities/proctoring_risk.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/presentation/widgets/risk_index_chip.dart';

/// The risk index rule, exercised on its own.
///
/// `ProctoringRisk` is what both the student's warning overlay and the
/// supervisor's grid read, so the numbers are pinned here rather than inferred
/// from whatever a widget happens to render: the parts that matter are that the
/// score is a function of the session's whole evidence list, that *mixed* signals
/// cost more than repeats, and that the server's strike count can raise the index
/// but never lower it.
void main() {
  group('proctoring risk index', () {
    test('no evidence scores zero and is the only "no evidence" state', () {
      final risk = ProctoringRisk.fromViolations(const <ViolationType>[]);

      expect(risk.score, 0);
      expect(risk.band, RiskBand.low);
      expect(risk.strikes, 0);
      expect(risk.distinctTypes, 0);
      expect(risk.severeCount, 0);
      expect(identical(risk, ProctoringRisk.none), isTrue);
    });

    test('one violation is Moderate, not Low', () {
      final risk = ProctoringRisk.fromViolations([ViolationType.lookingAway]);

      // 20 * 1 + 10 * 0 + 15 * 0
      expect(risk.score, 20);
      expect(risk.band, RiskBand.moderate);
      expect(risk.label, 'Moderate');
    });

    test('repeating one signal costs less than mixing several', () {
      final repeated = ProctoringRisk.fromViolations(
        List<ViolationType>.filled(3, ViolationType.lookingAway),
      );
      final mixed = ProctoringRisk.fromViolations(const <ViolationType>[
        ViolationType.lookingAway,
        ViolationType.noFace,
        ViolationType.audioNoise,
      ]);

      // Same three strikes: 60 + 0 vs 60 + 10 * 2.
      expect(repeated.strikes, 3);
      expect(mixed.strikes, 3);
      expect(repeated.distinctTypes, 1);
      expect(mixed.distinctTypes, 3);
      expect(repeated.score, 60);
      expect(mixed.score, 80);

      // The third strike is the server's auto-disqualification threshold, so it
      // must never read below High whatever produced it.
      expect(repeated.band, RiskBand.high);
      expect(mixed.band, RiskBand.critical);
    });

    test('a severe signal is priced on its own', () {
      final risk = ProctoringRisk.fromViolations([
        ViolationType.multipleFaces,
      ]);

      // 20 * 1 + 10 * 0 + 15 * 1 - one signal, but not one to sit on.
      expect(risk.severeCount, 1);
      expect(risk.score, 35);
      expect(risk.label, 'Moderate');
    });

    test('the four severe signals are the ones that mean "not alone"', () {
      expect(ProctoringRisk.severeSignals, const <ViolationType>{
        ViolationType.multipleFaces,
        ViolationType.virtualCameraDetected,
        ViolationType.secondaryDisplayDetected,
        ViolationType.devtoolsDetected,
      });

      for (final type in ProctoringRisk.severeSignals) {
        expect(
          ProctoringRisk.fromViolations([type]).severeCount,
          1,
          reason: '$type is severe',
        );
      }
    });

    test('the score saturates at 100 rather than running past it', () {
      final risk = ProctoringRisk.fromViolations(ViolationType.values);

      // 20 * 11 + 10 * 10 + 15 * 4, well past the ceiling.
      expect(risk.strikes, 11);
      expect(risk.score, 100);
      expect(risk.band, RiskBand.critical);
    });

    test('server strikes raise the count a local list cannot explain', () {
      // A resumed attempt: the server remembers two strikes, this build has no
      // local evidence list for them.
      final risk = ProctoringRisk.fromViolations(
        const <ViolationType>[],
        serverStrikes: 2,
      );

      expect(risk.strikes, 2);
      expect(risk.distinctTypes, 0);
      // 20 * 2 + 10 * 0: the missing mix must not *deduct* from the count, or a
      // session with more evidence would score lower than one with less.
      expect(risk.score, 40);
      expect(risk.band, RiskBand.moderate);
      expect(identical(risk, ProctoringRisk.none), isFalse);
    });

    test('the richer of the two counts wins, never their sum', () {
      final richerLocally = ProctoringRisk.fromViolations(
        const <ViolationType>[ViolationType.noFace, ViolationType.noFace],
        serverStrikes: 1,
      );
      final richerOnServer = ProctoringRisk.fromViolations(
        const <ViolationType>[ViolationType.noFace],
        serverStrikes: 3,
      );

      expect(richerLocally.strikes, 2);
      expect(richerOnServer.strikes, 3);
    });

    test('the explanation says what the score is made of', () {
      final single = ProctoringRisk.fromViolations([
        ViolationType.lookingAway,
      ]);
      final mixed = ProctoringRisk.fromViolations(const <ViolationType>[
        ViolationType.multipleFaces,
        ViolationType.noFace,
        ViolationType.noFace,
      ]);

      // Singular and plural both ways, and the serious clause only when it
      // applies.
      expect(single.explanation, '1 violation across 1 signal');
      expect(
        mixed.explanation,
        '3 violations across 2 signals, 1 of them serious',
      );
    });
  });

  group('risk index chip', () {
    testWidgets('names the band and the score, and explains it in the tooltip', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: RiskIndexChip(risk: ProctoringRisk.none)),
        ),
      );

      expect(find.text('Low risk · 0'), findsOneWidget);
      expect(find.byIcon(Icons.speed), findsOneWidget);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Risk index 0/100 — 0 violations across 0 signals',
      );
    });

    testWidgets('compact keeps the band word and drops the score', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RiskIndexChip(
              risk: ProctoringRisk(
                score: 80,
                strikes: 3,
                distinctTypes: 3,
                severeCount: 0,
              ),
              compact: true,
            ),
          ),
        ),
      );

      // The grid row already prints its own flag count, so the chip must not
      // repeat a second number next to it.
      expect(find.text('Critical'), findsOneWidget);
      expect(find.textContaining('80'), findsNothing);
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).message,
        'Risk index 80/100 — 3 violations across 3 signals',
      );
    });

    testWidgets('on the dark overlay the low band stays legible', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ColoredBox(
            color: Colors.black,
            child: Center(
              child: RiskIndexChip(risk: ProctoringRisk.none, onDark: true),
            ),
          ),
        ),
      );

      // The light scheme's `onSurfaceVariant` is a dark grey, which reads as
      // "greyed out" on the black proctoring overlay - so the low band has to be
      // re-coloured there, exactly like the critical band is.
      expect(
        tester.widget<Text>(find.text('Low risk · 0')).style?.color,
        Colors.white70,
      );
    });
  });
}
