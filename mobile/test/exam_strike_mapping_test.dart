import 'package:exam_proctor/core/services/hardware_integrity_service.dart';
import 'package:exam_proctor/core/services/web_guards.dart';
import 'package:exam_proctor/features/exam/presentation/exam_strike_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

/// The strike/violation rule, exercised on its own.
///
/// This mapping used to be two `switch` statements inside `exam_taking_page.dart`,
/// where the only way to reach it was a full widget session. It is pure now, so
/// these tests pin the rule directly: which browser-guard and device-integrity
/// events are strikes, which strike each one is, and which event is not a strike
/// at all.
void main() {
  group('browser-guard events', () {
    test('leaving the exam surface is always app_minimized', () {
      for (final event in const <WebGuardEvent>[
        WebGuardEvent.tabHidden,
        WebGuardEvent.windowBlurred,
        WebGuardEvent.fullscreenExited,
      ]) {
        expect(
          strikeForWebGuardEvent(event),
          ExamStrike.appMinimized,
          reason: '$event leaves the exam surface',
        );
      }
    });

    test('the three clipboard events share one copy_paste strike', () {
      for (final event in const <WebGuardEvent>[
        WebGuardEvent.copyBlocked,
        WebGuardEvent.cutBlocked,
        WebGuardEvent.pasteBlocked,
      ]) {
        expect(
          strikeForWebGuardEvent(event),
          ExamStrike.copyPasteAttempt,
          reason: '$event is a clipboard attempt',
        );
      }
    });

    test('a suppressed menu and a devtools panel are their own strikes', () {
      expect(
        strikeForWebGuardEvent(WebGuardEvent.contextMenuBlocked),
        ExamStrike.rightClickBlocked,
      );
      expect(
        strikeForWebGuardEvent(WebGuardEvent.devtoolsDetected),
        ExamStrike.devtoolsDetected,
      );
    });

    test('the only non-strike guard event is fullscreen re-entry', () {
      // Entering fullscreen closes a pending countdown; it is bookkeeping, never
      // a violation.
      final unstruck = WebGuardEvent.values
          .where((event) => strikeForWebGuardEvent(event) == null)
          .toSet();
      expect(unstruck, <WebGuardEvent>{WebGuardEvent.fullscreenEntered});
    });
  });

  group('device-integrity findings', () {
    test('a second display and a virtual camera are separate strikes', () {
      expect(
        strikeForHardwareFinding(HardwareFinding.secondaryDisplay),
        ExamStrike.secondaryDisplay,
      );
      expect(
        strikeForHardwareFinding(HardwareFinding.virtualCamera),
        ExamStrike.virtualCamera,
      );
    });

    test('every finding is mapped (a new one cannot slip through unmapped)', () {
      for (final finding in HardwareFinding.values) {
        expect(
          strikeForHardwareFinding(finding),
          isNotNull,
          reason: '$finding needs a strike',
        );
      }
    });
  });
}
