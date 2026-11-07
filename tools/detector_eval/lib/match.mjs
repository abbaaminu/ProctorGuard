/**
 * Windows in, precision/recall/FPR out.
 *
 * The scoring unit is the *window*, not the frame and not the detection:
 *
 *  * a `label = 1` window is a hit if at least one action the app logged falls
 *    inside it (or within `tolerance` of its edges), and a miss otherwise — one
 *    episode inside one labelled episode is one hit, however many times it fired;
 *  * a `label = 0` window is a false positive if any action falls inside it, and a
 *    true negative otherwise. This is the only place a false-positive *rate* can
 *    come from, so a folder with no negatives measures recall and calls it
 *    accuracy;
 *  * an action outside every window of its own action is a *stray*: the detector
 *    said something the labeller did not label. It is reported, and it is not
 *    scored — it may be the detector being right about something nobody marked,
 *    and folding it into precision would be scoring the spreadsheet.
 *
 * The tolerance exists because an episode's edges are a judgement call: a head
 * starts turning a little before the labelled second, and the app reports only
 * after its sustain. Half a second either side is the width of that uncertainty,
 * and it is one flag so a reviewer can see how much of the score depends on it.
 */

export const DEFAULT_TOLERANCE_SECONDS = 0.5;

/**
 * Fills in a blank `end` from the clip's own duration, read during the replay.
 *
 * Doing it after the fact is what lets a labeller write `3.0,,1` for "from three
 * seconds to the end" without knowing the file's length to the frame.
 */
export function resolveEnds(rows, durations) {
  return rows.map((row) => {
    if (row.end !== null) return row;
    const duration = durations[row.clip];
    if (!Number.isFinite(duration)) {
      throw new Error(`line ${row.line}: no end, and the duration of ${row.clip} is unknown`);
    }
    if (duration <= row.start) {
      throw new Error(
        `line ${row.line}: start ${row.start}s is past the end of ${row.clip} (${duration.toFixed(2)}s)`,
      );
    }
    return { ...row, end: duration };
  });
}

function overlaps(a, b) {
  return a.start < b.end && b.start < a.end;
}

/**
 * One clip's windows against the actions the app logged for it.
 *
 * @param {object[]} rows        that clip's label rows, ends resolved
 * @param {{ action: string, t: number }[]} actions
 * @param {{ tolerance?: number }} [options]
 * @returns {{ segments: object[], strays: object[] }}
 */
export function evaluateClip(rows, actions, { tolerance = DEFAULT_TOLERANCE_SECONDS } = {}) {
  const positives = rows.filter((row) => row.label);
  // Overlapping positive windows of the same action would make "was this window
  // caught" ambiguous, and one action would count twice in the same second.
  for (let i = 0; i < positives.length; i += 1) {
    for (let j = i + 1; j < positives.length; j += 1) {
      if (positives[i].action !== positives[j].action) continue;
      if (!overlaps(positives[i], positives[j])) continue;
      throw new Error(
        `lines ${positives[i].line} and ${positives[j].line}: two ${positives[i].action} windows overlap — ` +
          'one episode cannot be two labels',
      );
    }
  }

  const segments = rows.map((row) => ({ row, detections: [] }));
  const strays = [];

  for (const action of actions) {
    const own = segments.filter((segment) => segment.row.action === action.action);
    const landed = own.filter(
      (segment) =>
        action.t >= segment.row.start - tolerance && action.t <= segment.row.end + tolerance,
    );
    if (landed.length > 0) {
      // The nearest window of its own action owns the detection; two windows close
      // enough to both accept it are an overlap this cannot happen on (refused
      // above for positives, and a negative beside a positive is a labelling that
      // the tolerance is allowed to blur).
      const nearest = landed.reduce((best, segment) =>
        Math.abs(action.t - (segment.row.start + segment.row.end) / 2) <
        Math.abs(action.t - (best.row.start + best.row.end) / 2)
          ? segment
          : best,
      );
      nearest.detections.push(action);
      continue;
    }
    strays.push(action);
  }

  return {
    segments: segments.map(({ row, detections }) => ({
      row,
      positive: row.label,
      detections,
      hit: row.label ? detections.length > 0 : false,
      falsePositive: row.label ? false : detections.length > 0,
    })),
    strays,
  };
}


/**
 * Segment results → the numbers a report prints.
 *
 * `precision` is computed over the windows only (detections that landed in a
 * labelled window against detections that landed in a negative one), because a
 * stray has no ground truth to be right or wrong about. Strays are counted and
 * shown beside the table.
 */
export function summarize(segments, strays = []) {
  const positives = segments.filter((segment) => segment.positive);
  const negatives = segments.filter((segment) => !segment.positive);
  const hits = positives.filter((segment) => segment.hit).length;
  const falsePositives = negatives.filter((segment) => segment.falsePositive).length;
  const detectedInPositives = positives.reduce((sum, segment) => sum + segment.detections.length, 0);
  const detectedInNegatives = negatives.reduce((sum, segment) => sum + segment.detections.length, 0);
  const negativeSeconds = negatives.reduce(
    (sum, segment) => sum + (segment.row.end - segment.row.start),
    0,
  );
  const positiveSeconds = positives.reduce(
    (sum, segment) => sum + (segment.row.end - segment.row.start),
    0,
  );
  const reports = detectedInPositives + detectedInNegatives;

  return {
    positives: positives.length,
    hits,
    misses: positives.length - hits,
    // With no positive window there is nothing to recall: null, not 0, so a tag
    // that only ever appears in negatives is not reported as a broken detector.
    recall: positives.length > 0 ? hits / positives.length : null,
    negatives: negatives.length,
    falsePositives,
    trueNegatives: negatives.length - falsePositives,
    fpr: negatives.length > 0 ? falsePositives / negatives.length : null,
    detections: reports,
    detectedInPositives,
    detectedInNegatives,
    precision: reports > 0 ? detectedInPositives / reports : null,
    falsePositivesPerMinute:
      negativeSeconds > 0 ? detectedInNegatives / (negativeSeconds / 60) : null,
    strays: strays.length,
    positiveSeconds,
    negativeSeconds,
  };
}

/**
 * The whole run, then one row per tag — `all` first.
 *
 * A tag is a slice, not a category: a window tagged `lighting=dim;glasses=yes`
 * counts in both rows, which is the point (a slice is a question like "does dim
 * light cost recall?"). Rows for tags with no positives or no negatives carry a
 * null rate rather than a zero.
 */
export function byTag(segments) {
  const rows = [{ tag: 'all', ...summarize(segments) }];
  const tags = [...new Set(segments.flatMap((segment) => segment.row.tagList))].sort();
  for (const tag of tags) {
    const subset = segments.filter((segment) => segment.row.tagList.includes(tag));
    rows.push({ tag, ...summarize(subset) });
  }
  return rows;
}

/**
 * The same table, per action.
 *
 * Actions are kept apart because they are not interchangeable: a detector that
 * misses every `multiple_faces` and catches every `looking_away` has one number
 * that looks fine and one that would fail an exam.
 */
export function byAction(segments, strays = []) {
  const actions = [...new Set(segments.map((segment) => segment.row.action))].sort();
  return actions.map((action) => {
    const subset = segments.filter((segment) => segment.row.action === action);
    const actionStrays = strays.filter((stray) => stray.action === action);
    return { action, ...summarize(subset, actionStrays) };
  });
}

/** Median of a list, for "how late was the report" — null for an empty list. */
export function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}
