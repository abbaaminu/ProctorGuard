/**
 * End-to-end: the load test against a fake Supabase.
 *
 * These tests exist to keep `load.mjs` honest about its own control flow — that
 * a sitting really does reach `submit_exam`, that the guard refuses before the
 * first request, that a threshold miss is a non-zero exit. None of it touches a
 * network, a credential or a real project.
 */

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const LOAD = fileURLToPath(new URL('../load.mjs', import.meta.url));
const STUB = fileURLToPath(new URL('../stub/fake_supabase.mjs', import.meta.url));
const STUB_EXAM = '11111111-1111-4111-8111-111111111111';

/** Starts the fake Supabase on an ephemeral port and waits for its port line. */
function startStub(extraArgs = []) {
  const child = spawn(process.execPath, [STUB, '--port', '0', ...extraArgs], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stderr.on('data', () => {});
  return new Promise((resolve, reject) => {
    let buffer = '';
    child.stdout.on('data', (chunk) => {
      buffer += chunk.toString();
      const newline = buffer.indexOf('\n');
      if (newline === -1) return;
      try {
        resolve({ child, port: JSON.parse(buffer.slice(0, newline)).port });
      } catch (error) {
        reject(error);
      }
    });
    child.on('error', reject);
  });
}

function runLoad(args, env = {}) {
  const child = spawn(process.execPath, [LOAD, ...args], {
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on('data', (chunk) => {
    stderr += chunk.toString();
  });
  return new Promise((resolve) => {
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

function students(count) {
  return Array.from({ length: count }, (_, index) => ({
    email: `loadtest+${index + 1}@example.test`,
    id: `00000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`,
  }));
}

function writePlan(directory, count) {
  const path = join(directory, 'plan.json');
  writeFileSync(path, JSON.stringify({
    generatedAt: new Date().toISOString(),
    examId: STUB_EXAM,
    consentVersion: 'stub',
    password: 'stub-password',
    students: students(count),
  }), 'utf8');
  return path;
}

function fakeKey(payload) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${encode({ alg: 'HS256', typ: 'JWT' })}.${encode(payload)}.signature`;
}

/** A run that finishes in about two seconds, whatever the stub does. */
const FAST = [
  '--session-seconds', '1',
  '--answer-every', '0.25',
  '--heartbeat-every', '0.25',
  '--violations-per-minute', '120',
  '--quiet',
];

test('a complete run drives every leg of a sitting and prints the report', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-'));
  const stub = await startStub();
  const outPath = join(directory, 'report.json');
  t.after(() => {
    stub.child.kill();
    rmSync(directory, { recursive: true, force: true });
  });

  const result = await runLoad([
    '--url', `http://127.0.0.1:${stub.port}`,
    '--anon-key', 'stub-anon-key',
    '--plan', writePlan(directory, 6),
    '--stages', '3:1s,6:1s',
    ...FAST,
    '--out', outPath,
    '--seed', '3',
  ]);

  assert.equal(result.code, 0, `load.mjs failed:\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /BY OPERATION/);
  assert.match(result.stdout, /STATUS CODES/);
  assert.match(result.stdout, /429 \(rate limited\): \d+/);
  assert.match(result.stdout, /5xx \(server\): \d+/);

  const report = JSON.parse(readFileSync(outPath, 'utf8'));
  assert.equal(report.sessions.started, 6);
  assert.equal(report.sessions.submitted, 6);
  assert.equal(report.sessions.failed, 0);
  assert.ok(report.sessions.answers >= 6, `only ${report.sessions.answers} answers were sent`);
  assert.ok(report.sessions.heartbeats >= 6);
  assert.ok(report.summary.requests >= 30);
  assert.equal(report.summary.errors, 0);

  // Every operation the sitting is supposed to produce appears: a missing leg
  // (consent, say) would otherwise be invisible, because nothing asserts it.
  const ops = report.summary.ops.map((op) => op.op).sort();
  assert.deepEqual(ops, [
    'answer',
    'auth',
    'consent',
    'exams_list',
    'heartbeat',
    'questions',
    'start_attempt',
    'submit',
    'violation',
  ]);
});

test('injected 429s and 5xx are counted and reported, not retried', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-fail-'));
  const stub = await startStub(['--fail-rate', '0.35']);
  const outPath = join(directory, 'report.json');
  t.after(() => {
    stub.child.kill();
    rmSync(directory, { recursive: true, force: true });
  });

  const result = await runLoad([
    '--url', `http://127.0.0.1:${stub.port}`,
    '--anon-key', 'stub-anon-key',
    '--plan', writePlan(directory, 6),
    '--stages', '6:1s',
    ...FAST,
    '--out', outPath,
  ]);

  // No threshold was asked for, so a run full of 429s still exits 0: the exit
  // code reports the operator's bar, not this file's opinion.
  assert.equal(result.code, 0, result.stderr);

  const report = JSON.parse(readFileSync(outPath, 'utf8'));
  assert.ok(
    report.summary.tooManyRequests + report.summary.serverErrors > 0,
    'the injected failures should show up in the status counts',
  );
  assert.ok(report.summary.errorRate > 0);
  if (report.summary.failures.length > 0) {
    assert.match(result.stdout, new RegExp(`FIRST ${report.summary.failures.length} FAILURES`));
    assert.match(result.stdout, /stub: (rate limit exceeded|injected server error)/);
  }
});

test('a threshold the run misses is a non-zero exit', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-threshold-'));
  const stub = await startStub(['--fail-rate', '0.5']);
  t.after(() => {
    stub.child.kill();
    rmSync(directory, { recursive: true, force: true });
  });

  const result = await runLoad([
    '--url', `http://127.0.0.1:${stub.port}`,
    '--anon-key', 'stub-anon-key',
    '--plan', writePlan(directory, 2),
    '--stages', '2:1s',
    ...FAST,
    '--error-rate', '0.01',
  ]);

  assert.equal(result.code, 1, `expected a threshold failure:\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stdout, /THRESHOLDS/);
  assert.match(result.stdout, /FAIL  error rate/);
});

test('the production guard stops the run before any request', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-guard-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const production = 'projref0000000000000';

  const result = await runLoad(
    [
      '--url', `https://${production}.supabase.co`,
      '--anon-key', fakeKey({ ref: production, role: 'anon' }),
      '--plan', writePlan(directory, 2),
      '--dry-run',
    ],
    { LOADTEST_PROD_REF: production },
  );

  assert.equal(result.code, 2, `the guard should have refused:\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /production project/);
  // A dry run would have printed its banner and exited 0; it never got that far.
  assert.equal(result.stdout.includes('DRY RUN'), false);
});

test('a key from another project cannot be paired with the target URL', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-mismatch-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));

  const result = await runLoad(
    [
      '--url', 'https://stagingyyy00000000000.supabase.co',
      '--anon-key', fakeKey({ ref: 'projref0000000000000', role: 'anon' }),
      '--plan', writePlan(directory, 2),
      '--dry-run',
    ],
    { LOADTEST_PROD_REF: '' },
  );

  assert.equal(result.code, 2);
  assert.match(result.stderr, /belongs to project/);
});

test('a dry run prints the plan, the ramp and the seed shortfall, and sends nothing', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-dry-'));
  try {
    const result = await runLoad(
      [
        '--url', 'http://127.0.0.1:1',
        '--anon-key', 'stub-anon-key',
        '--plan', writePlan(directory, 3),
        '--stages', '50:2m,200:3m,500:3m',
        '--dry-run',
      ],
      // Nothing is listening on port 1: if the dry run sent one request, the
      // report below would show a transport failure instead of an empty run.
      { LOADTEST_PROD_REF: '' },
    );

    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /DRY RUN/);
    assert.match(result.stdout, /students\s+3/);
    assert.match(result.stdout, /peak reached will be\s+3/);
    assert.match(result.stdout, /Seed more \(--count\)/);
    assert.doesNotMatch(result.stdout, /TOTALS/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test('a missing plan is a configuration error that names the seeder', async () => {
  const result = await runLoad(
    [
      '--url', 'http://127.0.0.1:1',
      '--anon-key', 'stub-anon-key',
      '--plan', join(tmpdir(), 'definitely-not-here', 'plan.json'),
      '--dry-run',
    ],
    { LOADTEST_PROD_REF: '' },
  );

  assert.equal(result.code, 2);
  assert.match(result.stderr, /seed\/seed\.mjs/);
});

test('a plan seeded in another project is refused', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-load-planref-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const planPath = join(directory, 'plan.json');
  writeFileSync(planPath, JSON.stringify({
    projectRef: 'someotherprojectref0',
    examId: STUB_EXAM,
    password: 'stub-password',
    students: students(1),
  }), 'utf8');

  const result = await runLoad(
    [
      '--url', 'https://stagingyyy00000000000.supabase.co',
      '--anon-key', 'sb_publishable_staging',
      '--plan', planPath,
      '--dry-run',
    ],
    { LOADTEST_PROD_REF: '' },
  );

  // The student ids in the plan exist only in the project that created them; a
  // run against another project would sign in as nobody and report a 100% error
  // rate that looks like the server's fault.
  assert.equal(result.code, 2, `expected a refusal:\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /seeded in project someotherprojectref0/);
});
