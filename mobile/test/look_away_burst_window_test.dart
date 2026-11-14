import 'package:flutter_test/flutter_test.dart';
import 'package:proctorguard/core/services/look_away_burst_window.dart';
import 'package:proctorguard/core/services/proctoring_thresholds.dart';

/// The rolling half of the look-away rule, on its own.
///
/// It is a class rather than arithmetic inside each engine because there are two
/// engines (`MediaPipeProctoringService` on a phone, `WebFacePresenceMonitor` in a
/// browser) judging the same head from two different detectors, and an appeal
/// cannot be decided by which device the student sat in front of. So the rule is
/// tested once, here, against a clock the test owns - and each engine gets a test
/// of its own that the wiring calls it, rather than a copy of this one.
void main() {
  late DateTime now;
  late LookAwayBurstWindow window;

  setUp(() {
    now = DateTime.utc(2026, 7, 1, 9);
    window = LookAwayBurstWindow();
  });

  /// One glance of [length]: the head goes off screen at the current instant and
  /// comes back after [length], then [gap] of ordinary centred time passes.
  ///
  /// Returns what the *closing* call answered, which is the only place a counted
  /// episode can fill the count.
  bool glance(
    Duration length, {
    Duration gap = const Duration(seconds: 5),
  }) {
    window.observeOffScreen(now);
    now = now.add(length);
    final filled = window.closeEpisode(now);
    now = now.add(gap);
    return filled;
  }

  group('the rolling window', () {
    test('three glances inside a minute are one looking_away', () {
      expect(
        glance(const Duration(milliseconds: 600)),
        isFalse,
        reason: 'one glance is not a pattern',
      );
      expect(glance(const Duration(milliseconds: 600)), isFalse);
      expect(
        glance(const Duration(milliseconds: 600)),
        isTrue,
        reason: 'the third glance of the minute is the finding',
      );
      expect(window.episodesInWindow(now), 3);
    });

    test('two glances are not', () {
      expect(glance(const Duration(milliseconds: 600)), isFalse);
      expect(glance(const Duration(milliseconds: 600)), isFalse);

      expect(window.episodesInWindow(now), 2);
      expect(
        window.offScreenTimeInWindow(now),
        const Duration(milliseconds: 1200),
      );
    });

    test('three glances spread over ninety seconds are not either', () {
      // The window slides: a glance is evidence for the glance just made, not for
      // one from a minute and a half ago.
      expect(
        glance(
          const Duration(milliseconds: 600),
          gap: const Duration(seconds: 39),
        ),
        isFalse,
      );
      expect(
        glance(
          const Duration(milliseconds: 600),
          gap: const Duration(seconds: 39),
        ),
        isFalse,
      );
      expect(
        glance(const Duration(milliseconds: 600)),
        isFalse,
        reason: 'the first glance has aged out of the window',
      );
      expect(window.episodesInWindow(now), 2);
    });

    test('five seconds off screen in total are one looking_away, however split',
        () {
      // Fragments too short to be an episode on their own, repeated: the shape the
      // count cannot see, and the reason the total exists beside it.
      for (var i = 0; i < 12; i++) {
        expect(
          glance(
            const Duration(milliseconds: 400),
            gap: const Duration(seconds: 4),
          ),
          isFalse,
          reason: '4.8 s is not five',
        );
      }
      expect(
        window.episodesInWindow(now),
        0,
        reason: 'none of the fragments is long enough to be a counted glance',
      );

      expect(
        glance(
          const Duration(milliseconds: 400),
          gap: const Duration(seconds: 4),
        ),
        isTrue,
        reason: 'the thirteenth fragment is the fifth second',
      );
    });

    test('a run too short to be a glance is measured but not counted', () {
      for (var i = 0; i < 3; i++) {
        expect(
          glance(const Duration(milliseconds: 300)),
          isFalse,
          reason: 'a blink is not a glance',
        );
      }
      expect(window.episodesInWindow(now), 0);
      expect(
        window.offScreenTimeInWindow(now),
        const Duration(milliseconds: 900),
        reason: 'it still spent time off screen, which is what the total reads',
      );
    });

    test('a run as long as the sustained rule is not banked here', () {
      // Two seconds is the other rule's: it has already struck (or been suppressed
      // there), so counting it again would make one turn two strikes.
      for (var i = 0; i < 3; i++) {
        expect(
          glance(lookAwaySustain),
          isFalse,
          reason: 'the sustained rule owns a run this long',
        );
      }
      expect(window.episodesInWindow(now), 0);
      expect(window.offScreenTimeInWindow(now), Duration.zero);
    });

    test('an episode that is still open counts towards the total', () {
      for (var i = 0; i < 4; i++) {
        glance(const Duration(seconds: 1));
      }
      expect(window.offScreenTimeInWindow(now), const Duration(seconds: 4));

      // The fifth second arrives while the head is still turned: the total is
      // judged on the way in, not only when the glance ends, so the strike lands
      // while the student is still doing it.
      window.observeOffScreen(now);
      now = now.add(const Duration(seconds: 1));
      expect(window.observeOffScreen(now), isTrue);
    });

    test('a strike empties the window it came from', () {
      glance(const Duration(milliseconds: 600));
      glance(const Duration(milliseconds: 600));
      expect(glance(const Duration(milliseconds: 600)), isTrue);

      window.clear();
      expect(window.episodesInWindow(now), 0);
      expect(window.offScreenTimeInWindow(now), Duration.zero);
      expect(window.hasOpenEpisode, isFalse);

      // ...so the same three glances have to be earned again rather than the next
      // one arriving with two strikes already in hand.
      expect(glance(const Duration(milliseconds: 600)), isFalse);
      expect(glance(const Duration(milliseconds: 600)), isFalse);
      expect(glance(const Duration(milliseconds: 600)), isTrue);
    });

    test('an abandoned episode is over, not paused', () {
      // `no_face` / a second person: there is no head pose to judge, so the open
      // run is dropped rather than paused - and the glances already seen stay.
      glance(const Duration(milliseconds: 600));
      window.observeOffScreen(now);
      now = now.add(const Duration(milliseconds: 1500));
      window.abandonEpisode();
      expect(window.hasOpenEpisode, isFalse);

      now = now.add(const Duration(seconds: 2));
      expect(
        glance(const Duration(milliseconds: 600)),
        isFalse,
        reason: 'the abandoned 1.5 s is no evidence, and two glances is not three',
      );
      expect(window.episodesInWindow(now), 2);
      expect(
        window.offScreenTimeInWindow(now),
        const Duration(milliseconds: 1200),
      );
    });

    test('evidence ages out on the clock, not on new verdicts', () {
      final start = now;
      glance(const Duration(milliseconds: 600), gap: Duration.zero);
      final endedAt = now;

      // Exactly a window old still counts; a millisecond older does not. Pruning
      // runs from the oldest entry, so a detector that goes quiet for the minute
      // still loses the glances it was not reporting.
      now = start.add(lookAwayBurstWindow - const Duration(milliseconds: 599));
      expect(
        window.episodesInWindow(now),
        1,
        reason: 'the glance is younger than the window',
      );

      now = endedAt.add(lookAwayBurstWindow + const Duration(milliseconds: 1));
      expect(window.episodesInWindow(now), 0);
      expect(window.offScreenTimeInWindow(now), Duration.zero);
    });

    test('an open episode starts once and does not restart on later verdicts',
        () {
      window.observeOffScreen(now);
      now = now.add(const Duration(milliseconds: 400));
      window.observeOffScreen(now);
      now = now.add(const Duration(milliseconds: 400));

      expect(window.hasOpenEpisode, isTrue);
      expect(
        window.offScreenTimeInWindow(now),
        const Duration(milliseconds: 800),
        reason: 'the episode opened at the first verdict off screen',
      );
    });

    test('a closing verdict with no open episode is ignored', () {
      expect(window.closeEpisode(now), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(window.closeEpisode(now), isFalse);
      expect(window.episodesInWindow(now), 0);
    });
  });

  group('the configuration', () {
    test('is the shared constants, not a copy of them', () {
      // A number restated here would pass every test above while drifting from the
      // file a reviewer reads, and the two engines would silently keep their own.
      expect(window.minEpisode, lookAwayMinEpisode);
      expect(window.window, lookAwayBurstWindow);
      expect(window.episodeCount, lookAwayBurstCount);
      expect(window.cumulative, lookAwayBurstCumulative);
      expect(window.sustain, lookAwaySustain);
    });

    test('cannot be configured into something that reports on nothing', () {
      // The same complaints the constants' own tests make, at the only place that
      // could restate them: a zero minimum, a zero count, or a total as long as the
      // whole window.
      expect(
        () => LookAwayBurstWindow(minEpisode: Duration.zero),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => LookAwayBurstWindow(episodeCount: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => LookAwayBurstWindow(cumulative: lookAwayBurstWindow),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => LookAwayBurstWindow(window: lookAwayMinEpisode),
        throwsA(isA<AssertionError>()),
      );
    });

    test('a sustain no longer than the minimum leaves the rule silent', () {
      // A degenerate configuration rather than an error: a host is allowed a short
      // sustain, and one whose sustained rule fires first must not throw on the way
      // to being deaf.
      final deafened = LookAwayBurstWindow(sustain: lookAwayMinEpisode);
      var reported = false;
      for (var i = 0; i < 5; i++) {
        deafened.observeOffScreen(now);
        now = now.add(lookAwayMinEpisode);
        reported = deafened.closeEpisode(now) || reported;
        now = now.add(const Duration(seconds: 1));
      }
      expect(reported, isFalse);
      expect(deafened.episodesInWindow(now), 0);
    });
  });
}
