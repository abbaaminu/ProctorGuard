import assert from 'node:assert/strict';
import test from 'node:test';

import { parseDuration, parseStages, rampSeconds, targetAt, StageError } from '../lib/stages.mjs';

test('durations are single-unit, and a bare number is seconds', () => {
  assert.equal(parseDuration('90'), 90);
  assert.equal(parseDuration('90s'), 90);
  assert.equal(parseDuration('2m'), 120);
  assert.equal(parseDuration('1h'), 3600);
  assert.equal(parseDuration(' 30s '), 30);
  assert.equal(parseDuration(45), 45);
});

test('a duration that is not a duration is refused by name', () => {
  for (const bad of ['', 'two minutes', '1m30s', '-5s', '0s', '5x']) {
    assert.throws(() => parseDuration(bad), StageError, `"${bad}" should not parse`);
  }
});

test('stages parse into targets and seconds', () => {
  assert.deepEqual(parseStages('50:2m,200:3m,500:3m'), [
    { target: 50, seconds: 120 },
    { target: 200, seconds: 180 },
    { target: 500, seconds: 180 },
  ]);
  assert.equal(rampSeconds(parseStages('50:2m,200:3m,500:3m')), 480);
});

test('a stage target that decreases is refused', () => {
  assert.throws(() => parseStages('200:1m,50:1m'), StageError);
});

test('a malformed stage names the piece that is wrong', () => {
  assert.throws(() => parseStages('50'), StageError);
  assert.throws(() => parseStages('fifty:1m'), StageError);
  assert.throws(() => parseStages('50:'), StageError);
  assert.throws(() => parseStages(''), StageError);
  assert.throws(() => parseStages('  '), StageError);
});

test('an empty segment is skipped, so a trailing comma is harmless', () => {
  // Deliberate: a stage list is often pasted from a spreadsheet and a trailing
  // comma is not worth a failed run. A stage with no duration is not the same
  // thing and is refused above.
  assert.deepEqual(parseStages('50:1m,'), [{ target: 50, seconds: 60 }]);
  assert.deepEqual(parseStages('50:1m, ,200:2m'), [
    { target: 50, seconds: 60 },
    { target: 200, seconds: 120 },
  ]);
});

test('the ramp is linear from the previous target, not a plateau', () => {
  const stages = parseStages('50:2m,200:3m,500:3m');
  assert.equal(targetAt(stages, 0), 0);
  assert.equal(targetAt(stages, 60), 25);       // half way up the first stage
  assert.equal(targetAt(stages, 120), 50);      // end of the first stage
  assert.equal(targetAt(stages, 210), 125);     // half way from 50 to 200
  assert.equal(targetAt(stages, 300), 200);     // end of the second stage
  assert.equal(targetAt(stages, 390), 350);     // half way from 200 to 500
  assert.equal(targetAt(stages, 480), 500);     // end of the ramp
});

test('the final target holds after the ramp', () => {
  const stages = parseStages('50:1m,200:1m');
  assert.equal(targetAt(stages, 120), 200);
  assert.equal(targetAt(stages, 600), 200);
  assert.equal(targetAt(stages, -5), 0);
});
