import 'dart:collection';

import 'proctoring_thresholds.dart';

/// The rolling half of the look-away rule: **short glances that never last
/// [lookAwaySustain] are still `looking_away` when they keep coming back inside
/// [lookAwayBurstWindow].**
///
/// `MediaPipeProctoringService` and `WebFacePresenceMonitor` both judge a turned
/// head, one from camera frames and one from a page's verdicts, and they have to
/// agree - an appeal cannot be decided by which device the student sat in front
/// of. So the window lives here, once, and both hosts feed the same class instead
/// of each carrying its own copy of the arithmetic:
///
///  * [observeOffScreen] is called on every verdict that says the head is past the
///    tolerances. The first one opens an episode; a later one while the episode is
///    open does not move its start.
///  * [closeEpisode] is called on the first verdict back inside the tolerances. It
///    records how long the episode lasted and answers whether that episode was the
///    one that filled the window.
///  * [abandonEpisode] is for `no_face` / `multiple_faces`: without a head there
///    is no pose to judge, so the open episode is over rather than paused, but the
///    episodes already recorded are still evidence about the student.
///  * [clear] is for a strike (the window is emptied by the strike it produced) and
///    for a counter reset.
///
/// The shape is the one `AudioNoiseDetector` uses for repeated noise, because the
/// two rules are the same question about different sensors: a run of evidence that
/// never fills the sustained window still means something when it keeps returning.
///
/// Three details are worth reading before changing a number:
///
///  * **A run that reached [lookAwaySustain] is not recorded here.** At that length
///    the sustained rule owns it - it has either produced its strike or been
///    deliberately suppressed - and banking its seconds would let one turn be two
///    strikes.
///  * **A run shorter than [minEpisode] is not counted as an episode, but it is
///    still measured**: it adds to [offScreenTimeInWindow], exactly as a fragment
///    of speech adds to the audio total. It has to. Three episodes of the minimum
///    length are 1.5 s, so if the total only saw runs of [minEpisode] or longer, the
///    three-episode count would fire long before [cumulative] could, and the total
///    would be unreachable code. A blink or a single bad Euler estimate is still
///    nothing: it is a fraction of a second, and a minute of them is the shape this
///    rule is for, not one of them.
///  * **A strike empties the window** ([clear], called by the host when this class
///    reports). Otherwise the next glance would arrive with the evidence already
///    spent and every glance after it would be its own strike, which is the stacking
///    the server's three-strike rule exists to prevent.
///
/// The clock is the host's (`MediaPipeProctoringService` and
/// `WebFacePresenceMonitor` both take one), and it has to run forwards: the queue is
/// pruned from its oldest entry, so a caller that can step backwards in time would
/// see evidence that should have aged out. Both hosts use `DateTime.now` or a test
/// clock, so that is a statement about the contract, not a hazard in the app.
class LookAwayBurstWindow {
  /// A window over episodes that are shorter than [sustain].
  ///
  /// The defaults are the shared constants, so neither host can restate a number
  /// that the other one - or the docs - does not agree with.
  LookAwayBurstWindow({
    this.minEpisode = lookAwayMinEpisode,
    this.window = lookAwayBurstWindow,
    this.episodeCount = lookAwayBurstCount,
    this.cumulative = lookAwayBurstCumulative,
    this.sustain = lookAwaySustain,
  })  : assert(
          minEpisode > Duration.zero,
          'a zero minimum would let one frame count as a glance',
        ),
        assert(
          window > Duration.zero,
          'a zero window would never hold two episodes at once',
        ),
        assert(
          episodeCount > 0,
          'a zero count would report the first glance of the sitting',
        ),
        assert(
          cumulative > Duration.zero,
          'a zero total would report on the first frame off screen',
        ),
        assert(
          cumulative < window,
          'a total as long as the window would mean a whole minute off screen',
        ),
        assert(
          window > minEpisode * episodeCount,
          'the counted episodes have to fit inside the window',
        );

  /// How long a run has to last before it counts as one episode.
  ///
  /// Shorter runs are still measured for [cumulative]; they simply cannot be one
  /// of the [episodeCount] episodes. See the class doc.
  final Duration minEpisode;

  /// The rolling window the episodes are counted in.
  final Duration window;

  /// How many counted episodes inside [window] are one `looking_away`.
  final int episodeCount;

  /// How much off-screen time inside [window] is one `looking_away`, however it
  /// was divided up.
  final Duration cumulative;

  /// The length at which the sustained rule takes over, and a closed run stops
  /// being recorded here.
  ///
  /// A host whose sustain is not longer than [minEpisode] has no room for this
  /// rule at all (a run long enough to count would also be the sustained rule's),
  /// so the window stays empty. That is a degenerate configuration, not an error:
  /// the engine allows a zero sustain, and a rule that cannot speak must not
  /// throw.
  final Duration sustain;

  final ListQueue<_LookAwayEpisode> _episodes = ListQueue<_LookAwayEpisode>();

  DateTime? _openSince;

  /// Whether an episode is open right now (a head that is still off screen).
  bool get hasOpenEpisode => _openSince != null;

  /// How many counted episodes the window holds at [at].
  ///
  /// Exposed for tests and for the diagnostics a host could show, the way
  /// `AudioNoiseDetector.burstCountInWindow` is: it is the number that says *why*
  /// a student who keeps glancing has not been reported yet.
  int episodesInWindow(DateTime at) {
    _prune(at);
    return _episodes.where((episode) => episode.counted).length;
  }

  /// How much off-screen time the window holds at [at], including the episode
  /// that is still open and the fragments too short to count as episodes.
  ///
  /// Measured against [at] rather than trusting the queue to be pruned, so it is
  /// honest between verdicts: an episode that began a second ago reads as a
  /// second before anything closes it.
  Duration offScreenTimeInWindow(DateTime at) {
    var total = Duration.zero;
    for (final episode in _episodes) {
      if (at.difference(episode.endedAt) > window) continue;
      total += episode.duration;
    }
    final startedAt = _openSince;
    if (startedAt != null) {
      final open = at.difference(startedAt);
      // Past the sustain the other rule owns the run (and a host that reports it
      // clears this window anyway), so stop growing the total with it rather than
      // double-count seconds that are already a strike.
      if (open > Duration.zero && open < sustain) total += open;
    }
    return total;
  }

  /// Records that the head is off screen at [at] and answers whether the window
  /// is now full.
  ///
  /// The first call opens the episode; the rest only age it. Returns true exactly
  /// once per window, because the caller is expected to [clear] the window when
  /// it reports - and because a caller that ignores the answer cannot make this
  /// class report twice for the same evidence.
  bool observeOffScreen(DateTime at) {
    _openSince ??= at;
    return _windowExceeded(at);
  }

  /// Closes the open episode at [at] (a verdict back inside the tolerances) and
  /// answers whether it filled the window.
  ///
  /// No open episode, a zero-length run, a run shorter than [minEpisode] or a run
  /// that reached [sustain] all return false. The short ones are still recorded
  /// for [cumulative], which is the difference between "a glance" and "a minute
  /// of glancing".
  bool closeEpisode(DateTime at) {
    final startedAt = _openSince;
    _openSince = null;
    if (startedAt == null) return false;

    final duration = at.difference(startedAt);
    if (duration <= Duration.zero) return false;

    // The sustained rule owns a run this long: see the class doc.
    if (duration >= sustain) return false;

    _episodes.addLast(
      _LookAwayEpisode(
        endedAt: at,
        duration: duration,
        counted: duration >= minEpisode,
      ),
    );
    return _windowExceeded(at);
  }

  /// Ends the open episode without recording it: a `no_face` or a second person
  /// leaves no head pose to judge, so this run is over rather than paused.
  ///
  /// The episodes already recorded stay: they are evidence about the student, not
  /// about the frame that happened to be empty.
  void abandonEpisode() {
    _openSince = null;
  }

  /// Forgets everything: the open episode and every recorded one.
  ///
  /// Called when a strike is reported (so the strike consumes its own evidence),
  /// and by a host's counter reset (a camera that stopped delivering saw nothing).
  void clear() {
    _openSince = null;
    _episodes.clear();
  }

  /// The one place the window is judged, so the two sites that can fill it - a
  /// verdict still off screen, and the verdict that closes an episode - cannot
  /// drift apart.
  bool _windowExceeded(DateTime at) {
    _prune(at);
    if (_episodes.where((episode) => episode.counted).length >= episodeCount) {
      return true;
    }
    return offScreenTimeInWindow(at) >= cumulative;
  }

  /// Drops the episodes that have fallen out of [window].
  ///
  /// Pruned on the clock rather than on new verdicts, so it happens whether or not
  /// the detector was delivering in between: a glance a minute and a half ago is
  /// not evidence for the one happening now.
  void _prune(DateTime at) {
    while (_episodes.isNotEmpty &&
        at.difference(_episodes.first.endedAt) > window) {
      _episodes.removeFirst();
    }
  }
}

/// One closed run of off-screen time, aged by its end.
///
/// [counted] is what the episode count reads; [duration] is what the cumulative
/// total reads, which is why a fragment too short to count is still stored.
class _LookAwayEpisode {
  const _LookAwayEpisode({
    required this.endedAt,
    required this.duration,
    required this.counted,
  });

  final DateTime endedAt;
  final Duration duration;
  final bool counted;
}
