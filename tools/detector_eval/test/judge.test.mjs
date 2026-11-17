/**
 * The judge.
 *
 * `createJudge` is a port of `WebFacePresenceMonitor`, so these tests are about
 * the parts a reviewer would check against the Dart: a sustained `no_face` is one
 * violation however long it lasts, a turned head has to hold unless it is near
 * sideways (two detections past 30 degrees), a second person latches across a
 * cooldown, the pitch gate is signed (20 degrees down, 15 up) and the startup grace
 * can be switched back on.
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
  const judge = createJudge(rules({ noFaceSustainMs: 300 }));
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

test('looking_away waits for the hold, and no ordinary angle skips it', () => {
  const sustained = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(sustained.feed('looking_away', 0), null);
  assert.equal(sustained.feed('looking_away', 299), null);
  assert.equal(sustained.feed('looking_away', 300), 'looking_away');

  // Just over the gate waits too, and the gate is the app's 15 degrees.
  const nearly = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(nearly.feed('pose:20,0', 0), null);
  assert.equal(nearly.feed('pose:20,0', 300), 'looking_away');
});

test('a near-sideways turn is confirmed by two detections, not two seconds', () => {
  // The monitor's one speed-up, and its port has it too: past 30 degrees of yaw a
  // head is not in any reading position, so two consecutive detections are the whole
  // of the evidence - the second one reports, well inside the hold.
  const judge = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(judge.feed('pose:45,0', 0), null, 'one detection is a frame');
  assert.equal(judge.feed('pose:45,0', 150), 'looking_away');

  // One detection, then a centred frame, then one more: two bad frames are not two
  // consecutive ones, so nothing has been earned.
  const flicker = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(flicker.feed('pose:45,0', 0), null);
  assert.equal(flicker.feed('pose:0,0', 100), null);
  assert.equal(flicker.feed('pose:45,0', 200), null);
  assert.equal(flicker.feed('pose:45,0', 300), 'looking_away');

  // A deep nod has no fast path: pitch is reading, not another screen, so 70 degrees
  // of it waits out the hold like any other glance.
  const nod = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(nod.feed('pose:0,70', 0), null);
  assert.equal(nod.feed('pose:0,70', 150), null, 'two detections are not two seconds');
  assert.equal(nod.feed('pose:0,70', 300), 'looking_away');
});

test('the yaw gate is symmetric, and the pitch gate is not', () => {
  // Yaw is judged on the absolute angle: how far the head went is the evidence,
  // which way it went is not.
  for (const [there, back] of [
    ['pose:20,0', 'pose:-20,0'],
  ]) {
    const judge = createJudge(rules({ lookAwaySustainMs: 300 }));
    assert.equal(judge.feed(there, 0), null);
    assert.equal(judge.feed(there, 300), 'looking_away', `${there} should report`);
    const mirrored = createJudge(rules({ lookAwaySustainMs: 300 }));
    assert.equal(mirrored.feed(back, 0), null);
    assert.equal(mirrored.feed(back, 300), 'looking_away', `${back} should report`);
  }

  // Pitch is signed, and the sign is the page's: positive is a chin down. A chin
  // 18 degrees *down* is the keyboard and is not evidence, however long it holds;
  // 18 degrees *up* is a screen above the monitor and is. That is the browser's one
  // asymmetry, 15 up against 20 down.
  const down = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(down.feed('pose:0,18', 0), null);
  assert.equal(down.feed('pose:0,18', 300), null, '18 down is inside the wider gate');
  assert.equal(down.feed('pose:0,18', 5000), null);

  const up = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(up.feed('pose:0,-18', 0), null);
  assert.equal(up.feed('pose:0,-18', 300), 'looking_away', '18 up is past the 15 gate');

  const desk = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(desk.feed('pose:0,20', 0), null);
  assert.equal(desk.feed('pose:0,20', 300), null, 'the widened gate is strict, like the old one');
  assert.equal(desk.feed('pose:0,22', 400), null);
  assert.equal(desk.feed('pose:0,22', 700), 'looking_away', '22 down is past 20');
});

test('a pose inside the box ends the episode and re-arms it', () => {
  const judge = createJudge(rules({ lookAwaySustainMs: 300 }));
  assert.equal(judge.feed('pose:40,0', 0), null);
  assert.equal(judge.feed('pose:40,0', 300), 'looking_away');
  assert.equal(judge.feed('pose:40,0', 400), null);
  // Centred again: the episode is over, so the next turn is a new one.
  assert.equal(judge.feed('pose:0,0', 450), null);
  // Pitch counts as much as yaw: looking down at a phone is looking away, and it
  // still has to last the hold.
  assert.equal(judge.feed('pose:-2,-25', 500), null);
  assert.equal(judge.feed('pose:-2,-25', 800), 'looking_away');
  // Inside the tolerances is not evidence, however long it goes on.
  assert.equal(judge.feed('pose:14,14', 900), null);
  assert.equal(judge.feed('pose:14,14', 5000), null);
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
  const judge = createJudge(rules({ lookAwaySustainMs: 300 }));
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
    rules({ lookAwaySustainMs: 300, noFaceSustainMs: 300 }),
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
  // The two holds are different questions and the app answers them with different
  // numbers: two seconds for a turned head, 300 ms for a camera that has stopped
  // showing one - and the grace is the shared five seconds.
  assert.ok(app.lookAwaySustainMs > app.noFaceSustainMs, 'a turn waits longer than an absence');
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
