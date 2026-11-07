/**
 * The ramp: how many concurrent student sessions should be running at a given
 * second of the test.
 *
 * The shape is k6's `ramping-vus` stage list, because that is what anybody
 * reading a load-test result already has in their head:
 *
 *     50 -> 200 -> 500        "50:2m,200:3m,500:3m"
 *
 * Each stage names the target for the *end* of that stage and how long it takes
 * to get there; the ramp is linear from the previous target. `50:2m` therefore
 * starts at 0 and reaches 50 after two minutes, not at 50 for two minutes — the
 * reading that would make a "ramp" a plateau.
 */

export class StageError extends Error {}

const DURATION_UNITS = { s: 1, m: 60, h: 3600 };

/**
 * Parses `30s`, `2m`, `1h` or a bare number of seconds into seconds.
 *
 * Deliberately not `1m30s`: a compound duration invites a typo that reads as a
 * much shorter test than intended, and the stage list is short enough to write
 * in single units.
 */
export function parseDuration(text) {
  if (typeof text === 'number') {
    if (!Number.isFinite(text) || text <= 0) throw new StageError(`duration must be > 0, got ${text}`);
    return text;
  }
  if (typeof text !== 'string') throw new StageError(`duration must be a string, got ${typeof text}`);
  const trimmed = text.trim();
  const match = /^(\d+(?:\.\d+)?)\s*([smh]?)$/.exec(trimmed);
  if (match === null) {
    throw new StageError(`cannot read duration "${text}" — use seconds ("90"), "90s", "2m" or "1h"`);
  }
  const value = Number(match[1]) * (DURATION_UNITS[match[2]] ?? 1);
  if (value <= 0) throw new StageError(`duration must be > 0, got "${text}"`);
  return value;
}

/**
 * Parses `"50:2m,200:3m,500:3m"` into `[{ target: 50, seconds: 120 }, …]`.
 *
 * Targets must not go backwards: a ramp that steps down and up again measures
 * recovery, not capacity, and it is almost always a typo. Refusing it here
 * costs one error message; discovering it afterwards costs a wasted run.
 */
export function parseStages(spec) {
  if (typeof spec !== 'string' || spec.trim() === '') {
    throw new StageError('stages are required, e.g. "50:2m,200:3m,500:3m"');
  }
  const stages = [];
  let previousTarget = 0;
  for (const part of spec.split(',')) {
    const piece = part.trim();
    if (piece === '') continue;
    const separator = piece.indexOf(':');
    if (separator === -1) {
      throw new StageError(`stage "${piece}" must look like <target>:<duration>, e.g. 200:3m`);
    }
    const targetText = piece.slice(0, separator).trim();
    const durationText = piece.slice(separator + 1).trim();
    const target = Number(targetText);
    if (!Number.isInteger(target) || target < 0) {
      throw new StageError(`stage target "${targetText}" must be a whole number of sessions, 0 or more`);
    }
    if (target < previousTarget) {
      throw new StageError(`stage targets must not decrease (${previousTarget} -> ${target}) — that measures recovery, not capacity`);
    }
    stages.push({ target, seconds: parseDuration(durationText) });
    previousTarget = target;
  }
  if (stages.length === 0) throw new StageError('stages are required, e.g. "50:2m,200:3m,500:3m"');
  return stages;
}

/** Total seconds of all stages, i.e. when the last target is reached. */
export function rampSeconds(stages) {
  return stages.reduce((total, stage) => total + stage.seconds, 0);
}

/**
 * Sessions that should be running `elapsedSeconds` into the run.
 *
 * Before the first stage this is already ramping (from 0), during a stage it
 * interpolates linearly from the previous target, and after the last stage it
 * holds the final target — the plateau a "soak at 500" is read from, without
 * needing a second mechanism.
 */
export function targetAt(stages, elapsedSeconds) {
  if (stages.length === 0) throw new StageError('no stages');
  if (!Number.isFinite(elapsedSeconds)) throw new StageError(`elapsedSeconds must be finite, got ${elapsedSeconds}`);
  if (elapsedSeconds <= 0) return 0;

  let previousTarget = 0;
  let stageStart = 0;
  for (const stage of stages) {
    const stageEnd = stageStart + stage.seconds;
    if (elapsedSeconds < stageEnd) {
      const progress = stage.seconds === 0 ? 1 : (elapsedSeconds - stageStart) / stage.seconds;
      return previousTarget + (stage.target - previousTarget) * progress;
    }
    previousTarget = stage.target;
    stageStart = stageEnd;
  }
  return previousTarget;
}

/** Human-readable one-liner for the report header. */
export function describeStages(stages) {
  return stages.map((stage) => `${stage.target}/${Math.round(stage.seconds)}s`).join(' -> ');
}
