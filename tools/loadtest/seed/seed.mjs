#!/usr/bin/env node
/**
 * Seeds a staging project with what a load test needs: N student accounts, a
 * published paper they may sit, and a `plan.json` that `load.mjs` reads.
 *
 *   LOADTEST_URL=https://<staging-ref>.supabase.co \
 *   LOADTEST_SERVICE_KEY=<service_role key> \
 *   node tools/loadtest/seed/seed.mjs --count 500
 *
 * Why this is separate from `load.mjs`:
 *
 *   * it needs the **service_role** key (creating accounts, publishing a paper),
 *     which is a key the load generator itself must never hold — a run that had
 *     it could answer 500 sessions without ever exercising RLS, and RLS is half
 *     of what the run is measuring;
 *   * it writes rows (`profiles`, `exams`, `questions`, `exam_allowed_students`)
 *     that are *setup*, not traffic, and counting them would distort the
 *     latency percentiles;
 *   * it is run once per environment, not once per run.
 *
 * The same production guard as the load test runs first, against the service
 * key — its `ref` claim is the strongest evidence available that the key really
 * is the staging project's, and the consequence of getting this wrong (500 real
 * accounts and a published paper on the production project) is worse than a
 * noisy run.
 *
 * Idempotent by design: re-running with the same `--prefix`/`--tag` reuses the
 * accounts GoTrue already has, reuses the seeder's paper, and rewrites
 * `plan.json`. `--reset` deletes the accounts this seeder made (their profiles,
 * attempts, answers and violations cascade) so a run starts from zero.
 */

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { parseArgs } from 'node:util';

import { HttpClient } from '../lib/http.mjs';
import { Recorder } from '../lib/metrics.mjs';
import { assertStaging, readProductionRef, GuardError } from '../lib/guard.mjs';

const EXIT_CONFIG = 2;

const DEFAULTS = {
  count: 50,
  domain: 'proctorguard.test',
  prefix: 'loadtest',
  tag: 'staging',
  password: 'Loadtest!2026',
  title: 'Load test paper',
  durationMinutes: 180,
  questions: 5,
  batchSize: 200,
  concurrency: 8,
};

/** Marks the papers this script created, so it can find them again. */
const TITLE_PREFIX = '[loadtest]';

const USAGE = `ProctorGuard staging seeder

  node tools/loadtest/seed/seed.mjs [options]

  --url <url>              staging project URL           (env LOADTEST_URL)
  --service-key <key>      service_role key              (env LOADTEST_SERVICE_KEY)
  --count <n>              student accounts to ensure    (default ${DEFAULTS.count})
  --prefix <text>          email prefix                  (default ${DEFAULTS.prefix})
  --tag <text>             email tag, for parallel runs  (default ${DEFAULTS.tag})
  --domain <domain>        email domain                  (default ${DEFAULTS.domain})
  --password <text>        student password              (default ${DEFAULTS.password})
  --exam-id <uuid>         use this published paper instead of creating one
  --creator <uuid>         profile id that owns the created paper
  --title <text>           title of the created paper    (default "${DEFAULTS.title}")
  --questions <n>          questions in the created paper (default ${DEFAULTS.questions})
  --faculty <text>         label the accounts (targeting)
  --department <text>      label the accounts (targeting)
  --level <text>           label the accounts (targeting)
  --out <path>             where to write plan.json      (default ./plan.json)
  --reset                  delete this seeder's accounts and paper first
  --no-verify              skip the sign-in check at the end
  --dry-run                print what would be written and exit
  --help

Email addresses are \`<prefix>-<tag>-<n>@<domain>\`, so two runs against one
project can be seeded side by side with different --tags.

Exit codes: 0 ok, 2 bad configuration or the guard refused.
`;

const OPTIONS = {
  url: { type: 'string' },
  'service-key': { type: 'string' },
  count: { type: 'string' },
  prefix: { type: 'string' },
  tag: { type: 'string' },
  domain: { type: 'string' },
  password: { type: 'string' },
  'exam-id': { type: 'string' },
  creator: { type: 'string' },
  title: { type: 'string' },
  questions: { type: 'string' },
  faculty: { type: 'string' },
  department: { type: 'string' },
  level: { type: 'string' },
  out: { type: 'string' },
  reset: { type: 'boolean', default: false },
  'no-verify': { type: 'boolean', default: false },
  'dry-run': { type: 'boolean', default: false },
  help: { type: 'boolean', default: false },
};

function readEnv(name) {
  const value = process.env[name];
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined;
}

function numberFlag(raw, fallback, name, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new GuardError(`--${name} must be a number between ${min} and ${max}, got "${raw}"`);
  }
  return value;
}

function* chunks(items, size) {
  for (let index = 0; index < items.length; index += size) {
    yield items.slice(index, index + size);
  }
}

/** Runs `worker` over `items` with `limit` in flight, keeping the input order. */
async function pool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(runners);
  return results;
}

/**
 * A PostgREST/GoTrue client that always speaks as service_role.
 *
 * Reusing `HttpClient` rather than `fetch`: it has the timeout, the no-retry
 * rule and the status-as-a-value contract the rest of this directory relies on,
 * and the seeder should fail as loudly on a 429 as the load test does.
 */
function createApi({ client, serviceKey }) {
  const call = (op, path, { method = 'GET', body, prefer } = {}) => client.call(op, path, {
    method,
    token: serviceKey,
    body,
    headers: {
      // Service-role requests are already privileged; asking PostgREST for a
      // count or a merge is what keeps the seeder to one round trip per batch.
      ...(prefer === undefined ? {} : { Prefer: prefer }),
    },
  });

  return {
    call,
    /** Unwraps a call that must have succeeded, with the server's own words if not. */
    async must(op, path, options) {
      const result = await call(op, path, options);
      if (!result.ok) {
        throw new GuardError(`${op} ${method(options)} ${path.split('?')[0]} -> ${result.status}: ${HttpClient.errorMessage(result)}`);
      }
      return result.data;
    },
  };
}

function method(options) {
  return options?.method ?? 'GET';
}

function emailFor(config, index) {
  return `${config.prefix}-${config.tag}-${index}@${config.domain}`;
}

function fullNameFor(config, index) {
  return `${config.prefix} student ${index} (${config.tag})`;
}

// ---- The project's own state ------------------------------------------------

/**
 * The consent notice version in force.
 *
 * Read rather than assumed: `student_has_consent()` compares the acceptance
 * against `current_proctor_consent_version()`, so a plan carrying a hard-coded
 * version would seed accounts that cannot create an attempt — and the load test
 * would report a 403 wall that is really the seeder's fault.
 */
async function readConsentVersion(api) {
  const rows = await api.must(
    'consent_version',
    '/rest/v1/proctoring_consent_config?select=current_version&id=eq.1',
  );
  const version = Array.isArray(rows) ? rows[0]?.current_version : rows?.current_version;
  if (typeof version !== 'string' || version.trim() === '') {
    throw new GuardError(
      'the project has no proctoring_consent_config row, so no student could accept the ' +
        'notice. Run supabase/schema.sql against this project first.',
    );
  }
  return version;
}

/** Every auth user in the project, paged. GoTrue caps `per_page` at 1000. */
async function listAuthUsers(api) {
  const users = [];
  for (let page = 1; page <= 100; page += 1) {
    const body = await api.must('users_list', `/auth/v1/admin/users?page=${page}&per_page=1000`);
    const rows = Array.isArray(body) ? body : (Array.isArray(body?.users) ? body.users : []);
    users.push(...rows);
    if (rows.length < 1000) break;
  }
  return users;
}

function userIdOf(body) {
  if (body === null || typeof body !== 'object') return null;
  const id = body.id ?? body.user?.id;
  return typeof id === 'string' && id !== '' ? id : null;
}

/**
 * One student, one auth account. Creates it, or finds the one a previous run
 * made and re-sets its password so `plan.json` is always the truth.
 */
async function ensureAccount(api, config, { index, email, fullName }) {
  const created = await api.call('user_create', '/auth/v1/admin/users', {
    method: 'POST',
    body: {
      email,
      password: config.password,
      // Pre-confirmed: a load-test account that needs an inbox is a run that
      // cannot start.
      email_confirm: true,
      user_metadata: { full_name: fullName, role: 'student' },
    },
  });

  if (created.ok) {
    const id = userIdOf(created.data);
    if (id === null) throw new GuardError(`user_create for ${email} returned no id`);
    return { id, email, fullName, index, action: 'created' };
  }

  const conflict = created.status === 422 || created.status === 409 || created.status === 400;
  if (!conflict || !/exist|registered|duplicate/i.test(HttpClient.errorMessage(created))) {
    throw new GuardError(`user_create ${email} -> ${created.status}: ${HttpClient.errorMessage(created)}`);
  }

  // The account is already there; we still need its id, and its password has to
  // match the plan.
  const existing = (await listAuthUsers(api)).find(
    (user) => typeof user.email === 'string' && user.email.toLowerCase() === email.toLowerCase(),
  );
  if (existing === undefined) {
    throw new GuardError(
      `GoTrue says ${email} exists but it is not in the user list. Delete it in the ` +
        'dashboard, or seed with a different --tag.',
    );
  }
  const updated = await api.call('user_password', `/auth/v1/admin/users/${existing.id}`, {
    method: 'PUT',
    body: { password: config.password, email_confirm: true },
  });
  if (!updated.ok) {
    throw new GuardError(`user_password ${email} -> ${updated.status}: ${HttpClient.errorMessage(updated)}`);
  }
  return { id: existing.id, email, fullName, index, action: 'reused' };
}

async function ensureAccounts(api, config) {
  const indexes = Array.from({ length: config.count }, (_, index) => index + 1);
  const accounts = [];
  const counts = { created: 0, reused: 0 };
  for (const batch of chunks(indexes, config.batchSize)) {
    const results = await pool(batch, config.concurrency, (index) => ensureAccount(api, config, {
      index,
      email: emailFor(config, index),
      fullName: fullNameFor(config, index),
    }));
    for (const account of results) {
      counts[account.action] += 1;
      accounts.push(account);
    }
    process.stdout.write(`  accounts ${String(accounts.length).padStart(4)}/${config.count}\n`);
  }
  return { accounts, counts };
}

// ---- Rows the load test needs -----------------------------------------------

function profileRow(config, account, role) {
  return {
    id: account.id,
    role,
    full_name: account.fullName,
    email: account.email,
    faculty: config.faculty ?? null,
    department: config.department ?? null,
    level: config.level ?? null,
  };
}

/**
 * The `profiles` row for each account.
 *
 * A GoTrue account and an application account are two rows, and the schema's
 * `profiles.id` points at `auth.users` without a trigger to create it — so the
 * seeder, like the admin Edge Function, writes both. `merge-duplicates` makes a
 * re-run a no-op instead of a 409.
 */
async function upsertProfiles(api, config, rows) {
  for (const batch of chunks(rows, config.batchSize)) {
    await api.must('profiles_upsert', '/rest/v1/profiles?on_conflict=id', {
      method: 'POST',
      prefer: 'resolution=merge-duplicates,return=minimal',
      body: batch,
    });
  }
}

/**
 * A supervisor to own the seeded paper.
 *
 * `exams.created_by` is not null and there is no way around it: a paper without
 * an owner cannot be created by any policy. Rather than make the operator click
 * through the dashboard first, the seeder makes its own staff account — the
 * service_role key may write `profiles.role`, which is exactly what the schema's
 * `guard_user_role_change()` allows it to do.
 */
async function ensureTeacher(api, config) {
  const email = `${config.prefix}-${config.tag}-teacher@${config.domain}`;
  const account = await ensureAccount(api, config, {
    index: 0,
    email,
    fullName: `${config.prefix} supervisor (${config.tag})`,
  });
  await upsertProfiles(api, config, [profileRow(config, account, 'supervisor')]);
  return account.id;
}

/** The paper this seeder created for the tag, if a previous run made one. */
async function findSeedExam(api, title) {
  const rows = await api.must(
    'exam_find',
    `/rest/v1/exams?select=id,title&title=eq.${encodeURIComponent(title)}`,
  );
  return Array.isArray(rows) && rows.length > 0 ? rows[0] : null;
}

async function ensureExam(api, config, log) {
  if (config.examId !== undefined) {
    // An existing paper is the safest choice: it is already published, already
    // targeted, and — most importantly — not something this script may delete.
    log(`  paper  reusing ${config.examId} (from --exam-id)`);
    return config.examId;
  }

  const title = `${TITLE_PREFIX} ${config.title}`;
  const existing = await findSeedExam(api, title);
  if (existing !== null) {
    log(`  paper  reusing "${title}" (${existing.id})`);
    return existing.id;
  }

  const creator = config.creator ?? await ensureTeacher(api, config);
  const rows = await api.must('exam_create', '/rest/v1/exams', {
    method: 'POST',
    prefer: 'return=representation',
    body: {
      title,
      created_by: creator,
      duration_minutes: config.durationMinutes,
      is_published: true,
      // No window: `attempt_deadline()` reads these, and a load test that ends
      // with "the paper closed" would measure the clock instead of the server.
      starts_at: null,
      ends_at: null,
      faculty: config.faculty ?? null,
      department: config.department ?? null,
      level: config.level ?? null,
    },
  });
  const exam = Array.isArray(rows) ? rows[0] : rows;
  if (typeof exam?.id !== 'string') throw new GuardError('exam_create returned no id');
  log(`  paper  created "${title}" (${exam.id})`);
  return exam.id;
}

async function ensureQuestions(api, config, examId, log) {
  const existing = await api.must(
    'questions_find',
    `/rest/v1/questions?select=id&exam_id=eq.${examId}&limit=1`,
  );
  if (Array.isArray(existing) && existing.length > 0) {
    log('  paper  already has questions');
    return 0;
  }
  // Every key is correct-option 0 and every point is 1: the load test picks a
  // random option and never reads the score back, so what matters is that the
  // rows are internally valid (the `questions_answer_key_shape` check) and that
  // `questions_public` has something to return.
  const rows = Array.from({ length: config.questions }, (_, index) => ({
    exam_id: examId,
    question_text: `Load test question ${index + 1}`,
    question_type: 'multiple_choice',
    options: ['A', 'B', 'C', 'D'],
    correct_option: 0,
    points: 1,
  }));
  await api.must('questions_insert', '/rest/v1/questions', {
    method: 'POST',
    prefer: 'return=minimal',
    body: rows,
  });
  log(`  paper  inserted ${rows.length} question(s)`);
  return rows.length;
}

/**
 * Makes the paper reachable for every seeded account.
 *
 * `student_can_access_exam()` accepts a student either by the paper's
 * faculty/department/level labels or by a row in `exam_allowed_students` (the
 * "borrowed course" exception list). The seeder always writes the exception
 * list: it works against a paper that was targeted by labels the accounts do not
 * carry, and against one that was never targeted at all.
 */
async function ensureTargeting(api, config, examId, accounts, log) {
  const rows = accounts.map((account) => ({ exam_id: examId, student_id: account.id }));
  for (const batch of chunks(rows, config.batchSize)) {
    await api.must('targeting_upsert', '/rest/v1/exam_allowed_students?on_conflict=exam_id,student_id', {
      method: 'POST',
      prefer: 'resolution=ignore-duplicates,return=minimal',
      body: batch,
    });
  }
  log(`  access  ${rows.length} account(s) allowed to sit it`);
}

// ---- Reset and verification -------------------------------------------------

async function resetSeedState(api, config, log) {
  if (config.examId === undefined) {
    // Papers first: `exam_submissions.exam_id` cascades, so this clears attempts
    // without waiting for 500 auth-user deletes to cascade through `profiles`.
    const papers = await api.must('exam_list', '/rest/v1/exams?select=id,title&limit=1000');
    const seeds = (Array.isArray(papers) ? papers : []).filter(
      (paper) => typeof paper.title === 'string' && paper.title.startsWith(TITLE_PREFIX),
    );
    for (const paper of seeds) {
      await api.call('exam_delete', `/rest/v1/exams?id=eq.${paper.id}`, { method: 'DELETE' });
    }
    log(`  reset   removed ${seeds.length} seeded paper(s)`);
  }

  const prefix = `${config.prefix}-${config.tag}-`;
  const users = (await listAuthUsers(api)).filter(
    (user) => typeof user.email === 'string' && user.email.toLowerCase().startsWith(prefix.toLowerCase()),
  );
  let deleted = 0;
  for (const user of users) {
    const result = await api.call('user_delete', `/auth/v1/admin/users/${user.id}`, { method: 'DELETE' });
    if (result.ok || result.status === 404) deleted += 1;
  }
  log(`  reset   deleted ${deleted} account(s) and the profiles that hang off them`);
}

/**
 * Signs the first student in, with the anon/publishable key path the app uses.
 *
 * Worth one request: the failure it catches — a plan whose password does not
 * match the accounts, or an account created without a confirmed email — would
 * otherwise appear as a 100% error rate in a 500-session run, hours later.
 */
async function verifySignIn(client, config, account) {
  const result = await client.call('verify_signin', '/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: { email: account.email, password: config.password },
  });
  return result.ok
    ? { ok: true }
    : { ok: false, detail: `${result.status}: ${HttpClient.errorMessage(result)}` };
}

// ---- The plan ---------------------------------------------------------------

function buildPlan({ environment, examId, consentVersion, config, accounts }) {
  return {
    generatedAt: new Date().toISOString(),
    url: environment.url,
    projectRef: environment.projectRef,
    examId,
    consentVersion,
    password: config.password,
    students: accounts.map((account) => ({ id: account.id, email: account.email })),
  };
}

// ---- Command line -----------------------------------------------------------

const TOKEN_RE = /^[a-z0-9][a-z0-9._-]*$/i;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function slugFlag(value, flag) {
  // `--tag` is how two runs share a project, and the value goes into a real email
  // address: a typo here seeds a *second* cohort instead of reusing the first.
  if (typeof value !== 'string' || value.length > 40 || !TOKEN_RE.test(value)) {
    throw new GuardError(`--${flag} must be 1-40 characters of letters, digits, ".", "_" or "-", got "${value}"`);
  }
  return value.toLowerCase();
}

function domainFlag(value) {
  const ok = typeof value === 'string' &&
    /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i.test(value);
  if (!ok) throw new GuardError(`--domain must be a domain name, got "${value}"`);
  return value.toLowerCase();
}

function uuidFlag(value, flag) {
  const trimmed = typeof value === 'string' ? value.trim() : '';
  if (!UUID_RE.test(trimmed)) throw new GuardError(`--${flag} must be a uuid, got "${value}"`);
  return trimmed.toLowerCase();
}

function passwordFlag(value) {
  // GoTrue's default minimum length is 6. Below that every sign-in fails and the
  // load test blames the server for it.
  if (typeof value !== 'string' || value.length < 8) {
    throw new GuardError('the student password must be at least 8 characters');
  }
  return value;
}

function buildConfig(values) {
  const title = typeof values.title === 'string' ? values.title.trim() : '';
  return {
    count: numberFlag(values.count, DEFAULTS.count, 'count', { min: 1, max: 5000 }),
    questions: numberFlag(values.questions, DEFAULTS.questions, 'questions', { min: 1, max: 200 }),
    domain: domainFlag(values.domain ?? DEFAULTS.domain),
    prefix: slugFlag(values.prefix ?? DEFAULTS.prefix, 'prefix'),
    tag: slugFlag(values.tag ?? DEFAULTS.tag, 'tag'),
    password: passwordFlag(values.password ?? readEnv('LOADTEST_STUDENT_PASSWORD') ?? DEFAULTS.password),
    title: title === '' ? DEFAULTS.title : title,
    durationMinutes: DEFAULTS.durationMinutes,
    batchSize: DEFAULTS.batchSize,
    concurrency: DEFAULTS.concurrency,
    examId: values['exam-id'] === undefined ? undefined : uuidFlag(values['exam-id'], 'exam-id'),
    creator: values.creator === undefined ? undefined : uuidFlag(values.creator, 'creator'),
    faculty: values.faculty ?? undefined,
    department: values.department ?? undefined,
    level: values.level ?? undefined,
    reset: values.reset === true,
    verify: values['no-verify'] !== true,
  };
}

function describeRange(config) {
  return config.count === 1
    ? emailFor(config, 1)
    : `${emailFor(config, 1)} … ${emailFor(config, config.count)}`;
}

async function main(argv = process.argv.slice(2)) {
  const { values } = parseArgs({ args: argv, options: OPTIONS, allowPositionals: false });
  if (values.help === true) {
    process.stdout.write(USAGE);
    return 0;
  }

  const config = buildConfig(values);
  const serviceKey = values['service-key'] ?? readEnv('LOADTEST_SERVICE_KEY');
  if (serviceKey === undefined) {
    throw new GuardError(
      'the service_role key is required: set LOADTEST_SERVICE_KEY or pass --service-key.\n' +
        '  Supabase dashboard -> Project Settings -> API keys -> service_role.\n' +
        '  Never the production project\'s key: the seeder creates accounts and publishes a paper.',
    );
  }

  // Same guard, same order as load.mjs: the target is proved before a single
  // account exists. `apiKey` is the service key here, and its `ref` claim is the
  // strongest evidence available that this really is the intended project.
  const environment = assertStaging({
    url: values.url ?? readEnv('LOADTEST_URL'),
    apiKey: serviceKey,
    productionRef: readEnv('LOADTEST_PROD_REF') ?? readProductionRef(),
    allowForeignHost: readEnv('LOADTEST_ALLOW_FOREIGN_HOST') === '1',
  });

  const outPath = resolve(values.out ?? readEnv('LOADTEST_PLAN') ?? 'plan.json');
  const log = (line) => process.stdout.write(`${line}\n`);

  log(`ProctorGuard seeder -> ${environment.projectRef ?? (environment.isLocal ? 'local' : 'foreign host')}`);
  log(`  target  ${environment.url}`);
  log(`  cohort  ${config.count} account(s): ${describeRange(config)}`);

  if (values['dry-run'] === true) {
    log('  dry-run no request was sent and no row was written');
    log(`  plan    would write ${outPath}`);
    return 0;
  }

  const client = new HttpClient({ baseUrl: environment.url, apiKey: serviceKey, recorder: new Recorder() });
  const api = createApi({ client, serviceKey });

  const consentVersion = await readConsentVersion(api);
  log(`  consent "${consentVersion}" is the version in force`);

  if (config.reset === true) {
    await resetSeedState(api, config, log);
  }

  const { accounts, counts } = await ensureAccounts(api, config);
  log(`  accounts ${counts.created} created, ${counts.reused} reused`);

  await upsertProfiles(api, config, accounts.map((account) => profileRow(config, account, 'student')));
  log('  profiles written (role = student)');

  const examId = await ensureExam(api, config, log);
  await ensureQuestions(api, config, examId, log);
  await ensureTargeting(api, config, examId, accounts, log);

  if (config.verify === true) {
    // One sign-in, before the plan is handed over: the failure it catches (a
    // password that does not match, an unconfirmed account) would otherwise show
    // up as a 100% error rate in a 500-session run.
    const check = await verifySignIn(client, config, accounts[0]);
    if (!check.ok) {
      throw new GuardError(
        `the first seeded account cannot sign in (${check.detail}).\n` +
          '  Nothing was written. Check the project\'s auth settings (email confirmation, ' +
          'password policy) and that --password is the one load.mjs will read.',
      );
    }
    log('  verify  sign-in succeeds for the first account');
  }

  const plan = buildPlan({ environment, examId, consentVersion, config, accounts });
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(plan, null, 2)}\n`, 'utf8');
  log(`  plan    ${outPath}`);

  log('');
  log(`Seeded ${accounts.length} student(s) on ${plan.url}`);
  log(`  paper    ${examId}`);
  log(`  password ${plan.password}`);
  log('');
  log('This key has done its job. The load run needs the anon key, never this one:');
  log(`  LOADTEST_URL=${plan.url} LOADTEST_ANON_KEY=<anon key> \\`);
  log(`    node tools/loadtest/load.mjs --plan ${JSON.stringify(outPath)} --dry-run`);
  log('');
  log('Then the same command without --dry-run. Start with the small stage.');
  return 0;
}

main(process.argv.slice(2))
  .then((code) => {
    process.exit(code);
  })
  .catch((error) => {
    process.stderr.write(`\nseed error: ${error?.message ?? String(error)}\n\n`);
    if (error instanceof GuardError) {
      process.stderr.write('Run with --help for the options. Nothing was written.\n');
    }
    process.exit(EXIT_CONFIG);
  });
