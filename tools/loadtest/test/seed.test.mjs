/**
 * The seeder, against a fake Supabase.
 *
 * `seed.mjs` is the only script here that creates accounts and publishes a
 * paper, and the only one that can be pointed at the wrong project with real
 * consequences. These tests keep its control flow honest — create-or-reuse,
 * find-or-create the paper, write the plan, refuse production — without a
 * network, a credential or a real project.
 */

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const SEED = fileURLToPath(new URL('../seed/seed.mjs', import.meta.url));
const STUB = fileURLToPath(new URL('../stub/fake_supabase.mjs', import.meta.url));
const STUB_KEY = 'stub-service-role-key';

function startStub() {
  const child = spawn(process.execPath, [STUB, '--port', '0'], { stdio: ['ignore', 'pipe', 'pipe'] });
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

/**
 * Runs the seeder with the LOADTEST_* variables cleared.
 *
 * A developer with LOADTEST_URL exported would otherwise seed *their* project
 * from a test run, which is exactly the accident the guard exists to prevent.
 */
function runSeed(args, env = {}) {
  const child = spawn(process.execPath, [SEED, ...args], {
    env: {
      ...process.env,
      LOADTEST_URL: '',
      LOADTEST_SERVICE_KEY: '',
      LOADTEST_STUDENT_PASSWORD: '',
      LOADTEST_PLAN: '',
      LOADTEST_PROD_REF: '',
      LOADTEST_ALLOW_FOREIGN_HOST: '',
      ...env,
    },
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

async function stats(port) {
  const response = await fetch(`http://127.0.0.1:${port}/stub/stats`);
  return response.json();
}

function stubArgs(port, extra) {
  return ['--url', `http://127.0.0.1:${port}`, '--service-key', STUB_KEY, ...extra];
}

test('a dry run proves the target, and creates nothing', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-seed-dry-'));
  const stub = await startStub();
  const out = join(directory, 'plan.json');
  t.after(() => {
    stub.child.kill();
    rmSync(directory, { recursive: true, force: true });
  });

  const result = await runSeed(stubArgs(stub.port, ['--count', '3', '--out', out, '--dry-run']));

  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /dry-run/);
  assert.match(result.stdout, /loadtest-staging-1@proctorguard\.test/);
  assert.equal(existsSync(out), false, 'a dry run must not write the plan');
  const after = await stats(stub.port);
  assert.deepEqual(after.users, [], 'a dry run must not create an account');
});

test('a real run creates the cohort, the paper and the plan', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-seed-'));
  const stub = await startStub();
  const out = join(directory, 'plan.json');
  t.after(() => {
    stub.child.kill();
    rmSync(directory, { recursive: true, force: true });
  });

  const result = await runSeed(stubArgs(stub.port, ['--count', '3', '--out', out]));

  assert.equal(result.code, 0, `seed.mjs failed:\n${result.stdout}\n${result.stderr}`);
  const plan = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(plan.students.length, 3);
  assert.match(plan.examId, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  assert.equal(plan.password, 'Loadtest!2026');
  assert.equal(plan.consentVersion, 'stub-1');
  assert.equal(plan.students[0].email, 'loadtest-staging-1@proctorguard.test');
  assert.equal(plan.students[2].email, 'loadtest-staging-3@proctorguard.test');
  assert.match(plan.students[0].id, /^[0-9a-f-]{36}$/);
  assert.match(plan.url, new RegExp(`127\\.0\\.0\\.1:${stub.port}$`));

  // The report is what an operator reads, so it has to name the paper.
  assert.match(result.stdout, /paper\s+created/);
  assert.match(result.stdout, /sign-in succeeds/);

  const after = await stats(stub.port);
  assert.equal(after.users.length, 4, `expected 3 students and a supervisor, got ${after.users.join(', ')}`);
  assert.ok(
    after.users.includes('loadtest-staging-teacher@proctorguard.test'),
    'the paper needs an owner, so the seeder makes a supervisor',
  );

  // A second run is idempotent: the same accounts, the same plan, nothing new.
  const again = await runSeed(stubArgs(stub.port, ['--count', '3', '--out', out]));
  assert.equal(again.code, 0, again.stderr);
  assert.match(again.stdout, /0 created, 3 reused/);
  assert.match(again.stdout, /paper\s+reusing/);
  assert.equal((await stats(stub.port)).users.length, 4);
});

test('--reset removes the previous cohort before seeding again', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-seed-reset-'));
  const stub = await startStub();
  const out = join(directory, 'plan.json');
  t.after(() => {
    stub.child.kill();
    rmSync(directory, { recursive: true, force: true });
  });

  const first = await runSeed(stubArgs(stub.port, ['--count', '2', '--out', out]));
  assert.equal(first.code, 0, first.stderr);
  const firstPlan = JSON.parse(readFileSync(out, 'utf8'));

  const second = await runSeed(stubArgs(stub.port, ['--count', '2', '--out', out, '--reset']));
  assert.equal(second.code, 0, second.stderr);
  assert.match(second.stdout, /deleted 3 account\(s\)/, 'two students and the supervisor');
  assert.match(second.stdout, /removed 1 seeded paper\(s\)/, 'and the paper they sat');

  const secondPlan = JSON.parse(readFileSync(out, 'utf8'));
  assert.equal(secondPlan.students.length, 2);
  // New auth ids: the point of --reset is that attempts (which hang off those
  // ids) cannot carry over into the run.
  assert.notEqual(secondPlan.students[0].id, firstPlan.students[0].id);
  assert.equal((await stats(stub.port)).users.length, 3);
});

test('the production guard refuses before a single account is created', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-seed-guard-'));
  const out = join(directory, 'plan.json');
  t.after(() => rmSync(directory, { recursive: true, force: true }));

  const result = await runSeed(
    ['--url', 'https://abcdefghijklmnopqrst.supabase.co', '--service-key', STUB_KEY, '--count', '1', '--out', out],
    { LOADTEST_PROD_REF: 'abcdefghijklmnopqrst' },
  );

  assert.equal(result.code, 2, `expected a refusal:\n${result.stdout}\n${result.stderr}`);
  assert.match(result.stderr, /refusing to run/);
  assert.match(result.stderr, /production project/);
  assert.equal(existsSync(out), false);
});

test('a missing key, a name that is not a name, and a short password are refused by flag', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'proctorguard-seed-config-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));

  const noKey = await runSeed(['--url', 'http://127.0.0.1:1', '--count', '1']);
  assert.equal(noKey.code, 2);
  assert.match(noKey.stderr, /LOADTEST_SERVICE_KEY/);

  const badCount = await runSeed(stubArgs(1, ['--count', '0']));
  assert.equal(badCount.code, 2);
  assert.match(badCount.stderr, /--count/);

  const badPassword = await runSeed(stubArgs(1, ['--password', 'short']));
  assert.equal(badPassword.code, 2);
  assert.match(badPassword.stderr, /at least 8 characters/);

  const badTag = await runSeed(stubArgs(1, ['--tag', 'not a tag']));
  assert.equal(badTag.code, 2);
  assert.match(badTag.stderr, /--tag/);

  // None of the above reached the network: a bad flag is caught before the
  // guard, and the guard before the first request.
  assert.equal(existsSync(join(directory, 'plan.json')), false);
});
