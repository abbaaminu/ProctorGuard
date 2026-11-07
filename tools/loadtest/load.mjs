#!/usr/bin/env node
/**
 * ProctorGuard staging load test.
 *
 *   node tools/loadtest/load.mjs --dry-run
 *   node tools/loadtest/load.mjs --stages "50:2m,200:3m,500:3m"
 *
 * What it does, in one sentence: it runs N concurrent *complete student
 * sittings* against a staging Supabase project — sign in, list papers, accept
 * the proctoring notice, start an attempt, read the paper, answer every 30 s,
 * beat every 15 s, occasionally log a violation, submit — and prints p50/p95/p99
 * latency, the error rate and the 429/5xx counts, per operation and in total.
 *
 * What it will not do: run against production. `--dry-run` is the way to check
 * what a run *would* do; there is no flag that sends traffic at all (a "force"
 * switch would defeat the only guardrail that matters).
 *
 * Environment (flags win):
 *   LOADTEST_URL                   the staging project URL
 *   LOADTEST_ANON_KEY              that project's anon/publishable key
 *   LOADTEST_PLAN                  plan.json from tools/loadtest/seed/seed.mjs
 *   LOADTEST_STAGES                "50:2m,200:3m,500:3m"
 *   LOADTEST_PROD_REF              production ref, when supabase/.temp/project-ref is absent
 *   LOADTEST_ALLOW_FOREIGN_HOST=1  for a self-hosted staging stack
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

import { HttpClient } from './lib/http.mjs';
import { Recorder } from './lib/metrics.mjs';
import { formatReport, evaluateThresholds, toJsonReport } from './lib/report.mjs';
import { parseStages, rampSeconds, targetAt } from './lib/stages.mjs';
import { runStudentSession, sleep, createRng, HEARTBEAT_FLOOR_SECONDS } from './lib/session.mjs';
import { assertStaging, readProductionRef, GuardError } from './lib/guard.mjs';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const EXIT_CONFIG = 2;
const EXIT_THRESHOLD = 1;

const USAGE = `ProctorGuard staging load test

  node tools/loadtest/load.mjs [options]

  --url <url>                  staging project URL          (env LOADTEST_URL)
  --anon-key <key>             staging anon key             (env LOADTEST_ANON_KEY)
  --plan <path>                plan.json from seed.mjs      (default ./plan.json)
  --stages <spec>              "50:2m,200:3m,500:3m"        (default 50/200/500)
  --answer-every <seconds>     answer cadence               (default 30)
  --heartbeat-every <seconds>  heartbeat cadence            (default 15)
  --violations-per-minute <n>  per student                 (default 0.5)
  --violation-type <action>    action_type to log          (default looking_away)
  --session-seconds <n>        how long one sitting lasts   (default 300)
  --timeout-ms <n>             per-request timeout          (default 20000)
  --p95-ms <n>                 fail the run above this p95
  --error-rate <fraction>      fail the run above this rate (0.01 = 1%)
  --max-5xx <n>                fail the run above this many 5xx
  --max-429 <n>                fail the run above this many 429s
  --out <path>                 write the JSON report
  --seed <n>                   PRNG seed for a repeatable run (default 1)
  --dry-run                    print what would be sent and exit
  --quiet                      no progress lines
  --help

The server throttles record_heartbeat inside ${HEARTBEAT_FLOOR_SECONDS}s, so anything below that
is answered with outcome = "throttled" - which the report counts, and does not call an error.

Exit codes: 0 ok, 1 a threshold failed, 2 bad configuration or the guard refused.
`;

const OPTIONS = {
  url: { type: 'string' },
  'anon-key': { type: 'string' },
  plan: { type: 'string' },
  stages: { type: 'string' },
  'answer-every': { type: 'string' },
  'heartbeat-every': { type: 'string' },
  'violations-per-minute': { type: 'string' },
  'violation-type': { type: 'string' },
  'session-seconds': { type: 'string' },
  'timeout-ms': { type: 'string' },
  'p95-ms': { type: 'string' },
  'error-rate': { type: 'string' },
  'max-5xx': { type: 'string' },
  'max-429': { type: 'string' },
  out: { type: 'string' },
  seed: { type: 'string' },
  'dry-run': { type: 'boolean', default: false },
  quiet: { type: 'boolean', default: false },
  help: { type: 'boolean', default: false },
};

function readEnv(name) {
  const value = process.env[name];
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined;
}

function numberFlag(raw, fallback, name, { min = 0 } = {}) {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min) {
    throw new GuardError(`--${name} must be a number >= ${min}, got "${raw}"`);
  }
  return value;
}

function loadPlan(path) {
  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (error) {
    throw new GuardError(
      `cannot read the plan at ${path} (${error.code ?? error.message}). ` +
        'Run `node tools/loadtest/seed/seed.mjs --count 500` first — it writes plan.json.',
    );
  }
  let plan;
  try {
    plan = JSON.parse(raw);
  } catch {
    throw new GuardError(`the plan at ${path} is not JSON`);
  }
  if (!Array.isArray(plan.students) || plan.students.length === 0) {
    throw new GuardError(`the plan at ${path} has no students — reseed with a positive --count`);
  }
  if (typeof plan.password !== 'string' || plan.password === '') {
    throw new GuardError(`the plan at ${path} has no password`);
  }
  if (typeof plan.examId !== 'string' || plan.examId === '') {
    throw new GuardError(`the plan at ${path} has no examId — reseed, or add the paper id`);
  }
  return plan;
}

function emptySessions(stages) {
  return {
    started: 0,
    submitted: 0,
    failed: 0,
    answers: 0,
    heartbeats: 0,
    heartbeatsThrottled: 0,
    heartbeatsDuplicated: 0,
    violations: 0,
    peakConcurrency: 0,
    expectedPeak: stages.reduce((max, stage) => Math.max(max, stage.target), 0),
    reasons: new Map(),
  };
}

function mergeOutcome(sessions, outcome) {
  sessions.answers += outcome.answers;
  sessions.heartbeats += outcome.heartbeats;
  sessions.heartbeatsThrottled += outcome.heartbeatsThrottled;
  sessions.heartbeatsDuplicated += outcome.heartbeatsDuplicated;
  sessions.violations += outcome.violations;
  if (outcome.submitted) {
    sessions.submitted += 1;
  } else {
    sessions.failed += 1;
    const reason = outcome.reason ?? 'unknown';
    sessions.reasons.set(reason, (sessions.reasons.get(reason) ?? 0) + 1);
  }
}

function sortedReasons(reasons) {
  return [...reasons.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

function describeTarget(environment) {
  return environment.projectRef ?? (environment.isLocal ? 'local' : 'foreign host');
}

async function main(argv) {
  const { values } = parseArgs({ args: argv, options: OPTIONS, allowPositionals: false });
  if (values.help) {
    process.stdout.write(USAGE);
    return 0;
  }

  const stages = parseStages(values.stages ?? readEnv('LOADTEST_STAGES') ?? '50:2m,200:3m,500:3m');
  const config = {
    answerEverySeconds: numberFlag(values['answer-every'], 30, 'answer-every', { min: 0.001 }),
    heartbeatEverySeconds: numberFlag(values['heartbeat-every'], 15, 'heartbeat-every', { min: 0.001 }),
    violationsPerMinute: numberFlag(values['violations-per-minute'], 0.5, 'violations-per-minute'),
    violationType: values['violation-type'] ?? 'looking_away',
    sessionSeconds: numberFlag(values['session-seconds'], 300, 'session-seconds', { min: 1 }),
  };

  const apiKey = values['anon-key'] ?? readEnv('LOADTEST_ANON_KEY');
  if (apiKey === undefined) {
    throw new GuardError('LOADTEST_ANON_KEY (or --anon-key) is required — the staging project anon key');
  }

  // The guard runs before anything is read that could be mistaken for consent to
  // start: no plan, no HTTP client, no request.
  const environment = assertStaging({
    url: values.url ?? readEnv('LOADTEST_URL'),
    apiKey,
    productionRef: readEnv('LOADTEST_PROD_REF') ?? readProductionRef(),
    allowForeignHost: readEnv('LOADTEST_ALLOW_FOREIGN_HOST') === '1',
  });

  const planPath = resolve(values.plan ?? readEnv('LOADTEST_PLAN') ?? resolve(SCRIPT_DIR, 'plan.json'));
  const plan = loadPlan(planPath);
  if (
    typeof plan.projectRef === 'string' &&
    environment.projectRef !== null &&
    plan.projectRef.toLowerCase() !== environment.projectRef.toLowerCase()
  ) {
    throw new GuardError(
      `the plan at ${planPath} was seeded in project ${plan.projectRef} but the target is ` +
        `${environment.projectRef}. Reseed against this project — the student ids would not exist there.`,
    );
  }

  const thresholds = {
    p95Ms: numberFlag(values['p95-ms'], undefined, 'p95-ms'),
    errorRate: numberFlag(values['error-rate'], undefined, 'error-rate'),
    maxServerErrors: numberFlag(values['max-5xx'], undefined, 'max-5xx'),
    maxTooManyRequests: numberFlag(values['max-429'], undefined, 'max-429'),
  };

  const seed = numberFlag(values.seed, 1, 'seed');

  if (values['dry-run']) {
    const lines = [
      'DRY RUN — nothing will be sent.',
      '',
      `target        ${environment.url}`,
      `guard         ${describeTarget(environment)} (production ref: ${environment.productionRef ?? 'unknown'})`,
      `plan          ${planPath}`,
      `students      ${plan.students.length} (first: ${plan.students[0].email})`,
      `paper         ${plan.examId}   consent ${plan.consentVersion ?? '(from plan)'}`,
      `ramp          ${stages.map((s) => `${s.target}:${Math.round(s.seconds)}s`).join(', ')} -> peak ${Math.max(...stages.map((s) => s.target))}`,
      `traffic       answer/${config.answerEverySeconds}s heartbeat/${config.heartbeatEverySeconds}s ` +
        `violations ${config.violationsPerMinute}/min (${config.violationType}) session ${config.sessionSeconds}s`,
      `longest run   ~${Math.round(rampSeconds(stages) + config.sessionSeconds)}s`,
      '',
    ];
    if (plan.students.length < Math.max(...stages.map((s) => s.target))) {
      lines.push(
        `note: the ramp peaks at ${Math.max(...stages.map((s) => s.target))} but the plan has ` +
          `${plan.students.length} students. One student sits a paper once, so the peak reached will be ` +
          `${plan.students.length}. Seed more (--count) for a real 500.`,
        '',
      );
    }
    if (config.heartbeatEverySeconds < HEARTBEAT_FLOOR_SECONDS) {
      lines.push(
        `note: --heartbeat-every ${config.heartbeatEverySeconds}s is inside the server's ` +
          `${HEARTBEAT_FLOOR_SECONDS}s window; those beats will be answered "throttled" and counted as such.`,
        '',
      );
    }
    process.stdout.write(lines.join('\n'));
    return 0;
  }

  const recorder = new Recorder();
  const client = new HttpClient({
    baseUrl: environment.url,
    apiKey,
    recorder,
    timeoutMs: numberFlag(values['timeout-ms'], 20_000, 'timeout-ms', { min: 100 }),
  });

  const sessions = emptySessions(stages);
  const startedAt = new Date().toISOString();
  const runStart = performance.now();
  const rampMs = rampSeconds(stages) * 1000;
  const hardStopMs = rampMs + config.sessionSeconds * 1000 + 15_000;

  let nextStudent = 0;
  let active = 0;
  let sessionCounter = 0;
  let aborted = false;
  let rampClosed = false;
  let lastProgressAt = runStart;
  const pending = new Set();

  const startSession = (student) => {
    sessionCounter += 1;
    sessions.started += 1;
    active += 1;
    sessions.peakConcurrency = Math.max(sessions.peakConcurrency, active);
    // A per-session stream, seeded from the run seed and the session number, so
    // two runs with the same --seed send the same choices *and* one session's
    // draws cannot depend on how many others are in flight.
    const sessionRng = createRng(seed + sessionCounter * 7919);
    const promise = runStudentSession({
      client,
      student,
      plan,
      settings: config,
      sessionId: `s${sessionCounter}`,
      rng: sessionRng,
    })
      .then((outcome) => mergeOutcome(sessions, outcome))
      .catch((error) => {
        sessions.failed += 1;
        const reason = `threw: ${error?.message ?? String(error)}`;
        sessions.reasons.set(reason, (sessions.reasons.get(reason) ?? 0) + 1);
      })
      .finally(() => {
        active -= 1;
        pending.delete(promise);
      });
    pending.add(promise);
  };

  // ---- The ramp ----------------------------------------------------------
  while (true) {
    const elapsedMs = performance.now() - runStart;
    const rampOver = elapsedMs > rampMs;
    // While the ramp runs, the target is where the schedule says it is. After it
    // closes, the target is the peak — for exactly one catch-up pass, see below.
    const target = rampOver
      ? sessions.expectedPeak
      : Math.round(targetAt(stages, elapsedMs / 1000));

    // New sittings start while the ramp is running, plus a single catch-up pass
    // at the instant it closes. The loop samples every 200ms, so the last
    // increment of the final stage can land in the gap between the last sample
    // and the ramp's own end — a small plan (or a test's "6:1s") then starts
    // fewer sittings than the stage asked for and reports a peak it never
    // reached. The catch-up starts only what the peak still allows, so it is at
    // most one stage's worth of sessions on a real ramp.
    if (!rampOver || !rampClosed) {
      while (active < target && nextStudent < plan.students.length) {
        startSession(plan.students[nextStudent]);
        nextStudent += 1;
      }
    }
    if (rampOver) rampClosed = true;

    // After the ramp, the run drains: a sitting that began at the top of the
    // last stage is still a student in an exam, and cutting it off would delete
    // the submit leg — the single most expensive request in the whole flow.
    if (rampOver && active === 0) break;
    if (elapsedMs > hardStopMs) {
      aborted = true;
      break;
    }

    if (!values.quiet && performance.now() - lastProgressAt >= 15_000) {
      lastProgressAt = performance.now();
      const partial = recorder.summarise();
      process.stdout.write(
        `${String(Math.round(elapsedMs / 1000)).padStart(5)}s  target ${String(target).padStart(3)}  ` +
          `active ${String(active).padStart(3)}  requests ${partial.requests}  ` +
          `errors ${partial.errors} (${(partial.errorRate * 100).toFixed(2)}%)  ` +
          `p95 ${Math.round(partial.p95)}ms\n`,
      );
    }

    await sleep(200);
  }

  if (pending.size > 0) {
    // Bounded drain: an in-flight request that will never answer must not keep
    // the process alive, but the report has to say the numbers are partial.
    const drained = await Promise.race([
      Promise.allSettled([...pending]).then(() => true),
      sleep(15_000).then(() => false),
    ]);
    if (!drained) aborted = true;
  }

  if (aborted) {
    const reason = 'run aborted with sittings still in flight — the numbers below are partial';
    sessions.reasons.set(reason, (sessions.reasons.get(reason) ?? 0) + 1);
  }
  if (nextStudent >= plan.students.length && sessions.peakConcurrency < sessions.expectedPeak) {
    const reason =
      `only ${plan.students.length} students in the plan, so the peak was ` +
      `${sessions.peakConcurrency} of ${sessions.expectedPeak} — seed more to reach the top stage`;
    sessions.reasons.set(reason, (sessions.reasons.get(reason) ?? 0) + 1);
  }

  const durationSeconds = (performance.now() - runStart) / 1000;
  const summary = recorder.summarise();
  const verdicts = evaluateThresholds(summary, thresholds);
  const reportSessions = { ...sessions, reasons: sortedReasons(sessions.reasons) };

  process.stdout.write(`\n${formatReport({
    environment,
    stages,
    summary,
    sessions: reportSessions,
    config,
    startedAt,
    durationSeconds,
    verdicts,
  })}\n`);

  if (values.out !== undefined) {
    const outPath = resolve(values.out);
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(
      outPath,
      `${JSON.stringify(toJsonReport({
        environment,
        stages,
        summary,
        sessions: reportSessions,
        config,
        startedAt,
        durationSeconds,
        verdicts,
      }), null, 2)}\n`,
      'utf8',
    );
    process.stdout.write(`JSON report: ${outPath}\n`);
  }

  const failed = verdicts.some((verdict) => !verdict.ok) || aborted;
  return failed ? EXIT_THRESHOLD : 0;
}

main(process.argv.slice(2))
  .then((code) => {
    process.exit(code);
  })
  .catch((error) => {
    process.stderr.write(`\nerror: ${error?.message ?? String(error)}\n\n`);
    if (error instanceof GuardError || error?.name === 'StageError') {
      process.stderr.write('Run with --help for the options. Nothing was sent.\n');
    }
    process.exit(EXIT_CONFIG);
  });
