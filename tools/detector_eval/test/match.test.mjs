/**
 * The scoring.
 *
 * The unit here is the window: an episode inside a labelled episode is a hit
 * however many times it fired, a report inside a negative window is a false
 * positive, and a report outside every window of its own action is a stray that is
 * reported and not scored. These tests pin those three decisions, because they are
 * the difference between a number about the detector and a number about the
 * spreadsheet.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  DEFAULT_TOLERANCE_SECONDS,
  byAction,
  byTag,
  evaluateClip,
  median,
  resolveEnds,
  summarize,
} from '../lib/match.mjs';

const row = (overrides = {}) => ({
  line: 1,
  clip: 'a.mp4',
  action: 'looking_away',
  start: 0,
  end: 1,
  label: true,
  tags: {},
  tagList: [],
  ...overrides,
});

/** A finished segment, as `evaluateClip` would have produced it. */
const segment = (positive, detections, overrides = {}) => ({
  row: row({ label: positive, ...overrides }),
  positive,
  detections,
  hit: positive && detections.length > 0,
  falsePositive: !positive && detections.length > 0,
});

const detection = (t, action = 'looking_away') => ({ action, t });

test('a detection inside a positive window is a hit; inside a negative one it is not', () => {
  const { segments, strays } = evaluateClip(
    [
      row({ start: 2, end: 6, line: 2 }),
      row({ start: 0, end: 1.5, label: false, line: 3 }),
    ],
    [detection(4)],
  );

  assert.equal(segments[0].hit, true);
  assert.equal(segments[0].falsePositive, false);
  assert.equal(segments[1].hit, false);
  assert.equal(segments[1].falsePositive, false);
  assert.deepEqual(strays, []);
});

test('a detection in a negative window is a false positive, not a stray', () => {
  const { segments, strays } = evaluateClip(
    [row({ start: 2, end: 6 }), row({ start: 0, end: 1.5, label: false })],
    [detection(1)],
  );

  assert.equal(segments[1].falsePositive, true);
  assert.equal(segments[0].hit, false);
  // It landed in a window, so it is scored — strays are only what landed nowhere.
  assert.deepEqual(strays, []);
});

test('tolerance widens the window, and nothing beyond it', () => {
  const rows = [row({ start: 2, end: 6 })];
  assert.equal(evaluateClip(rows, [detection(1.6)], { tolerance: 0.5 }).segments[0].hit, true);
  assert.equal(evaluateClip(rows, [detection(1.4)], { tolerance: 0.5 }).segments[0].hit, false);
  assert.equal(DEFAULT_TOLERANCE_SECONDS, 0.5);
});

test('a detection between two windows of one action belongs to the nearest', () => {
  const rows = [row({ start: 0, end: 2.4, label: false }), row({ start: 2.5, end: 6 })];
  // 2.45s is inside the tolerance of both; the earlier window is closer.
  const { segments } = evaluateClip(rows, [detection(2.45)], { tolerance: 0.5 });
  assert.equal(segments[0].falsePositive, true);
  assert.equal(segments[1].hit, false);
});

test('a detection outside every window of its own action is a stray', () => {
  const rows = [row({ start: 2, end: 6 })];
  const { segments, strays } = evaluateClip(rows, [detection(0.5), detection(9)]);
  assert.equal(segments[0].hit, false);
  assert.deepEqual(strays, [detection(0.5), detection(9)]);
});

test('a detection of another action is not evidence for this window', () => {
  const rows = [row({ start: 2, end: 6, action: 'looking_away' })];
  const { strays } = evaluateClip(rows, [detection(4, 'no_face')]);
  assert.deepEqual(strays, [detection(4, 'no_face')]);
});

test('two positive windows of one action may not overlap', () => {
  assert.throws(
    () => evaluateClip([row({ start: 0, end: 3, line: 2 }), row({ start: 2, end: 5, line: 7 })], []),
    /lines 2 and 7: two looking_away windows overlap — one episode cannot be two labels/,
  );
  // Different actions can overlap: a face leaving while a second person arrives is
  // two things happening, not a labelling error.
  assert.doesNotThrow(() =>
    evaluateClip([row({ start: 2, end: 5, line: 2 }), row({ start: 0, end: 3, line: 7, action: 'no_face' })], []),
  );
  // A negative beside a positive is the case the tolerance is allowed to blur.
  assert.doesNotThrow(() =>
    evaluateClip([row({ start: 2, end: 5 }), row({ start: 0, end: 3, label: false })], []),
  );
});

test('summarize counts windows, not detections, and rates the negatives separately', () => {
  const total = summarize([
    segment(true, [detection(1), detection(2)]), // one hit, however many reports
    segment(true, []), //                              a miss
    segment(false, [detection(1)]), //                 a false positive
    segment(false, []),
    segment(false, []),
  ]);

  assert.equal(total.positives, 2);
  assert.equal(total.hits, 1);
  assert.equal(total.misses, 1);
  assert.equal(total.recall, 0.5);
  assert.equal(total.negatives, 3);
  assert.equal(total.falsePositives, 1);
  assert.equal(total.trueNegatives, 2);
  assert.equal(total.fpr, 1 / 3);
  assert.equal(total.detections, 3);
  assert.equal(total.precision, 2 / 3);
  // The windows are 1s wide in this fixture; one false positive in three of those
  // seconds is twenty a minute, which is the number an exam would feel.
  assert.equal(total.negativeSeconds, 3);
  assert.equal(total.falsePositivesPerMinute, 20);
});

test('a rate with no denominator is null, not zero', () => {
  assert.equal(summarize([segment(false, [])]).recall, null);
  assert.equal(summarize([segment(true, [])]).fpr, null);
  assert.equal(summarize([segment(true, [])]).precision, null);
  assert.equal(summarize([]).recall, null);
  assert.equal(summarize([]).detections, 0);
});

test('strays are counted per action and never folded into precision', () => {
  const segments = [segment(true, [detection(1)]), segment(false, [])];
  const strays = [detection(9), detection(11), detection(3, 'no_face')];

  const total = summarize(segments, strays);
  assert.equal(total.strays, 3);
  assert.equal(total.precision, 1, 'a stray is not evidence about a window');

  const rows = byAction([...segments, segment(true, [], { action: 'no_face' })], strays);
  assert.deepEqual(rows.map((entry) => entry.action), ['looking_away', 'no_face']);
  assert.equal(rows[0].strays, 2);
  assert.equal(rows[1].strays, 1);
});

test('byTag starts with the whole run and gives every tag its own row', () => {
  const segments = [
    segment(true, [detection(1)], { tagList: ['lighting=dim', 'glasses=yes'] }),
    segment(true, [], { tagList: ['lighting=dim'] }),
    segment(false, [], { tagList: ['lighting=dim', 'mixed=yes'] }),
  ];
  const rows = byTag(segments);

  assert.deepEqual(
    rows.map((entry) => entry.tag),
    ['all', 'glasses=yes', 'lighting=dim', 'mixed=yes'],
  );
  assert.equal(rows[0].positives, 2);
  // A window with two tags counts in both rows — a slice is a question, not a
  // category — so the rows do not add up to the total and are not meant to.
  assert.equal(rows[1].positives, 1);
  assert.equal(rows[1].recall, 1);
  assert.equal(rows[2].positives, 2);
  assert.equal(rows[2].recall, 0.5);
  // A tag that only ever appears in negatives has nothing to recall.
  assert.equal(rows[3].positives, 0);
  assert.equal(rows[3].recall, null);
});

test('resolveEnds fills a blank end from the clip, and refuses to guess', () => {
  const rows = resolveEnds([row({ start: 3, end: null })], { 'a.mp4': 9.5 });
  assert.equal(rows[0].end, 9.5);

  // The row is copied, not mutated: the caller's labels stay as written.
  const original = row({ start: 3, end: null });
  resolveEnds([original], { 'a.mp4': 9.5 });
  assert.equal(original.end, null);

  assert.throws(
    () => resolveEnds([row({ start: 3, end: null })], {}),
    /line 1: no end, and the duration of a.mp4 is unknown/,
  );
  assert.throws(
    () => resolveEnds([row({ start: 12, end: null })], { 'a.mp4': 9.5 }),
    /line 1: start 12s is past the end of a.mp4 \(9.50s\)/,
  );
});

test('median answers "how late was it" without averaging the outliers in', () => {
  assert.equal(median([]), null);
  assert.equal(median([5]), 5);
  assert.equal(median([3, 1, 2]), 2);
  assert.equal(median([4, 1, 3, 2]), 2.5);
});
