import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/features/exam/presentation/providers/exam_session_controller.dart';

/// The countdown is the *client's* copy of the server's `attempt_deadline()`
/// (`supabase/schema.sql`): `started_at + duration_minutes`, **capped by the
/// paper's own `ends_at`**.
///
/// These tests pin both halves of that sentence, because the two clocks running
/// out of step is not cosmetic: the RPC refuses every answer that lands after
/// `attempt_deadline()`, so a client clock that ignored `ends_at` would show a
/// student time left in which nothing they saved could be accepted.
///
///  * [ExamSessionController.resolveDeadline] is the pure rule, tested directly
///    (no timer, no wall clock);
///  * [ExamSessionController.startCountdown] is the wiring that turns it into
///    `state.remaining`, tested through a real container so a regression that
///    stopped passing `endsAt` through would still be caught.
void main() {
  group('resolveDeadline mirrors attempt_deadline()', () {
    // One fixed "now" for the file, so nothing here reads the wall clock.
    final now = DateTime(2026, 1, 5, 12);

    test('an unscheduled paper (no ends_at) is just started_at + duration', () {
      final deadline = ExamSessionController.resolveDeadline(
        now: now,
        durationMinutes: 60,
        startedAt: DateTime(2026, 1, 5, 9),
        endsAt: null,
      );

      expect(deadline, DateTime(2026, 1, 5, 10));
    });

    test('an ends_at that arrives first is the deadline (the hard close)', () {
      final deadline = ExamSessionController.resolveDeadline(
        now: now,
        durationMinutes: 60,
        startedAt: DateTime(2026, 1, 5, 16, 50),
        endsAt: DateTime(2026, 1, 5, 17),
      );

      // `least(16:50 + 60min, 17:00)` — the paper closes at 17:00, so the
      // attempt gets ten minutes and not a fresh hour.
      expect(deadline, DateTime(2026, 1, 5, 17));
    });

    test('a later ends_at leaves the duration alone', () {
      final deadline = ExamSessionController.resolveDeadline(
        now: now,
        durationMinutes: 30,
        startedAt: DateTime(2026, 1, 5, 9),
        endsAt: DateTime(2026, 1, 5, 17),
      );

      // `least(09:30, 17:00)` — the duration is the earlier bound.
      expect(deadline, DateTime(2026, 1, 5, 9, 30));
    });

    test('a missing started_at counts from now, as the controller does', () {
      final deadline = ExamSessionController.resolveDeadline(
        now: now,
        durationMinutes: 45,
        startedAt: null,
        endsAt: null,
      );

      expect(deadline, DateTime(2026, 1, 5, 12, 45));
    });

    test('no duration (null or non-positive) means no countdown at all', () {
      expect(
        ExamSessionController.resolveDeadline(
          now: now,
          durationMinutes: null,
          startedAt: now,
          endsAt: null,
        ),
        isNull,
      );
      expect(
        ExamSessionController.resolveDeadline(
          now: now,
          durationMinutes: 0,
          startedAt: now,
          endsAt: null,
        ),
        isNull,
      );
    });

    test('both bounds at the same instant still yields that instant', () {
      final deadline = ExamSessionController.resolveDeadline(
        now: now,
        durationMinutes: 30,
        startedAt: DateTime(2026, 1, 5, 9),
        endsAt: DateTime(2026, 1, 5, 9, 30),
      );

      expect(deadline, DateTime(2026, 1, 5, 9, 30));
    });
  });

  group('startCountdown', () {
    // The clock is fixed, so `remaining` is a pure function of the deadline and
    // `now`: the periodic tick reads the same instant every second.
    final now = DateTime(2026, 1, 5, 16, 55);

    /// A controller for one attempt, driven by a clock the test moves itself.
    ///
    /// [timeUps] counts the times the clock asked the page to submit, because the
    /// distinction this group pins is *which* situation is allowed to get there: a
    /// clock that runs out in front of the student, never one that ran out while
    /// the screen was closed.
    ({ExamSessionController controller, List<bool> timeUps}) countdownFor({
      required DateTime Function() clock,
      int? durationMinutes = 60,
      DateTime? startedAt,
      DateTime? endsAt,
    }) {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final args = ExamSessionArgs(
        examId: 'exam-1',
        submissionId: 'sub-1',
        durationMinutes: durationMinutes,
        startedAt: startedAt ?? DateTime(2026, 1, 5, 16, 50),
        endsAt: endsAt,
        clock: clock,
      );
      // A listener keeps the `autoDispose` provider alive for the test; a bare
      // `read` would let Riverpod dispose it on the next microtask.
      container.listen(examSessionControllerProvider(args), (_, _) {});

      final controller =
          container.read(examSessionControllerProvider(args).notifier);
      final timeUps = <bool>[];
      controller.onTimeUp = () => timeUps.add(true);
      addTearDown(controller.stopCountdown);
      return (controller: controller, timeUps: timeUps);
    }

    Future<void> expectRemaining({
      required int durationMinutes,
      DateTime? endsAt,
      required Duration expected,
    }) async {
      final built = countdownFor(
        clock: () => now,
        durationMinutes: durationMinutes,
        endsAt: endsAt,
      );
      built.controller.startCountdown();

      expect(built.controller.state.remaining, expected);
    }

    test('shows the full duration when the paper has no window', () async {
      await expectRemaining(
        durationMinutes: 60,
        endsAt: null,
        expected: const Duration(minutes: 55),
      );
    });

    test('is cut short by the paper closing sooner', () async {
      // Started 16:50 with an hour on the paper, but it closes at 17:00: five
      // minutes left at 16:55, not fifty-five.
      await expectRemaining(
        durationMinutes: 60,
        endsAt: DateTime(2026, 1, 5, 17),
        expected: const Duration(minutes: 5),
      );
    });

    test('an attempt resumed after the close has zero left', () async {
      await expectRemaining(
        durationMinutes: 60,
        endsAt: DateTime(2026, 1, 5, 16, 54),
        expected: Duration.zero,
      );
    });

    // A reload, a crashed tab, the machine waking up the next morning: the
    // deadline went by while nobody was looking at the paper. Submitting from the
    // first tick here is how a resumed attempt got closed with none of the
    // student's answers (the cache and the offline queue had not been replayed
    // yet), so the clock reports the situation and leaves the decision to the
    // page, which can explain it before handing the attempt in.
    test('an attempt resumed past its deadline is reported, not submitted', () {
      final built = countdownFor(
        // Deadline was 17:50 (16:50 + 60), and the screen comes back at 18:30.
        clock: () => DateTime(2026, 1, 5, 18, 30),
      );

      built.controller.startCountdown();

      expect(built.controller.state.expiredOnLoad, isTrue);
      expect(built.controller.state.remaining, Duration.zero);
      expect(built.timeUps, isEmpty);
    });

    test('the deadline landing on the very first tick counts as expired', () {
      // 16:50 + 60 is 17:50: the exact instant is already too late.
      final built = countdownFor(clock: () => DateTime(2026, 1, 5, 17, 50));

      built.controller.startCountdown();

      expect(built.controller.state.expiredOnLoad, isTrue);
      expect(built.timeUps, isEmpty);
    });

    test('an attempt with time left is not reported as expired', () {
      final built = countdownFor(clock: () => DateTime(2026, 1, 5, 16, 55));

      built.controller.startCountdown();

      expect(built.controller.state.expiredOnLoad, isFalse);
      expect(built.controller.state.remaining, const Duration(minutes: 55));
      expect(built.timeUps, isEmpty);
    });

    test('a retry on a clock that is running again clears the reading', () {
      var now = DateTime(2026, 1, 5, 18, 30);
      final built = countdownFor(clock: () => now);
      built.controller.startCountdown();
      expect(built.controller.state.expiredOnLoad, isTrue);

      // The device clock was wrong, or the supervisor moved the deadline: the
      // next arming must not leave the page stuck on the "time is up" panel.
      now = DateTime(2026, 1, 5, 16, 55);
      built.controller.startCountdown();

      expect(built.controller.state.expiredOnLoad, isFalse);
      expect(built.controller.state.remaining, const Duration(minutes: 55));
    });
  });
}
