import '../../../core/services/hardware_integrity_service.dart';
import '../../../core/services/web_guards.dart';
import '../../proctoring/presentation/providers/proctoring_provider.dart';

/// The proctoring strike an event is evidence of.
///
/// One callback from the browser guard carries two different families of
/// events, and the device-integrity probe reports its own findings: turning
/// each of those into the violation it means used to be two `switch` statements
/// buried inside the exam page, where the rule could only be exercised by
/// standing up a whole session. The mapping is pure data now — [strikeForWebGuardEvent]
/// and [strikeForHardwareFinding] take an event and answer with the strike (or
/// `null` for bookkeeping that is not a strike), so it can be tested on its own
/// (see `test/exam_strike_mapping_test.dart`) and the page only has to apply it.
enum ExamStrike {
  /// Leaving the exam surface: a tab switch, a window blur, or a fullscreen
  /// exit whose grace window ran out.
  appMinimized,

  /// A blocked copy / cut / paste: the three DOM events share one behaviour.
  copyPasteAttempt,

  /// A suppressed context menu.
  rightClickBlocked,

  /// A developer-tools panel.
  devtoolsDetected,

  /// A second display attached to the device (Android only).
  secondaryDisplay,

  /// A camera that is not the device's own lens (Android only).
  virtualCamera,
}

/// The strike a browser-guard [event] is evidence of, or `null` when the event
/// is bookkeeping rather than a violation (entering fullscreen closes a pending
/// countdown and is never a strike).
ExamStrike? strikeForWebGuardEvent(WebGuardEvent event) => switch (event) {
  WebGuardEvent.tabHidden ||
  WebGuardEvent.windowBlurred ||
  WebGuardEvent.fullscreenExited => ExamStrike.appMinimized,
  WebGuardEvent.copyBlocked ||
  WebGuardEvent.cutBlocked ||
  WebGuardEvent.pasteBlocked => ExamStrike.copyPasteAttempt,
  WebGuardEvent.contextMenuBlocked => ExamStrike.rightClickBlocked,
  WebGuardEvent.devtoolsDetected => ExamStrike.devtoolsDetected,
  WebGuardEvent.fullscreenEntered => null,
};

/// The strike a device-integrity [finding] is evidence of.
///
/// The service reports a finding when it appears rather than while it lasts, so
/// this is a straight mapping and needs no dedupe of its own.
ExamStrike? strikeForHardwareFinding(HardwareFinding finding) => switch (finding) {
  HardwareFinding.secondaryDisplay => ExamStrike.secondaryDisplay,
  HardwareFinding.virtualCamera => ExamStrike.virtualCamera,
};

/// Records [strike] on [notifier] — the single place the strike-to-`report*`
/// wiring lives, so the page no longer needs a switch of its own.
void applyStrike(ProctoringNotifier notifier, ExamStrike strike) {
  switch (strike) {
    case ExamStrike.appMinimized:
      notifier.reportAppMinimized();
    case ExamStrike.copyPasteAttempt:
      notifier.reportCopyPasteAttempt();
    case ExamStrike.rightClickBlocked:
      notifier.reportRightClickBlocked();
    case ExamStrike.devtoolsDetected:
      notifier.reportDevtoolsDetected();
    case ExamStrike.secondaryDisplay:
      notifier.reportSecondaryDisplayDetected();
    case ExamStrike.virtualCamera:
      notifier.reportVirtualCameraDetected();
  }
}
