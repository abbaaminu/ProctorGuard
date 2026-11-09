import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:proctorguard/core/services/mediapipe_proctoring_service.dart';
import 'package:proctorguard/core/services/offline_sync_service.dart';
import 'package:proctorguard/core/services/proctoring_heartbeat.dart';
import 'package:proctorguard/features/exam/domain/entities/exam.dart';
import 'package:proctorguard/features/exam/domain/entities/exam_submit_result.dart';
import 'package:proctorguard/features/exam/domain/entities/question.dart';
import 'package:proctorguard/features/exam/domain/entities/submission.dart';
import 'package:proctorguard/features/exam/domain/repositories/exam_repository.dart';
import 'package:proctorguard/features/proctoring/domain/entities/heartbeat.dart';
import 'package:proctorguard/features/proctoring/domain/entities/proctoring_risk.dart';
import 'package:proctorguard/features/proctoring/domain/entities/violation.dart';
import 'package:proctorguard/features/proctoring/domain/repositories/proctoring_repository.dart';
import 'package:proctorguard/features/proctoring/presentation/providers/proctoring_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// Anti-cheating inputs that do not come from the camera: the kiosk escape
/// callback (`lock_task_channel`), the audio-noise hook, and the 3-strike
/// escalation they feed into. Everything is driven through fakes — no device,
/// no Supabase.
void main() {
  // The notifier attaches a WidgetsBindingObserver on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('kiosk escape', () {
    test('a lock task escape is logged as app_minimized', () async {
      final repo = _RecordingProctoringRepository();
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(repo.violations.single.type, ViolationType.appMinimized);
      expect(repo.violations.single.type.dbValue, 'app_minimized');
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.lastViolation, ViolationType.appMinimized);
      expect(notifier.state.showViolationOverlay, isTrue);
    });
  });

  group('audio noise hook', () {
    test('a classified strike is logged as audio_noise', () async {
      final repo = _RecordingProctoringRepository();
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      // The rules (calibration, sustain, cooldown) live in `AudioNoiseDetector`
      // and are tested there; what this asserts is the *join*: a classified
      // episode becomes an `audio_noise` violation through the same ladder as
      // every other signal. `AudioMonitoringNotifier` is the production caller.
      notifier.reportAudioNoise();
      await pumpEventQueue();

      expect(repo.violations.single.type, ViolationType.audioNoise);
      expect(repo.violations.single.type.dbValue, 'audio_noise');
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.showViolationOverlay, isTrue);
    });

    test('the notifier declares no second noise rule', () {
      // Regression guard for the deleted `reportAudioLevel(double)`: it was an
      // independent threshold + sustain implementation while the shipping audio
      // path classified with `AudioNoiseDetector`, i.e. two rules for one event.
      // The source is the contract here - a re-added method would compile fine and
      // only show up as behaviour drift months later.
      //
      // The match is on the *declaration*, not the name: the doc comment on
      // `reportAudioNoise` names the deleted method to explain why it is gone.
      final source = File(
        'lib/features/proctoring/presentation/providers/proctoring_provider.dart',
      );
      if (!source.existsSync()) return; // running from outside the package root

      final text = source.readAsStringSync();
      expect(
        text,
        isNot(matches(RegExp(r'void\s+reportAudioLevel\b'))),
        reason: 'raw levels must be classified by AudioNoiseDetector, not here',
      );
      expect(text, contains('AudioNoiseDetector'));
    });

    test('repeats inside the debounce window are one violation', () async {
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      notifier.reportAudioNoise();
      notifier.reportAudioNoise();
      await pumpEventQueue();

      expect(repo.violations, hasLength(1));
    });
  });

  group('3-strike escalation', () {
    test('a server-side disqualification ends the session and forces exit',
        () async {
      final repo = _RecordingProctoringRepository(disqualifyAfter: 1);
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(notifier.state.disqualified, isTrue);
      expect(notifier.state.showViolationOverlay, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);

      // Signals arriving after the lockout are dropped, not logged again.
      notifier.reportAudioNoise();
      notifier.reportAppMinimized();
      await pumpEventQueue();
      expect(repo.violations, hasLength(1));

      // ...and the final lockout screen cannot be dismissed, unlike a warning.
      notifier.dismissOverlay();
      expect(notifier.state.showViolationOverlay, isTrue);
    });

    test('the third strike auto-disqualifies', () async {
      // Longer than the notifier's 2s debounce window, so each strike lands.
      const gap = Duration(milliseconds: 2200);
      final repo = _RecordingProctoringRepository();
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized(); // strike 1: leaving the exam surface
      await Future<void>.delayed(gap);
      notifier.reportAudioNoise(); // strike 2: background noise
      await Future<void>.delayed(gap);
      notifier.reportAppMinimized(); // strike 3: disqualified
      await pumpEventQueue();

      expect(
        repo.violations.map((violation) => violation.type.dbValue).toList(),
        <String>['app_minimized', 'audio_noise', 'app_minimized'],
      );
      expect(notifier.state.warningCount, 3);
      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);
    });
  });

  group('what a warning is worth', () {
    test('a soft signal is noted, and never counted towards the threshold',
        () async {
      // `register_violation()` counts an attempt two ways at once: `warning_count`
      // is how many rows it has logged, while the ending is decided by the weighted
      // score, which only sums the types carrying `counts_toward_dq`. The chip used
      // to read the row count, so three right-clicks could announce "3 of 3
      // warnings" on an attempt the server would never close.
      //
      // The pair below is a blocked paste and a suppressed context menu - both still
      // weight 0. `audio_noise` used to sit here and no longer does: since
      // `20261108090000_looking_away_and_noise_count.sql` it is a counted strike
      // (weight 1), which the next test covers from the counted side.
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      notifier.reportRightClickBlocked();
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();

      expect(notifier.state.warningCount, 2, reason: 'two rows were logged');
      expect(
        notifier.state.countedWarnings,
        0,
        reason: 'neither weighs anything towards the server threshold',
      );
      expect(notifier.state.notedWarnings, 2);
      expect(notifier.state.underReview, isFalse);

      // A counted signal moves all three numbers - it is the only kind that can
      // bring the attempt closer to closing.
      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(notifier.state.warningCount, 3);
      expect(notifier.state.countedWarnings, 1);
      expect(notifier.state.notedWarnings, 2);
      expect(notifier.state.underReview, isFalse);
    });

    test('the counted number is the one that ends the attempt', () async {
      // Three counted signals, and the flag lands on the third: a chip reading
      // "3 of 3" is a promise about the ending, so it has to be right about when
      // the ending happens.
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(
          disqualifyAfter: 100,
          flagAfter: 3,
        ),
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized(); // counted, 1 of 3
      notifier.reportDevtoolsDetected(); // counted, 2 of 3
      notifier.reportVirtualCameraDetected(); // counted, 3 of 3 -> flagged
      await pumpEventQueue();

      expect(
        notifier.state.countedWarnings,
        ProctoringRisk.disqualificationThreshold,
      );
      expect(notifier.state.notedWarnings, 0);
      expect(notifier.state.underReview, isTrue);
    });
  });

  group('camera gate', () {
    test('gaze signals are ignored while the camera feed is offline',
        () async {
      final repo = _RecordingProctoringRepository();
      final engine = MediaPipeProctoringService(
        mockCamera: true,
        mockInterval: const Duration(milliseconds: 20),
      );
      final notifier = _notifier(proctoringRepo: repo, engine: engine);
      addTearDown(notifier.dispose);

      notifier.setCameraActive(false);
      expect(notifier.state.cameraPaused, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(repo.violations, isEmpty);
      expect(notifier.state.warningCount, 0);

      notifier.setCameraActive(true);
      expect(notifier.state.cameraPaused, isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(repo.violations, isNotEmpty);
    });

    test('no_face is a state as well as a strike, and a face clears it',
        () async {
      // The exam page blocks the paper on `faceMissing` (see
      // `EquipmentBlockOverlay`), so the flag has to track the *current* feed
      // rather than only ever being raised by a strike.
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
      );
      addTearDown(notifier.dispose);

      notifier.setCameraActive(true);
      notifier.reportGazeSignal(GazeSignal.noFace);
      await pumpEventQueue();
      expect(notifier.state.faceMissing, isTrue);
      expect(notifier.state.warningCount, 1, reason: 'still a strike too');

      // A head turned away is a face that is *present*: the strike stands, but
      // the paper is not held shut by a "no face" that is no longer true.
      notifier.reportGazeSignal(GazeSignal.lookingAway);
      await pumpEventQueue();
      expect(notifier.state.faceMissing, isFalse);

      notifier.reportGazeSignal(GazeSignal.noFace);
      notifier.reportGazeSignal(GazeSignal.centered);
      await pumpEventQueue();
      expect(notifier.state.faceMissing, isFalse);
    });

    test('a camera that drops out does not leave a stale "no face" behind',
        () async {
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
      );
      addTearDown(notifier.dispose);

      notifier.setCameraActive(true);
      notifier.reportGazeSignal(GazeSignal.noFace);
      await pumpEventQueue();
      expect(notifier.state.faceMissing, isTrue);

      // The camera is the thing that stopped, so "nobody in frame" is its finding
      // rather than the student's: the page has a separate, stricter block for a
      // dead feed, and it must not be reading a leftover flag.
      notifier.setCameraActive(false);
      expect(notifier.state.cameraPaused, isTrue);
      expect(notifier.state.faceMissing, isFalse);

      // And a signal that arrives while the feed is down cannot re-raise it.
      notifier.reportGazeSignal(GazeSignal.noFace);
      await pumpEventQueue();
      expect(notifier.state.faceMissing, isFalse);
    });
  });

  group('evidence budget', () {
    test('an identity strike overtakes a softer one waiting on the same still',
        () async {
      // The camera will not produce a still (`takePicture` on a controller that is
      // re-initialising simply never answers), so both strikes are stuck behind the
      // same dead capture - the worst case these two budgets exist for.
      final stuck = Completer<Uint8List?>();
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
        snapshotSource: () => stuck.future,
        snapshotTimeout: const Duration(milliseconds: 400),
        criticalSnapshotTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(notifier.dispose);

      // The softer strike is registered *first*, so it would win any tie...
      notifier.reportAppMinimized();
      notifier.reportGazeSignal(GazeSignal.noFace);

      await Future<void>.delayed(const Duration(milliseconds: 150));

      // ...and still reaches the server first: "nobody is in front of the camera"
      // is the strike that can stop an impostor's attempt, so it does not spend the
      // same three seconds on a photograph that a glance away spends.
      expect(
        outbox.logged.map((violation) => violation.type),
        <ViolationType>[ViolationType.noFace],
        reason: 'the softer strike is still waiting on its own, longer budget',
      );

      // Let the abandoned capture finish so no future is left dangling, and confirm
      // the softer strike goes out on its own budget afterwards.
      stuck.complete(null);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        outbox.logged.map((violation) => violation.type),
        <ViolationType>[ViolationType.noFace, ViolationType.appMinimized],
      );
      // Both went out without a picture: the capture never completed, and a
      // violation is the record while the picture is only the illustration.
      expect(
        outbox.logged.every((violation) => violation.snapshotUrl == null),
        isTrue,
      );
    });

    test('a still that arrives in time is still attached', () async {
      // The budget is a deadline, not a refusal: when the camera answers inside it,
      // the identity strike carries its photograph like any other.
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
        snapshotSource: () async => Uint8List.fromList(<int>[1, 2, 3]),
        uploadSnapshot: ({
          required String submissionId,
          required String actionType,
          required Uint8List bytes,
        }) async =>
            '$submissionId/${actionType}_1.jpg',
        criticalSnapshotTimeout: const Duration(seconds: 1),
      );
      addTearDown(notifier.dispose);

      notifier.reportGazeSignal(GazeSignal.multipleFaces);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(outbox.logged.single.type, ViolationType.multipleFaces);
      expect(outbox.logged.single.snapshotUrl, isNotNull);
    });
  });

  group('violation outbox (requirement 4)', () {
    test('a violation that could not be delivered still counts locally',
        () async {
      final outbox = _FakeOutbox(reachable: false);
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      // The strike is shown and counted even though the row is only queued on the
      // device: losing the warning UI because the network is down would be worse
      // than a count that is briefly local.
      expect(notifier.state.warningCount, 1);
      expect(notifier.state.showViolationOverlay, isTrue);
      expect(outbox.logged, hasLength(1));
      // Every event carries an id, which is what makes the retry idempotent.
      expect(outbox.logged.single.clientEventId, isNotNull);
    });

    test('a ruling delivered late raises the count but never lowers it',
        () async {
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();
      expect(notifier.state.warningCount, 1);

      outbox.emitRuling(warningCount: 2);
      await pumpEventQueue();
      expect(notifier.state.warningCount, 2);

      // A deferred ruling can be older than a live one that already arrived: it
      // must not walk the ladder back down.
      outbox.emitRuling(warningCount: 1);
      await pumpEventQueue();
      expect(notifier.state.warningCount, 2);
    });

    test('a third strike delivered late ends the attempt', () async {
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final outbox = _FakeOutbox();

      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        examRepo: examRepo,
        outbox: outbox,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      outbox.emitRuling(warningCount: 3, disqualified: true);
      await pumpEventQueue();

      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);
    });

    test('a ruling for another session is ignored', () async {
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      outbox.emitRuling(
        submissionId: 'sub-9',
        warningCount: 3,
        disqualified: true,
      );
      await pumpEventQueue();

      expect(notifier.state.disqualified, isFalse);
      expect(notifier.state.warningCount, 0);
    });
  });

  group('risk index (end to end)', () {
    test('the mix of signals drives the score, and the third strike ends it',
        () async {
      // The chain both consoles read from: a detector -> `_registerViolation` ->
      // `state.violationTypes` -> `state.risk`, which is the same object the
      // supervisor's grid and the student's own overlay render. Asserted here and
      // not only on `ProctoringRisk` because the *join* is where a regression would
      // hide: a signal that logged but never widened the evidence list would leave
      // the index reading "Low risk · 0" while the strike count climbed.
      const gap = Duration(milliseconds: 2200); // longer than the 2s debounce
      final repo = _RecordingProctoringRepository();
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      // Nothing logged yet: the one state that is not evidence of anything.
      expect(identical(notifier.state.risk, ProctoringRisk.none), isTrue);
      expect(notifier.state.risk.label, 'Low');

      notifier.reportAppMinimized(); // strike 1, one signal
      await pumpEventQueue();
      expect(notifier.state.risk.strikes, 1);
      expect(notifier.state.risk.distinctTypes, 1);
      expect(notifier.state.risk.score, 20); // 1*20
      expect(notifier.state.risk.label, 'Moderate');

      await Future<void>.delayed(gap);
      notifier.reportAudioNoise(); // strike 2, a *different* detector
      await pumpEventQueue();
      expect(notifier.state.risk.score, 50); // 2*20 + 1*10 for the mix
      expect(notifier.state.risk.label, 'High');

      await Future<void>.delayed(gap);
      notifier.reportDevtoolsDetected(); // strike 3, and a severe one
      await pumpEventQueue();

      // 3*20 + 2*10 + 15*1. The third strike is always at least "High", and this
      // is the very sentence the lockout overlay prints under the chip.
      expect(notifier.state.risk.score, 95);
      expect(notifier.state.risk.label, 'Critical');
      expect(
        notifier.state.risk.explanation,
        '3 violations across 3 signals, 1 of them serious',
      );
      expect(notifier.state.disqualified, isTrue);
    });

    test('a server count with no local evidence still scores the session',
        () async {
      // A resumed attempt - or one whose violations were logged from another
      // device - starts with an empty local evidence list and a non-zero server
      // count. An index that read 0 there would be describing a different session.
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      addTearDown(notifier.dispose);

      outbox.emitRuling(warningCount: 2);
      await pumpEventQueue();

      expect(notifier.state.violationTypes, isEmpty);
      expect(notifier.state.risk.strikes, 2);
      expect(notifier.state.risk.distinctTypes, 0); // no local mix to price
      expect(notifier.state.risk.score, 40); // 2*20
      expect(notifier.state.risk.label, 'Moderate');
    });
  });

  group('browser lockdown + device signals', () {
    test('each signal keeps its own action_type on the server', () async {
      // The enterprise set is six *different* pieces of evidence: a clipboard
      // attempt, a suppressed context menu, a developer-tools panel, a second
      // screen, a substituted camera and an idle device. All six enter through the
      // same `report*` entry points the browser guard and the integrity poll call,
      // and each has to reach the log with its own value.
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      notifier.reportRightClickBlocked();
      await pumpEventQueue();
      notifier.reportDevtoolsDetected();
      await pumpEventQueue();
      notifier.reportSecondaryDisplayDetected();
      await pumpEventQueue();
      notifier.reportVirtualCameraDetected();
      await pumpEventQueue();
      notifier.reportIdleAfk();
      await pumpEventQueue();

      expect(
        repo.violations.map((violation) => violation.type.dbValue).toList(),
        <String>[
          'copy_paste_attempt',
          'right_click_blocked',
          'devtools_detected',
          'secondary_display_detected',
          'virtual_camera_detected',
          'idle_afk',
        ],
      );
      expect(notifier.state.warningCount, 6);
      expect(notifier.state.lastViolation, ViolationType.idleAfk);
      expect(notifier.state.showViolationOverlay, isTrue);
    });

    test('the debounce is per type, not per session', () async {
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo);
      addTearDown(notifier.dispose);

      // Three *different* signals inside one 2s debounce window: all three are
      // evidence. One shared stamp (the first shape of this) would have swallowed
      // whichever arrived second.
      notifier.reportCopyPasteAttempt();
      notifier.reportRightClickBlocked();
      notifier.reportIdleAfk();
      await pumpEventQueue();
      expect(repo.violations, hasLength(3));

      // A repeat of a type already logged inside the window is the same event...
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      expect(repo.violations, hasLength(3));

      // ...while the same type after the window is a new one.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      expect(repo.violations, hasLength(4));
    });

    test('lockdown strikes count towards the same 3-strike rule', () async {
      final repo = _RecordingProctoringRepository();
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      // Three different types, so what separates them is the evidence, not the
      // debounce: the escalation rule is the same one the camera signals feed.
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();
      notifier.reportRightClickBlocked();
      await pumpEventQueue();
      expect(notifier.state.disqualified, isFalse);

      notifier.reportDevtoolsDetected();
      await pumpEventQueue();

      expect(notifier.state.warningCount, 3);
      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']);
      expect(forcedExits, 1);
    });
  });
  group('the weighted threshold (flagged for review)', () {
    test('stops the session without disqualifying it', () async {
      // The server's weighted threshold closes the paper as `flagged_for_review`:
      // the sitting is over, nothing has been decided, and a supervisor will
      // decide. The client's job is to (a) stop showing questions and (b) *not*
      // send `mark_disqualified`, because that would be this device overruling the
      // review it just asked for.
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(
          // The server never disqualifies automatically any more; only the flag.
          disqualifyAfter: 99,
          flagAfter: 3,
        ),
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      notifier.reportDevtoolsDetected();
      await pumpEventQueue();
      expect(notifier.state.underReview, isFalse);
      expect(forcedExits, 0);

      notifier.reportVirtualCameraDetected(); // the third counted signal
      await pumpEventQueue();

      expect(notifier.state.underReview, isTrue);
      expect(notifier.state.disqualified, isFalse);
      expect(notifier.state.showViolationOverlay, isTrue);
      // Nothing on this device decided anything.
      expect(examRepo.disqualified, isEmpty);
      expect(forcedExits, 1);
    });

    test('is idempotent: a later signal neither logs nor exits again', () async {
      final repo = _RecordingProctoringRepository(
        disqualifyAfter: 99,
        flagAfter: 1,
      );
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: repo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();
      expect(notifier.state.underReview, isTrue);

      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();

      // `state.ended` covers both endings, so a session under review is exactly as
      // finished as a disqualified one: no second row, no second navigation.
      expect(repo.violations, hasLength(1));
      expect(forcedExits, 1);
    });

    test('a flag delivered late by the queue still ends the session', () async {
      // The signal that crossed the threshold was logged while the device was
      // offline, so the ruling arrives on the deferred stream rather than as the
      // answer to the live call.
      final outbox = _DeferredOutbox();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized(); // parked on the wire
      await pumpEventQueue();
      expect(notifier.state.underReview, isFalse);

      outbox.emitRuling(warningCount: 3, flagged: true);
      await pumpEventQueue();

      expect(notifier.state.underReview, isTrue);
      expect(notifier.state.warningCount, 3);
      expect(forcedExits, 1);
    });

    test('the review screen cannot be dismissed with back', () async {
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(
          disqualifyAfter: 99,
          flagAfter: 1,
        ),
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();
      expect(notifier.state.underReview, isTrue);

      notifier.dismissOverlay();
      expect(notifier.state.showViolationOverlay, isTrue);
    });
  });



  group('teardown (the session that is already gone)', () {
    test('a violation still in flight at dispose does not write state', () async {
      // `proctoringProvider` is autoDispose, so the notifier is torn down while a
      // violation's round-trip is still on the wire - the student closes the exam
      // screen right after a strike. Touching `state` after that used to assert in
      // debug and silently drop the server's reconciliation in release.
      final outbox = _DeferredOutbox();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
        onForceExit: () => forcedExits++,
      );

      notifier.reportAppMinimized(); // starts the (hanging) log call
      await pumpEventQueue();
      expect(outbox.logged, hasLength(1)); // the row is already on its way

      notifier.dispose(); // the exam page was popped mid-flight
      outbox.complete(warningCount: 3, disqualified: true);
      await pumpEventQueue();

      // The session is over: no late exit fires for it (the force-exit signal is
      // read through the provider container, which is gone with the page), and -
      // the regression this test exists for - nothing throws.
      expect(forcedExits, 0);
    });

    test('a ruling from the queue is ignored after dispose', () async {
      final outbox = _DeferredOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );

      notifier.reportAppMinimized();
      await pumpEventQueue();
      outbox.complete(warningCount: 1);
      await pumpEventQueue();

      notifier.dispose();
      outbox.emitRuling(warningCount: 3, disqualified: true);
      await pumpEventQueue();

      // Passing is the assertion: the shared offline queue outlives every session
      // it fed, so a replay into a disposed notifier must not throw.
    });

    test('a strike whose evidence lands after dispose is not logged', () async {
      // The still frame is the slow part of a violation - a camera that is
      // streaming can take seconds to answer, and the upload has its own timeout
      // - so this is the teardown race that actually happens in the field: the
      // student closes the exam screen while the evidence is still being
      // collected. Carrying on from there hands the outbox an RPC (or a queued
      // replay) for a submission that has already been submitted; the count it
      // would reconcile went away with the page.
      final outbox = _FakeOutbox();
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(),
        outbox: outbox,
      );
      final snapshot = Completer<Uint8List>();
      notifier.attachSnapshotSource(() => snapshot.future);

      notifier.reportIdleAfk();
      await pumpEventQueue(); // parked on the still frame, nothing sent yet
      expect(outbox.logged, isEmpty);

      notifier.dispose(); // the exam page was popped
      snapshot.complete(Uint8List.fromList(<int>[1, 2, 3]));
      await pumpEventQueue();

      expect(outbox.logged, isEmpty); // and the row never goes out
    });
  });

  group('disqualification without a backend', () {
    test('a third strike locks the student out even when the write fails',
        () async {
      // `register_violation` already set `status = 'disqualified'` server-side, so
      // the client's `mark_disqualified` call is bookkeeping. Before the fix an
      // offline device awaited that call and never reached the forced exit: the
      // student sat in an exam that had already ended, waiting for the network to
      // tell them.
      final examRepo = _FailingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(disqualifyAfter: 1),
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.attempts, 1);
      expect(forcedExits, 1);
    });

    test('a second disqualification forces exactly one exit', () async {
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(disqualifyAfter: 1),
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      notifier.reportAppMinimized();
      await pumpEventQueue();
      // Any signal for a session that is already over is dropped by the same
      // idempotence that makes `_forceDisqualify` safe to call twice: the exam
      // page's force-exit listener is one-shot, and a second navigation would take
      // the student out of wherever they are now.
      notifier.reportCopyPasteAttempt();
      await pumpEventQueue();

      expect(forcedExits, 1);
    });

    test('two strikes in flight at once force exactly one exit', () async {
      // The guard *inside* `_forceDisqualify`, not the ones at the top of its
      // callers: two signals that arrive in the same frame both pass
      // `!state.disqualified` before either could set it, because each is parked
      // on its own RPC by then. The second one therefore lands on an attempt that
      // is already over - and without the idempotency check it writes a second
      // `mark_disqualified` and fires a second exit, navigating the student out
      // of wherever they are by now.
      final examRepo = _RecordingExamRepository();
      var forcedExits = 0;
      final notifier = _notifier(
        proctoringRepo: _RecordingProctoringRepository(disqualifyAfter: 1),
        examRepo: examRepo,
        onForceExit: () => forcedExits++,
      );
      addTearDown(notifier.dispose);

      // Two *types*, so the debounce cannot turn the second strike into a repeat
      // of the first: both are real evidence, and either one crosses the
      // threshold on its own.
      notifier.reportAudioNoise();
      notifier.reportAppMinimized();
      await pumpEventQueue();

      expect(notifier.state.disqualified, isTrue);
      expect(examRepo.disqualified, <String>['sub-1']); // one bookkeeping write
      expect(forcedExits, 1); // one lockout, one exit
    });
  });

  group('injected clock', () {
    test('the debounce window is measured on the injected clock', () async {
      // The per-type debounce is a two-second contract that used to be testable
      // only by sleeping for two seconds; with the clock injected the whole window
      // is drivable, and a future change to it cannot hide behind wall-clock
      // timing.
      var now = DateTime.utc(2026, 1, 1, 9);
      final repo = _RecordingProctoringRepository(disqualifyAfter: 100);
      final notifier = _notifier(proctoringRepo: repo, clock: () => now);
      addTearDown(notifier.dispose);

      notifier.reportIdleAfk();
      await pumpEventQueue();
      expect(repo.violations, hasLength(1));

      notifier.reportIdleAfk(); // same instant: the same event
      await pumpEventQueue();
      expect(repo.violations, hasLength(1));

      now = now.add(const Duration(seconds: 3));
      notifier.reportIdleAfk();
      await pumpEventQueue();
      expect(repo.violations, hasLength(2));

      // The detection time that travels with the row is the injected one as well:
      // that is the timestamp the supervisor's audit log is ordered by.
      expect(repo.violations.last.timestamp, now);
    });
  });

  group('liveness series (proctor_heartbeats)', () {
    test('a session beats as soon as it is constructed', () async {
      // The whole point of the feature: the first beat must not wait a cadence,
      // because a supervisor looking at a just-started attempt needs to see the
      // client is there now, not fifteen seconds from now.
      final repo = _RecordingProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      final notifier = _notifier(proctoringRepo: repo, heartbeats: service);
      addTearDown(notifier.dispose);

      await pumpEventQueue();

      expect(service.isBeating, isTrue);
      expect(service.beatsAcked, 1);
      expect(repo.heartbeats, ['sub-1 camera=true monitoring=true']);
    });

    test('a camera that is down is reported, not hidden', () async {
      // "Monitored" and "monitoring nothing" must not look the same in the
      // table: without this the coverage report cannot tell a clean sitting from
      // one where the proctor was blind the whole time.
      final repo = _RecordingProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      final notifier = _notifier(proctoringRepo: repo, heartbeats: service);
      addTearDown(notifier.dispose);
      await pumpEventQueue();

      notifier.setCameraActive(false);
      await service.beatNow();

      expect(repo.heartbeats.last, 'sub-1 camera=false monitoring=false');

      // ...and the recovery is reported too, so the series shows when the feed
      // came back rather than staying red until the attempt ends.
      notifier.setCameraActive(true);
      await service.beatNow();
      expect(repo.heartbeats.last, 'sub-1 camera=true monitoring=true');
    });

    test('a browser that can only count faces reports a weaker sitting',
        () async {
      // `monitoring_ok = camera && analysis` (see
      // `WebFaceSignalSource.analysis`). The camera is up and absence is still
      // caught, but a page with no head-pose sensor cannot support "watched" for
      // anything the student does with their head - and `monitoring_ok` is the
      // only column that can say so, because the beat itself keeps coming.
      final repo = _RecordingProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      final notifier = _notifier(proctoringRepo: repo, heartbeats: service);
      addTearDown(notifier.dispose);
      await pumpEventQueue();
      expect(repo.heartbeats.last, 'sub-1 camera=true monitoring=true');

      notifier.setFaceAnalysisAvailable(false);
      expect(notifier.faceAnalysisAvailable, isFalse);
      // A weaker sensor is not something the student did: no strike, no flag.
      expect(notifier.state.warningCount, 0);
      await service.beatNow();
      expect(repo.heartbeats.last, 'sub-1 camera=true monitoring=false');

      // And a page that got its model back (a reload that found the assets) is
      // reported too, rather than leaving the sitting red for its whole length.
      notifier.setFaceAnalysisAvailable(true);
      await service.beatNow();
      expect(repo.heartbeats.last, 'sub-1 camera=true monitoring=true');
    });

    test('a feed that comes back does not claim head-turn monitoring', () async {
      // The two are tracked separately on purpose: `setCameraActive` recomputes
      // `monitoring_ok` from both, so recovering the camera cannot quietly turn a
      // count-only sitting back into a measured one.
      final repo = _RecordingProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      final notifier = _notifier(proctoringRepo: repo, heartbeats: service);
      addTearDown(notifier.dispose);
      await pumpEventQueue();

      notifier.setFaceAnalysisAvailable(false);
      notifier.setCameraActive(false);
      await service.beatNow();
      expect(repo.heartbeats.last, 'sub-1 camera=false monitoring=false');

      notifier.setCameraActive(true);
      await service.beatNow();
      expect(repo.heartbeats.last, 'sub-1 camera=true monitoring=false');

      notifier.setFaceAnalysisAvailable(true);
      await service.beatNow();
      expect(repo.heartbeats.last, 'sub-1 camera=true monitoring=true');
    });

    test('leaving the exam stops the series', () async {
      // A beat after the page is gone would claim a session is being watched
      // when nothing is - the one lie the client can still tell cheaply.
      final repo = _RecordingProctoringRepository();
      final service = ProctoringHeartbeatService(repo);
      final notifier = _notifier(proctoringRepo: repo, heartbeats: service);
      await pumpEventQueue();
      expect(repo.heartbeats, hasLength(1));

      notifier.dispose();
      await service.beatNow(); // ignored: nothing is beating any more

      expect(service.isBeating, isFalse);
      expect(repo.heartbeats, hasLength(1));
    });
  });
}

/// Builds a notifier wired to fakes. The uploader fails loudly: with no
/// snapshot source attached, the notifier must never try to upload evidence.
ProctoringNotifier _notifier({
  required ProctoringRepository proctoringRepo,
  ExamRepository? examRepo,
  MediaPipeProctoringService? engine,
  ViolationOutbox? outbox,
  ProctoringHeartbeatService? heartbeats,
  void Function()? onForceExit,
  DateTime Function()? clock,
  SnapshotSource? snapshotSource,
  // Structurally `SnapshotUploader` (declared next to the Supabase client, which
  // this suite deliberately does not import), so a fake uploader can be injected
  // without dragging the singleton in.
  Future<String?> Function({
    required String submissionId,
    required String actionType,
    required Uint8List bytes,
  })? uploadSnapshot,
  Duration snapshotTimeout = const Duration(seconds: 3),
  Duration criticalSnapshotTimeout = const Duration(milliseconds: 1200),
}) {
  final notifier = ProctoringNotifier(
    submissionId: 'sub-1',
    proctoringRepo: proctoringRepo,
    examRepo: examRepo ?? _RecordingExamRepository(),
    engine: engine ?? MediaPipeProctoringService(),
    outbox: outbox,
    heartbeats: heartbeats,
    onForceExit: onForceExit ?? () {},
    clock: clock,
    snapshotTimeout: snapshotTimeout,
    criticalSnapshotTimeout: criticalSnapshotTimeout,
    uploadSnapshot: uploadSnapshot ??
        ({
          required String submissionId,
          required String actionType,
          required Uint8List bytes,
        }) async =>
            fail('no snapshot source is attached in these tests'),
  );
  // Attached after construction, which is also how the exam page does it: the
  // page owns the camera and hands over the grabber once frames are flowing.
  if (snapshotSource != null) notifier.attachSnapshotSource(snapshotSource);
  return notifier;
}

/// A [ViolationOutbox] a test can drive: [reachable] decides whether a live
/// delivery succeeds, and [emitRuling] is the "the queue delivered it later"
/// signal the notifier has to reconcile (see the requirement-4 group).
class _FakeOutbox implements ViolationOutbox {
  _FakeOutbox({this.reachable = true});

  final bool reachable;
  final List<Violation> logged = <Violation>[];
  final StreamController<ViolationRuling> _rulings =
      StreamController<ViolationRuling>.broadcast();

  @override
  Future<ViolationRuling?> log({
    required String submissionId,
    required Violation violation,
  }) async {
    logged.add(violation);
    if (!reachable) return null; // queued on the device, retried later
    return ViolationRuling(
      submissionId: submissionId,
      violation: violation,
      warningCount: logged.length,
      disqualified: false,
    );
  }

  void emitRuling({
    String submissionId = 'sub-1',
    required int warningCount,
    bool disqualified = false,
    bool flagged = false,
  }) =>
      _rulings.add(ViolationRuling(
        submissionId: submissionId,
        violation: Violation(
          type: ViolationType.appMinimized,
          timestamp: DateTime.utc(2026, 1, 1),
        ),
        warningCount: warningCount,
        disqualified: disqualified,
        flagged: flagged,
      ));

  @override
  Stream<ViolationRuling> get deferredRulings => _rulings.stream;
}

/// A [ViolationOutbox] whose live delivery hangs until the test releases it.
///
/// The window between "the RPC is on the wire" and "the answer arrives" is where
/// the notifier used to reconcile state after teardown; it cannot be driven with
/// an outbox that answers immediately.
class _DeferredOutbox implements ViolationOutbox {
  final List<Violation> logged = <Violation>[];
  final Completer<ViolationRuling?> _pending = Completer<ViolationRuling?>();
  final StreamController<ViolationRuling> _rulings =
      StreamController<ViolationRuling>.broadcast();

  @override
  Future<ViolationRuling?> log({
    required String submissionId,
    required Violation violation,
  }) {
    logged.add(violation);
    return _pending.future;
  }

  /// Answers the pending [log] call, as the backend would.
  void complete({
    required int warningCount,
    bool disqualified = false,
    bool flagged = false,
  }) =>
      _pending.complete(
        ViolationRuling(
          submissionId: 'sub-1',
          violation: logged.last,
          warningCount: warningCount,
          disqualified: disqualified,
          flagged: flagged,
        ),
      );

  void emitRuling({
    String submissionId = 'sub-1',
    required int warningCount,
    bool disqualified = false,
    bool flagged = false,
  }) =>
      _rulings.add(ViolationRuling(
        submissionId: submissionId,
        violation: Violation(
          type: ViolationType.appMinimized,
          timestamp: DateTime.utc(2026, 1, 1),
        ),
        warningCount: warningCount,
        disqualified: disqualified,
        flagged: flagged,
      ));

  @override
  Stream<ViolationRuling> get deferredRulings => _rulings.stream;
}

/// An exam repository whose writes fail: the offline device, an expired token, or
/// a submission row this student may no longer touch.
class _FailingExamRepository extends _RecordingExamRepository {
  /// How many times the write was attempted, so a test can tell "failed" from
  /// "never tried".
  int attempts = 0;

  @override
  Future<void> markDisqualified(String submissionId) async {
    attempts++;
    throw StateError('network is unreachable');
  }
}

/// Stands in for `supabase.rpc('register_violation', ...)`: the server owns the
/// strike count and the weighted threshold, which is what the notifier reconciles
/// its local count against.
class _RecordingProctoringRepository implements ProctoringRepository {
  _RecordingProctoringRepository({this.disqualifyAfter = 3, this.flagAfter});

  final int disqualifyAfter;

  /// Evidence count at which the fake answers `flagged: true` - the weighted
  /// threshold, in rows, for a test that only cares about the ending.
  final int? flagAfter;

  final List<Violation> violations = <Violation>[];

  /// One entry per heartbeat this fake was asked for, in the form
  /// `'<submissionId> camera=<bool> monitoring=<bool>'`: proof that the notifier
  /// opened the liveness series, and what each beat was allowed to claim.
  final List<String> heartbeats = <String>[];

  @override
  Future<({int warningCount, bool disqualified, bool flagged})> logViolation({
    required String submissionId,
    required Violation violation,
  }) async {
    violations.add(violation);
    return (
      warningCount: violations.length,
      disqualified: violations.length >= disqualifyAfter,
      // `flagAfter` lets a test reach the "under review" ending without the RPC
      // having to disqualify first; null keeps the old behaviour.
      flagged: flagAfter != null && violations.length >= flagAfter!,
    );
  }

  @override
  Future<HeartbeatAck> recordHeartbeat({
    required String submissionId,
    bool cameraOk = true,
    bool monitoringOk = true,
    String? appVersion,
    DateTime? clientTime,
    String? clientEventId,
  }) async {
    heartbeats.add('$submissionId camera=$cameraOk monitoring=$monitoringOk');
    return HeartbeatAck(
      outcome: HeartbeatOutcome.recorded,
      recordedAt: clientTime,
      beatCount: heartbeats.length,
    );
  }

  @override
  Stream<List<Map<String, dynamic>>> watchLogs(String submissionId) =>
      const Stream<List<Map<String, dynamic>>>.empty();
}

class _RecordingExamRepository implements ExamRepository {
  final List<String> disqualified = <String>[];

  @override
  Future<List<Exam>> getPublishedExams() async => <Exam>[];

  @override
  Future<List<Question>> getQuestions(String examId) async => <Question>[];

  @override
  Future<Submission> startOrResumeSubmission(String examId) =>
      throw UnimplementedError('not used in these tests');

  @override
  Future<void> saveAnswer({
    required String submissionId,
    required String questionId,
    required int selectedOption,
  }) async {}

  @override
  Future<void> saveTextAnswer({
    required String submissionId,
    required String questionId,
    required String answer,
  }) async {}

  @override
  Future<ExamSubmitResult> submitExam(String submissionId) async =>
      const ExamSubmitResult(status: SubmissionStatus.submitted);

  @override
  Future<void> markDisqualified(String submissionId) async {
    disqualified.add(submissionId);
  }
}
