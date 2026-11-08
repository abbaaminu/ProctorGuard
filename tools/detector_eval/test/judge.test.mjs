/**
 * The judge.
 *
 * `createJudge` is a port of `WebFacePresenceMonitor`, so these tests are about
 * the parts a reviewer would check against the Dart: a sustained `no_face` is one
 * violation however long it lasts, a near-sideways turn reports at once, a second
 * person latches across a cooldown, and the startup grace can be switched back on.
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  DEFAULT_RULES,
  createJudge,
  judgeVerdicts,
  parsePose,
  readAppRules,
} from '../lib/judge.mjs';

/** Rules with the app's numbers and a grace of 0, overridden per test. */
const rules = (overrides = {}) => ({ ...DEFAULT_RULES, ...overrides });

test('a sustained no_face is one violation, however long it lasts', () => {
  const judge = createJudge(rules({ sustainMs: 300 }));
  assert.equal(judge.feed('no_face', 0), null);
  assert.equal(judge.feed('no_face', 200), null);
  // The sustain has elapsed: the app reports now, not at the first tick.
  assert.equal(judge.feed('no_face', 300), 'no_face');
  // ...and the episode is latched, so the next thirty ticks are not thirty reports.
  for (let at = 400; at <= 3000; at += 100) assert.equal(judge.feed('no_face', at), null);
});

test('a face coming back re-arms the episode', () => {
  const judge = createJudge(rules());
  judge.feed('no_face', 0);
  assert.equal(judge.feed('no_face', 300), 'no_face');
  assert.equal(judge.feed('centered', 500), null);
  assert.equal(judge.feed('no_face', 600), null);
  assert.equal(judge.feed('no_face', 900), 'no_face');
});

test('looking_away waits for the sustain, and pose: past the immediate angle does not', () => {
  const sustained = createJudge(rules({ sustainMs: 300 }));
  assert.equal(sustained.feed('looking_away', 0), null);
  assert.equal(sustained.feed('looking_away', 299), null);
  assert.equal(sustained.feed('looking_away', 300), 'looking_away');

  // A near-sideways head is unambiguous on the first detection, so the sustain is
  // skipped rather than filled.
  const immediate = createJudge(rules({ sustainMs: 300, immediateYawDegrees: 30 }));
  assert.equal(immediate.feed('pose:45,0', 0), 'looking_away');
  // Just over the look-away angle but under the immediate one still waits - 20 deg
  // against the app's 15 / 30 pair.
  const nearly = createJudge(rules({ immediateYawDegrees: 30 }));
  assert.equal(nearly.feed('pose:20,0', 0), null);
  assert.equal(nearly.feed('pose:20,0', 300), 'looking_away');
});

test('the pose gate is symmetric on both axes', () => {
  // `Math.abs()` on the yaw and the pitch, like the Dart: how far the head went is
  // the evidence, which way it went is not. The 15 / 15 pair is what makes "either
  // way" the same rule rather than two rules 7 degrees apart.
  for (const [there, back] of [
    ['pose:20,0', 'pose:-20,0'],
    ['pose:0,20', 'pose:0,-20'],
  ]) {
    const judge = createJudge(rules({ sustainMs: 300 }));
    assert.equal(judge.feed(there, 0), null);
    assert.equal(judge.feed(there, 300), 'looking_away', `${there} should report`);
    const mirrored = createJudge(rules({ sustainMs: 300 }));
    assert.equal(mirrored.feed(back, 0), null);
    assert.equal(mirrored.feed(back, 300), 'looking_away', `${back} should report`);
  }
});

test('a pose inside the box ends the episode and re-arms it', () => {
  const judge = createJudge(rules());
  assert.equal(judge.feed('pose:40,0', 0), 'looking_away');
  assert.equal(judge.feed('pose:40,0', 100), null);
  // Centred again: the episode is over, so the next turn is a new one.
  assert.equal(judge.feed('pose:0,0', 150), null);
  // Pitch counts as much as yaw: looking down at a phone is looking away, and it
  // still has to last the sustain.
  assert.equal(judge.feed('pose:-2,-25', 200), null);
  assert.equal(judge.feed('pose:-2,-25', 500), 'looking_away');
});

test('multiple_faces reports once and latches across the cooldown', () => {
  const judge = createJudge(rules({ multipleFacesCooldownMs: 30000 }));
  assert.equal(judge.feed('multiple_faces', 0), 'multiple_faces');
  for (let at = 1000; at <= 20000; at += 1000) {
    assert.equal(judge.feed('multiple_faces', at), null);
  }
  // Still latched: the second person never left.
  assert.equal(judge.feed('centered', 29000), null);
  assert.equal(judge.feed('multiple_faces', 30000), null);
  // The cooldown is measured from the last sighting, so only a centred tick more
  // than 30 s after it clears the latch...
  assert.equal(judge.feed('centered', 60001), null);
  // ...and the next report is a new episode.
  assert.equal(judge.feed('multiple_faces', 60500), 'multiple_faces');
});

test('a second person ends the single-face episodes rather than pausing them', () => {
  const judge = createJudge(rules());
  judge.feed('no_face', 0);
  assert.equal(judge.feed('no_face', 300), 'no_face');
  assert.equal(judge.feed('multiple_faces', 400), 'multiple_faces');
  // Back to one face: a fresh no_face episode has to sustain again.
  assert.equal(judge.feed('no_face', 500), null);
  assert.equal(judge.feed('no_face', 800), 'no_face');
});

test('a face appearing ends an away episode without needing a report', () => {
  const judge = createJudge(rules());
  assert.equal(judge.feed('looking_away', 0), null);
  // Without a face there is no head pose to judge, so the away clock is dropped.
  assert.equal(judge.feed('no_face', 100), null);
  assert.equal(judge.feed('looking_away', 200), null);
  assert.equal(judge.feed('looking_away', 500), 'looking_away');
});

test('the startup grace drops what it hears, including the sustain clock', () => {
  const judge = createJudge(rules({ graceMs: 5000 }));
  assert.equal(judge.feed('no_face', 0), null);
  assert.equal(judge.feed('no_face', 4999), null);
  // The clock starts at the first tick *after* the grace, not before it.
  assert.equal(judge.feed('no_face', 5000), null);
  assert.equal(judge.feed('no_face', 5299), null);
  assert.equal(judge.feed('no_face', 5300), 'no_face');
});

test('an unknown message is ignored, and does not end an episode', () => {
  const judge = createJudge(rules());
  judge.feed('no_face', 0);
  assert.equal(judge.feed('blink', 100), null);
  assert.equal(judge.feed('', 150), null);
  assert.equal(judge.feed('pose:not,a,number', 200), null);
  assert.equal(judge.feed('no_face', 300), 'no_face');
});

test('parsePose reads a pair, clamps it and refuses anything else', () => {
  assert.deepEqual(parsePose('45,-10'), { yaw: 45, pitch: -10 });
  assert.deepEqual(parsePose(' 0 , 0 '), { yaw: 0, pitch: 0 });
  // Clamped, not rejected: ±180 is a head that is definitely not facing the screen.
  assert.deepEqual(parsePose('900,-900'), { yaw: 180, pitch: -180 });
  assert.equal(parsePose(''), null);
  assert.equal(parsePose('45'), null);
  assert.equal(parsePose('45,0,0'), null);
  assert.equal(parsePose('left,right'), null);
  assert.equal(parsePose(','), null);
});

test('judgeVerdicts stamps each episode with the clip time it happened', () => {
  const actions = judgeVerdicts(
    [
      { message: 'no_face', t: 0 },
      { message: 'no_face', t: 0.2 },
      { message: 'no_face', t: 0.4 },
      { message: 'centered', t: 1.0 },
      { message: 'looking_away', t: 2.0 },
      { message: 'looking_away', t: 2.4 },
    ],
    rules({ sustainMs: 300 }),
  );
  assert.deepEqual(actions, [
    { action: 'no_face', t: 0.4 },
    // Two seconds in is when the turn began, not when the app reported it: the
    // stamp is the tick that crossed the sustain.
    { action: 'looking_away', t: 2.4 },
  ]);
});

test('readAppRules reads the numbers out of the Dart that states them', () => {
  const dir = new URL('../../../mobile/lib/core/services/', import.meta.url);
  const sources = {
    thresholdsSource: readFileSync(new URL('proctoring_thresholds.dart', dir), 'utf8'),
    presenceSource: readFileSync(new URL('web_face_presence.dart', dir), 'utf8'),
  };
  const app = readAppRules(sources);

  for (const [key, value] of Object.entries(app)) {
    assert.equal(typeof value, 'number', `${key} should be a number`);
    assert.ok(Number.isFinite(value) && value >= 0, `${key} should be a sane rule`);
  }
  assert.ok(app.sustainMs > 0, 'the app sustains an episode before reporting');
  assert.ok(app.graceMs > 0, 'the app ignores the start of an attempt');

  // The evaluation's default is not the app's grace, and that difference is the
  // only place the two disagree.
  assert.equal(DEFAULT_RULES.graceMs, 0);
  assert.deepEqual(
    { ...app, graceMs: 0 },
    { ...DEFAULT_RULES },
    'DEFAULT_RULES has drifted from the Dart',
  );
});

test('readAppRules fails loudly when a constant is renamed', () => {
  assert.throws(
    () => readAppRules({ thresholdsSource: 'const x = 1;', presenceSource: 'const y = 1;' }),
    /renamed\?/,
  );
});
