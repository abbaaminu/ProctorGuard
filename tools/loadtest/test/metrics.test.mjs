import assert from 'node:assert/strict';
import test from 'node:test';

import { SampleSet, Recorder } from '../lib/metrics.mjs';

test('percentiles are linearly interpolated over the sorted sample', () => {
  const set = new SampleSet();
  for (let value = 1; value <= 100; value += 1) set.add(value);

  // The definition the README quotes: numpy's default / PERCENTILE.INC.
  assert.equal(set.percentile(0), 1);
  assert.equal(set.percentile(50), 50.5);
  assert.equal(set.percentile(95), 95.05);
  assert.equal(set.percentile(99), 99.01);
  assert.equal(set.percentile(100), 100);
});

test('an empty sample set reports zero rather than NaN', () => {
  const set = new SampleSet();
  assert.equal(set.count, 0);
  assert.equal(set.percentile(50), 0);
  assert.equal(set.percentile(99), 0);
  assert.equal(set.mean(), 0);
  assert.equal(set.max(), 0);
});

test('a single sample is every percentile', () => {
  const set = new SampleSet();
  set.add(42);
  assert.equal(set.percentile(50), 42);
  assert.equal(set.percentile(99), 42);
});

test('adding a sample invalidates the cached sort', () => {
  const set = new SampleSet();
  set.add(10);
  assert.equal(set.percentile(100), 10);
  set.add(30);
  assert.equal(set.percentile(100), 30);
});

test('a sample must be a finite, non-negative number', () => {
  const set = new SampleSet();
  assert.throws(() => set.add(-1), RangeError);
  assert.throws(() => set.add(Number.NaN), RangeError);
  assert.throws(() => set.add(Number.POSITIVE_INFINITY), RangeError);
});

test('the recorder groups by operation, counts 429s and 5xx separately', () => {
  const recorder = new Recorder();
  recorder.record('answer', { durationMs: 10, status: 204 });
  recorder.record('answer', { durationMs: 30, status: 204 });
  recorder.record('heartbeat', { durationMs: 50, status: 429, body: '{"message":"rate limit"}' });
  recorder.record('submit', { durationMs: 70, status: 503, body: '{"message":"boom"}' });
  recorder.record('auth', { durationMs: 90, status: 0, error: 'ECONNREFUSED' });

  const summary = recorder.summarise();
  assert.equal(summary.requests, 5);
  assert.equal(summary.errors, 3);
  assert.equal(summary.errorRate, 3 / 5);
  assert.equal(summary.tooManyRequests, 1);
  assert.equal(summary.serverErrors, 1);

  const answer = summary.ops.find((op) => op.op === 'answer');
  assert.equal(answer.count, 2);
  assert.equal(answer.errors, 0);
  assert.equal(answer.p50, 20);

  // Busiest first, so the slowest thing a reader cares about is near the top.
  assert.equal(summary.ops[0].op, 'answer');
  assert.equal(summary.ops.length, 4);
});

test('failed samples keep the status, the body and the transport error', () => {
  const recorder = new Recorder({ maxFailures: 2 });
  recorder.record('answer', { durationMs: 1, status: 400, body: '{"message":"attempt is submitted"}' });
  recorder.record('answer', { durationMs: 2, status: 0, error: 'timeout after 20000ms' });
  recorder.record('answer', { durationMs: 3, status: 500, body: '{"message":"third"}' });

  const summary = recorder.summarise();
  // Capped: a run can fail a hundred thousand times and the report still has to
  // be readable.
  assert.equal(summary.failures.length, 2);
  assert.equal(summary.failures[0].status, 400);
  assert.match(summary.failures[0].body, /attempt is submitted/);
  assert.equal(summary.failures[1].status, 0);
  assert.match(summary.failures[1].error, /timeout/);
  // ...but every failure is still counted.
  assert.equal(summary.errors, 3);
});

test('statuses are listed in ascending order, with 0 first', () => {
  const recorder = new Recorder();
  recorder.record('a', { durationMs: 1, status: 200 });
  recorder.record('a', { durationMs: 1, status: 0, error: 'refused' });
  recorder.record('a', { durationMs: 1, status: 429 });

  assert.deepEqual(recorder.summarise().statuses, [[0, 1], [200, 1], [429, 1]]);
});
