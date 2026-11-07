/**
 * The report.
 *
 * Two audiences, one set of numbers: the reviewer reading stdout, and the reviewer
 * filing `--out report.json`. The tests check that the text carries the rules it
 * was scored under and says "—" where a rate has no denominator — a printed 0.0%
 * for "not measured" is the most misleading thing this tool could emit.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  describeRules,
  evaluateThresholds,
  formatReport,
  toJsonReport,
} from '../lib/report.mjs';

const RULES = {
  yawDegrees: 25,
  pitchDegrees: 18,
  immediateYawDegrees: 30,
  sustainMs: 300,
  graceMs: 0,
  multipleFacesCooldownMs: 30000,
};

const row = (overrides = {}) => ({
  line: 1,
  clip: 'a.mp4',
  action: 'looking_away',
  start: 0,
  end: 2,
  label: true,
  tags: {},
  tagList: [],
  ...overrides,
});

const segment = (positive, hits, overrides = {}) => ({
  row: row({ label: positive, ...overrides }),
  positive,
  detections: hits ? [{ action: 'looking_away', t: 1 }] : [],
  hit: positive && hits,
  falsePositive: !positive && hits,
});

/** A run with one hit, one miss and no negatives. */
function report(overrides = {}) {
  return {
    labelsPath: 'labels.csv',
    clips: ['a.mp4'],
    replayed: ['a.mp4'],
    segments: [segment(true, true, { line: 2 }), segment(true, false, { line: 3 })],
    strays: [],
    rules: RULES,
    tolerance: 0.5,
    ...overrides,
  };
}

test('describeRules names every number the score was produced under', () => {
  const text = describeRules(RULES);
  assert.match(text, /yaw > 25°/);
  assert.match(text, /pitch > 18°/);
  assert.match(text, /immediate > 30°/);
  assert.match(text, /sustain 300ms/);
  assert.match(text, /grace 0ms/);
  assert.match(text, /two-face re-arm 30000ms/);
});

test('the report leads with the rules, then the slices', () => {
  const text = formatReport(report());
  const order = ['rules', 'windows', 'BY ACTION', 'BY TAG', 'STRAYS'];
  const positions = order.map((label) => text.indexOf(label));
  for (const [index, position] of positions.entries()) {
    assert.ok(position >= 0, `missing section: ${order[index]}`);
  }
  assert.deepEqual([...positions].sort((a, b) => a - b), positions);

  assert.match(text, /windows       2 \(2 present, 0 absent\)/);
  assert.match(text, /tolerance     ±0\.5s around every window/);
  assert.match(text, /looking_away/);
});

test('a rate with no denominator prints an em dash, never 0.0%', () => {
  const text = formatReport(report());
  // Recall is measurable here (50%), but the false-positive rate is not.
  assert.match(text, /50\.0%/);
  assert.doesNotMatch(text, / 0\.0%\s*$/m);
  assert.match(text, /—/);
});

test('warnings and threshold verdicts are their own sections', () => {
  const text = formatReport(
    report({
      warnings: ['no label-0 windows were replayed'],
      verdicts: [
        { name: 'recall >= 90.0%', ok: false, detail: 'recall was 50.0%' },
        { name: 'fpr <= 10.0%', ok: true, detail: 'fpr was 5.0%' },
      ],
    }),
  );
  assert.match(text, /WARNINGS\n {2}no label-0 windows were replayed/);
  assert.match(text, /THRESHOLDS\n {2}FAIL {2}recall >= 90\.0% {3}\(recall was 50\.0%\)/);
  assert.match(text, /PASS {2}fpr <= 10\.0%/);
});

test('a stray is listed with its clip and time, and never scored', () => {
  const text = formatReport(
    report({ strays: [{ clip: 'a.mp4', action: 'looking_away', t: 7.25 }] }),
  );
  assert.match(text, /STRAYS {3}1 detection\(s\)/);
  assert.match(text, /a\.mp4 +looking_away +t=7\.25s/);
  assert.match(text, /reported, not scored/);
});

test('a threshold that was not asked for is not asserted', () => {
  assert.deepEqual(evaluateThresholds({ recall: 1, fpr: 0 }, {}), []);
  assert.deepEqual(evaluateThresholds({ recall: 1, fpr: 0 }), []);
});

test('a threshold with nothing to measure fails rather than passing vacuously', () => {
  const [recall] = evaluateThresholds({ recall: null, fpr: null }, { minRecall: 0.9 });
  assert.equal(recall.ok, false);
  assert.match(recall.detail, /recall was —/);

  const [fpr] = evaluateThresholds({ recall: null, fpr: null }, { maxFpr: 0.1 });
  assert.equal(fpr.ok, false, 'an unmeasured false-positive rate cannot be under budget');

  const [pass] = evaluateThresholds({ recall: 0.95, fpr: 0.02 }, { minRecall: 0.9, maxFpr: 0.1 });
  assert.equal(pass.ok, true);
});

test('the JSON report carries the facts, not the formatting', () => {
  const strays = [{ clip: 'a.mp4', action: 'looking_away', t: 7.25 }];
  const json = toJsonReport({ ...report({ strays }), startedAt: '2026-01-01T00:00:00.000Z' });

  assert.match(json.generatedAt, /^\d{4}-\d{2}-\d{2}T/);
  assert.equal(json.startedAt, '2026-01-01T00:00:00.000Z');
  assert.equal(json.labelsPath, 'labels.csv');
  assert.deepEqual(json.replayed, ['a.mp4']);
  assert.deepEqual(json.rules, RULES);
  assert.equal(json.tolerance, 0.5);

  assert.equal(json.total.positives, 2);
  assert.equal(json.total.recall, 0.5);
  assert.deepEqual(json.byAction.map((entry) => entry.action), ['looking_away']);
  assert.deepEqual(json.byTag.map((entry) => entry.tag), ['all']);
  assert.deepEqual(json.strays, strays);
  // A caller reading the file never has to parse "50.0%" back into a number.
  assert.equal(typeof json.total.recall, 'number');
  assert.equal(json.durationSeconds, null);
});
