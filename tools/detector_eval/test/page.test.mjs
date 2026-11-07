/**
 * The replay page.
 *
 * `page/eval.html` is the only part of this tool that cannot be unit-tested by
 * calling it — it needs a browser, a decoder and a face. What *can* be checked is
 * that it is a well-formed script that builds the DOM the detector insists on, and
 * that it is fed by a camera rather than by a file. A truncated inline script is a
 * syntax error that presents as "the page measured nothing", which is
 * indistinguishable from a detector that saw nothing: hence the first test.
 */

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const html = readFileSync(new URL('../page/eval.html', import.meta.url), 'utf8');
const open = html.indexOf('<script>');
const close = html.indexOf('</script>', open);
const inline = html.slice(open + '<script>'.length, close);

test('the inline script compiles', () => {
  assert.ok(open >= 0 && close > open, 'the page has one inline script');
  // Compiles without running: a syntax error here would leave `window.__result`
  // undefined for ever, and the runner would report a timeout instead of a bug.
  assert.doesNotThrow(() => new Function(inline));
});

test('the page loads the shipped detector, and builds the DOM Flutter builds', () => {
  assert.match(html, /<script src="\/detector\.js"><\/script>/);
  for (const element of ['flt-glass-pane', 'flt-platform-view', 'flt-platform-view-slot']) {
    assert.ok(html.includes(element), `the page builds <${element}>`);
  }
  // The platform view goes into the glass pane's light DOM, revealed through an
  // open shadow root — the arrangement the detector's lookup is written against.
  assert.match(inline, /attachShadow\(\{ mode: 'open' \}\)/);
  assert.match(inline, /glass\.appendChild\(wrapper\)/);
});

test('the detector watches a camera made from the clip, not the clip itself', () => {
  assert.match(inline, /canvas\.captureStream\(fps\)/);
  assert.match(inline, /preview\.srcObject = stream/);
  assert.match(inline, /preview\.muted = true/);

  // The clip must stay out of the document: a `<video>` with a `src` in the tree is
  // a candidate for the detector's own `findVideo`, and the detector has to proctor
  // the preview.
  assert.match(inline, /var source = document\.createElement\('video'\)/);
  assert.doesNotMatch(inline, /(document\.body|holder|glass|wrapper)\.appendChild\(source\)/);
});

test('a verdict is stamped with the clip clock, never the wall clock', () => {
  assert.match(inline, /t: clipTime\(\)/);
  assert.match(inline, /var now = source\.currentTime/);
  assert.doesNotMatch(inline, /t: Date\.now\(\)/);
});
