/**
 * The app's judgement, in JavaScript.
 *
 * The page does not decide what a violation is — `WebFacePresenceMonitor` does
 * (mobile/lib/core/services/web_face_presence.dart): it sustains a `no_face` or a
 * `looking_away`, says `multiple_faces` at once and latches it, reports one episode
 * once, and judges every measured head by one rule — how far the head turned *and
 * how long it stayed there*, with no near-sideways exemption. Measuring raw page
 * verdicts instead would score a detector the app does not ship: a hundred `no_face`
 * ticks in a row are worth exactly one violation, and a clip is labelled with
 * violations.
 *
 * So this file ports that class, and reads its numbers out of the Dart source
 * rather than restating them (the way `tool/face_lab/lab.js` reads the app's CSP
 * out of `web/index.html`). If a threshold moves, the evaluation moves with it —
 * and if a constant is renamed, `readAppRules` fails loudly instead of scoring a
 * stale rule.
 */

/** The wire vocabulary of `WebFaceMessages`. */
export const MESSAGES = {
  centered: 'centered',
  noFace: 'no_face',
  lookingAway: 'looking_away',
  multipleFaces: 'multiple_faces',
  posePrefix: 'pose:',
};

/**
 * The app's rules, with `graceMs` at 0.
 *
 * The app ignores the first 5 s of an attempt while a student positions their
 * camera. A clip is not the start of an attempt: it is a window someone labelled,
 * and discarding its first five seconds would report a recall no run achieved.
 * `--grace 5` reproduces the app exactly, for the comparison worth making once.
 *
 * The two windows are the app's own pair, and they are different on purpose:
 * `lookAwaySustainMs` is the two seconds a turned head has to hold (the browser used
 * to call 300 ms "sustained", which is a blink), while `noFaceSustainMs` is how long
 * a covered or abandoned camera waits before it says so.
 */
export const DEFAULT_RULES = Object.freeze({
  // 15 degrees on both axes, judged on the absolute angle: the same pair
  // `proctoring_thresholds.dart` states, and the test below fails if they drift.
  yawDegrees: 15,
  pitchDegrees: 15,
  lookAwaySustainMs: 2000,
  noFaceSustainMs: 300,
  graceMs: 0,
  multipleFacesCooldownMs: 30000,
});

function numberIn(source, name, where) {
  const match = new RegExp(`\\b${name}\\s*=\\s*(-?\\d+(?:\\.\\d+)?)`).exec(source);
  if (!match) {
    throw new Error(`${where}: no "${name} = <number>" — renamed? the evaluation cannot use a stale rule`);
  }
  return Number(match[1]);
}

function durationIn(source, name, where) {
  const match = new RegExp(
    `this\\.${name}\\s*=\\s*const\\s+Duration\\(\\s*(milliseconds|seconds|minutes):\\s*(\\d+)\\s*\\)`,
  ).exec(source);
  if (!match) {
    throw new Error(`${where}: no "this.${name} = const Duration(...)" — renamed?`);
  }
  const scale = { milliseconds: 1, seconds: 1000, minutes: 60000 }[match[1]];
  return Number(match[2]) * scale;
}

/**
 * A top-level `const Duration <name> = Duration(<unit>: n)`.
 *
 * The shared half of the rule is a named constant in `proctoring_thresholds.dart`
 * rather than a constructor default, because both platforms quote it - so it is
 * read there, and a monitor that restated the number instead would fail this check
 * rather than drift from it.
 */
function constantDurationIn(source, name, where) {
  const match = new RegExp(
    `const\\s+Duration\\s+${name}\\s*=\\s*Duration\\(\\s*(milliseconds|seconds|minutes):\\s*(\\d+)\\s*\\)`,
  ).exec(source);
  if (!match) {
    throw new Error(`${where}: no "const Duration ${name} = Duration(...)" — renamed?`);
  }
  const scale = { milliseconds: 1, seconds: 1000, minutes: 60000 }[match[1]];
  return Number(match[2]) * scale;
}

/**
 * The thresholds, read from the Dart that states them.
 *
 * Each number comes from the file that owns it, and that split is the app's own: the
 * look-away angle and hold, and the start-up grace, are shared constants in
 * `proctoring_thresholds.dart` that both the engine and the browser quote, while a
 * browser's absence window and multi-face cooldown are the monitor's.
 *
 * @param {{ thresholdsSource: string, presenceSource: string }} sources
 * @returns {typeof DEFAULT_RULES} with the app's own grace
 */
export function readAppRules({ thresholdsSource, presenceSource }) {
  return {
    yawDegrees: numberIn(thresholdsSource, 'lookAwayYawDegrees', 'proctoring_thresholds.dart'),
    pitchDegrees: numberIn(thresholdsSource, 'lookAwayPitchDegrees', 'proctoring_thresholds.dart'),
    lookAwaySustainMs: constantDurationIn(
      thresholdsSource,
      'lookAwaySustain',
      'proctoring_thresholds.dart',
    ),
    noFaceSustainMs: durationIn(presenceSource, 'noFaceSustain', 'web_face_presence.dart'),
    graceMs: constantDurationIn(
      thresholdsSource,
      'cameraStartupGrace',
      'proctoring_thresholds.dart',
    ),
    multipleFacesCooldownMs: durationIn(
      presenceSource,
      'multipleFacesCooldown',
      'web_face_presence.dart',
    ),
  };
}

/**
 * The four verdicts, as a state machine — a direct port of
 * `WebFacePresenceMonitor.handleMessage` and the three `_on*` methods it calls.
 *
 * `feed(message, atMs)` returns the violation the app would have logged at that
 * moment, or null. `atMs` is clip time: the page reports the clip's own
 * `currentTime` with every verdict, so a stuttering decoder shifts both the
 * evidence and the timeline together instead of inventing a look-away.
 */
export function createJudge(rules = DEFAULT_RULES) {
  const awaySustain = rules.lookAwaySustainMs;
  const missingSustain = rules.noFaceSustainMs;
  const grace = rules.graceMs;
  const cooldown = rules.multipleFacesCooldownMs;
  let awaySince = null;
  let missingSince = null;
  let secondPersonAt = null;
  let awayFlagged = false;
  let missingFlagged = false;
  let multiFlagged = false;

  function endMultiFace(now) {
    if (!multiFlagged) return;
    if (secondPersonAt !== null && now - secondPersonAt < cooldown) return;
    multiFlagged = false;
    secondPersonAt = null;
  }

  function onMissing(now) {
    // Without a face there is no head pose to judge, so an away episode is over
    // (and re-armable) rather than paused.
    awaySince = null;
    awayFlagged = false;
    if (missingSince === null) missingSince = now;
    if (missingFlagged) return null;
    if (now - missingSince < missingSustain) return null;
    missingFlagged = true;
    return MESSAGES.noFace;
  }

  function onAway(now) {
    missingSince = null;
    missingFlagged = false;
    endMultiFace(now);
    if (awaySince === null) awaySince = now;
    if (awayFlagged) return null;
    if (now - awaySince < awaySustain) return null;
    awayFlagged = true;
    return MESSAGES.lookingAway;
  }

  function onCentered(now) {
    awaySince = null;
    missingSince = null;
    awayFlagged = false;
    missingFlagged = false;
    endMultiFace(now);
    return null;
  }

  return {
    feed(message, atMs) {
      const text = String(message ?? '').trim().toLowerCase();
      if (text === '') return null;
      if (atMs < grace) return null;

      if (text === MESSAGES.multipleFaces) {
        secondPersonAt = atMs;
        if (multiFlagged) return null;
        multiFlagged = true;
        // One face is no longer the subject: the single-face episodes start over.
        awaySince = null;
        missingSince = null;
        awayFlagged = false;
        missingFlagged = false;
        return MESSAGES.multipleFaces;
      }
      if (text === MESSAGES.noFace) return onMissing(atMs);
      if (text === MESSAGES.lookingAway) return onAway(atMs);
      if (text === MESSAGES.centered) return onCentered(atMs);

      const pose = text.startsWith(MESSAGES.posePrefix)
        ? parsePose(text.slice(MESSAGES.posePrefix.length))
        : null;
      // An unrecognised message is a detector speaking a language this app does not
      // know. Ignoring it is the only honest reading: it is not evidence.
      if (pose === null) return null;

      // One rule for a measured head, at every angle past the gate: how far it
      // turned is the gate, how long it stayed there is the finding. The
      // near-sideways shortcut that used to sit here (past 30 degrees reported on
      // sight) is gone from the monitor, so it is gone from its port.
      if (Math.abs(pose.yaw) > rules.yawDegrees || Math.abs(pose.pitch) > rules.pitchDegrees) {
        return onAway(atMs);
      }
      return onCentered(atMs);
    },
  };
}

/**
 * `yaw,pitch` in degrees, or null when the numbers are not numbers.
 *
 * Null is deliberate rather than `(0, 0)`: a malformed pose read as "centred"
 * would quietly end a real looking-away episode.
 */
export function parsePose(body) {
  const parts = String(body).split(',');
  if (parts.length !== 2) return null;
  const yawCell = parts[0].trim();
  const pitchCell = parts[1].trim();
  if (yawCell === '' || pitchCell === '') return null;
  const yaw = Number(yawCell);
  const pitch = Number(pitchCell);
  if (!Number.isFinite(yaw) || !Number.isFinite(pitch)) return null;
  // Clamped rather than rejected: a detector reporting ±180 is describing a head
  // that is definitely not facing the screen.
  const clamp = (value) => Math.max(-180, Math.min(180, value));
  return { yaw: clamp(yaw), pitch: clamp(pitch) };
}

/**
 * A clip's page verdicts → the violations the app would have logged.
 *
 * @param {{ message: string, t: number }[]} verdicts clip time in seconds
 * @param {typeof DEFAULT_RULES} [rules]
 * @returns {{ action: string, t: number }[]}
 */
export function judgeVerdicts(verdicts, rules = DEFAULT_RULES) {
  const judge = createJudge(rules);
  const actions = [];
  for (const verdict of verdicts) {
    const atMs = Number(verdict.t) * 1000;
    if (!Number.isFinite(atMs)) continue;
    const action = judge.feed(verdict.message, atMs);
    if (action !== null) actions.push({ action, t: Number(verdict.t) });
  }
  return actions;
}

