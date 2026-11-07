/**
 * The labels parser.
 *
 * This is the one place a spreadsheet becomes a score, and every refusal here is
 * a window that would otherwise drop out of the metrics and quietly improve the
 * number. So the tests are mostly about what it refuses, and about the line
 * numbers in what it says.
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import { ACTIONS, COLUMNS, clipsOf, parseLabels, splitCsvLine, tagsOf } from '../lib/labels.mjs';

const HEADER = COLUMNS.join(',');

/** Parses a header plus the given body lines. */
const parse = (...lines) => parseLabels([HEADER, ...lines].join('\n'));

/** Asserts the whole file is refused, with `pattern` somewhere in the reason. */
function refuses(pattern, ...lines) {
  assert.throws(() => parse(...lines), (error) => {
    assert.match(error.message, pattern);
    return true;
  });
}

test('parses windows, blank ends, labels and tags', () => {
  const { rows, warnings } = parse(
    '# a note beside a hard call',
    '01-away.mp4,looking_away,0,2.4,0,lighting=bright;glasses=no',
    '',
    '01-away.mp4,looking_away,2.5,,1,lighting=bright',
  );

  assert.deepEqual(warnings, []);
  assert.equal(rows.length, 2);

  assert.equal(rows[0].label, false);
  assert.equal(rows[0].end, 2.4);
  assert.equal(rows[0].start, 0);
  assert.deepEqual(rows[0].tags, { lighting: 'bright', glasses: 'no' });
  assert.deepEqual(rows[0].tagList, ['lighting=bright', 'glasses=no']);

  // A blank end means "to the end of the clip", resolved after the replay.
  assert.equal(rows[1].end, null);
  assert.equal(rows[1].label, true);

  // Comments and blank lines are skipped but still counted, so the number the
  // operator reads matches the line their editor shows.
  assert.equal(rows[1].line, 5);
});

test('accepts a BOM and a header in any case', () => {
  const text = `\uFEFF${HEADER.toUpperCase()}\r\n01.mp4,no_face,0,1,1,\r\n`;
  const { rows } = parseLabels(text);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].clip, '01.mp4');
});

test('refuses a missing or renamed header', () => {
  assert.throws(
    () => parseLabels('clip,action,start,end,label\n01.mp4,no_face,0,1,1'),
    /line 1: the header must be/,
  );
  assert.throws(() => parseLabels(''), /no header row/);
});

test('refuses the wrong number of columns and names the usual cause', () => {
  refuses(/line 2: 7 columns, expected 6/, '01.mp4,no_face,0,1,1,lighting=dim,room=2');
});

test('refuses a path where a file name belongs', () => {
  refuses(/not a path/, 'clips\\01.mp4,no_face,0,1,1,');
  refuses(/not a path/, 'sub/01.mp4,no_face,0,1,1,');
  refuses(/not a path/, 'C:/clips/01.mp4,no_face,0,1,1,');
  refuses(/not a path/, '.,no_face,0,1,1,');
});

test('refuses an action the app does not log', () => {
  refuses(/action "blink" is not one this app logs/, '01.mp4,blink,0,1,1,');
  // ...and the known list is the app's, not the parser's opinion.
  assert.deepEqual(ACTIONS, ['looking_away', 'no_face', 'multiple_faces']);
});

test('refuses a label that is not 0 or 1', () => {
  refuses(/label must be 0 \(absent\) or 1 \(present\), not "yes"/, '01.mp4,no_face,0,1,yes,');
  refuses(/label must be 0 \(absent\) or 1 \(present\), not ""/, '01.mp4,no_face,0,1,,');
});

test('refuses a malformed tag, and a key given twice', () => {
  refuses(/tag "lighting" is not key=value/, '01.mp4,no_face,0,1,1,lighting');
  // Keys are compared exactly: `A=1` and `a=1` are two slices, not one.
  refuses(/tag "a" is given twice/, '01.mp4,no_face,0,1,1,a=1;A=1;a=2');
});

test('refuses a window that ends before it starts', () => {
  refuses(/end \(1s\) must be after start \(2s\)/, '01.mp4,no_face,2,1,1,');
  refuses(/end \(1s\) must be after start \(1s\)/, '01.mp4,no_face,1,1,1,');
});

test('refuses numbers that are not numbers', () => {
  refuses(/start is not a number of seconds: "later"/, '01.mp4,no_face,later,1,1,');
  // A negative second is a typo, not a window starting before the clip does.
  refuses(/start is not a number of seconds: "-1"/, '01.mp4,no_face,-1,1,1,');
  // An empty start is a missing cell, not "from the beginning".
  refuses(/start is not a number of seconds: ""/, '01.mp4,no_face,,1,1,');
});

test('warns about a header with no windows rather than passing silently', () => {
  const { rows, warnings } = parseLabels(HEADER);
  assert.deepEqual(rows, []);
  assert.match(warnings[0], /header but no windows/);
});

test('splitCsvLine honours quoted cells and "" escapes', () => {
  assert.deepEqual(splitCsvLine('a,b,c'), ['a', 'b', 'c']);
  assert.deepEqual(splitCsvLine('a,"b,c",d'), ['a', 'b,c', 'd']);
  assert.deepEqual(splitCsvLine('a,"say ""hi""",c'), ['a', 'say "hi"', 'c']);
  assert.deepEqual(splitCsvLine('a,,c'), ['a', '', 'c']);
});

test('clip order is first appearance, tags are sorted and deduplicated', () => {
  const { rows } = parse(
    'b.mp4,no_face,0,1,1,z=1',
    'a.mp4,no_face,0,1,1,a=2;z=1',
    'b.mp4,no_face,1,2,1,a=2',
  );
  assert.deepEqual(clipsOf(rows), ['b.mp4', 'a.mp4']);
  assert.deepEqual(tagsOf(rows), ['a=2', 'z=1']);
});
