import assert from 'node:assert/strict';
import test from 'node:test';

import { Recorder } from '../lib/metrics.mjs';
import { parseStages } from '../lib/stages.mjs';
import { formatReport, evaluateThresholds, toJsonReport } from '../lib/report.mjs';

function sampleRun() {
  const recorder = new Recorder();
  recorder.record('answer', { durationMs: 12, status: 204 });
  recorder.record('answer', { durationMs: 40, status: 204 });
  recorder.record('heartbeat', { durationMs: 25, status: 429, body: '{"message":"rate limit"}' });
  recorder.record('submit', { durationMs: 900, status: 503, body: '{"message":"boom"}' });

  return {
    environment: {
      url: 'https://stagingref0000000000.supabase.co',
      projectRef: 'stagingref0000000000',
      keyRef: 'stagingref0000000000',
      productionRef: 'projref0000000000000',
      isLocal: false,
    },
    stages: parseStages('50:1m'),
    summary: recorder.summarise(),
    sessions: {
      started: 2,
      submitted: 1,
      failed: 1,
      answers: 4,
      heartbeats: 3,
      heartbeatsThrottled: 1,
      heartbeatsDuplicated: 0,
      violations: 1,
      peakConcurrency: 2,
      expectedPeak: 50,
      reasons: [['start attempt 403: {message:"not offered"}', 1]],
    },
    config: {
      answerEverySeconds: 30,
      heartbeatEverySeconds: 15,
      violationsPerMinute: 0.5,
      violationType: 'looking_away',
      sessionSeconds: 300,
    },
    startedAt: '2026-11-05T09:00:00.000Z',
    durationSeconds: 361.4,
  };
}

test('the report carries the numbers an operator is asked for', () => {
  const text = formatReport(sampleRun());
  assert.match(text, /ProctorGuard staging load test/);
  assert.match(text, /TOTALS/);
  assert.match(text, /p50/);
  assert.match(text, /p95/);
  assert.match(text, /p99/);
  assert.match(text, /error rate/);
  assert.match(text, /429 \(rate limited\): 1/);
  assert.match(text, /5xx \(server\): 1/);
  assert.match(text, /peak concurrent/);
  assert.match(text, /why sessions ended early/);
});

test('the report names the guard facts rather than asserting them', () => {
  const text = formatReport(sampleRun());
  assert.match(text, /staging \(stagingref0000000000\) is not production \(projref0000000000000\)/);
});

test('a local run says the production ref does not apply', () => {
  const run = sampleRun();
  run.environment = {
    url: 'http://127.0.0.1:54321',
    projectRef: null,
    keyRef: null,
    productionRef: null,
    isLocal: true,
  };
  const text = formatReport(run);
  assert.match(text, /local target/);
  assert.match(text, /production\s+not found/);
});

test('failures and their bodies appear, so a 403 can be diagnosed', () => {
  const text = formatReport(sampleRun());
  assert.match(text, /FIRST 2 FAILURES/);
  assert.match(text, /rate limit/);
  assert.match(text, /boom/);
});

test('thresholds pass when the numbers are inside them', () => {
  const summary = new Recorder().summarise();
  const verdicts = evaluateThresholds(summary, { p95Ms: 1500, errorRate: 0.01 });
  assert.equal(verdicts.length, 2);
  assert.ok(verdicts.every((verdict) => verdict.ok));
});

test('thresholds fail when the numbers are outside them', () => {
  const run = sampleRun();
  const verdicts = evaluateThresholds(run.summary, {
    p95Ms: 100,
    errorRate: 0.01,
    maxServerErrors: 0,
    maxTooManyRequests: 0,
  });
  assert.equal(verdicts.length, 4);
  assert.ok(verdicts.every((verdict) => !verdict.ok), JSON.stringify(verdicts));
  assert.match(formatReport({ ...run, verdicts }), /FAIL  p95 < 100ms/);
});

test('an absent threshold is not a threshold of zero', () => {
  assert.deepEqual(evaluateThresholds(new Recorder().summarise(), {}), []);
  assert.deepEqual(
    evaluateThresholds(new Recorder().summarise(), { p95Ms: undefined, errorRate: undefined }),
    [],
  );
});

test('the JSON report holds the same facts, with reasons as objects', () => {
  const run = sampleRun();
  const json = toJsonReport({ ...run, verdicts: [] });
  assert.equal(json.summary.requests, 4);
  assert.deepEqual(json.sessions.reasons, [{
    reason: 'start attempt 403: {message:"not offered"}',
    count: 1,
  }]);
  assert.equal(json.durationSeconds, 361);
  // Round-trips, so a report can be archived and read later.
  assert.doesNotThrow(() => JSON.parse(JSON.stringify(json)));
});
