#!/usr/bin/env node
/**
 * A fake Supabase, for testing the load-test script itself.
 *
 * This is **not** a model of Supabase. It answers the handful of endpoints a
 * student sitting touches, with the shapes PostgREST and GoTrue return, so that
 * `load.mjs` can be run end to end on a laptop — in seconds, with no staging
 * project, no credentials and no traffic leaving the machine.
 *
 * It exists because the alternative is a script nobody runs until the day they
 * need it, and a load test that has never completed a session is a script with
 * bugs in its own control flow. It can also inject failures on purpose
 * (`--fail-rate`), which is the only way to see that the report's 429 and 5xx
 * lines actually fill in.
 *
 *   node tools/loadtest/stub/fake_supabase.mjs --port 54321 --fail-rate 0.05
 *
 * Prints one JSON line `{"port":N}` on stdout once it is listening, so a test
 * can start it on port 0 and learn the real port.
 */

import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    port: { type: 'string', default: '0' },
    'fail-rate': { type: 'string', default: '0' },
    'fail-statuses': { type: 'string', default: '429,503' },
    'fail-seed': { type: 'string', default: '7' },
  },
});

const failRate = Number(values['fail-rate']);
const failStatuses = values['fail-statuses']
  .split(',')
  .map((text) => Number(text.trim()))
  .filter(Number.isFinite);
const examId = '11111111-1111-4111-8111-111111111111';
const questionIds = [
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444',
];

// Deterministic failure injection: a run meant to fail 5% of requests should
// fail the same 5% twice, or a failing test cannot be reproduced.
let seed = Number(values['fail-seed']) >>> 0;
function nextRandom() {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

let requests = 0;

/**
 * The auth user store the seeder writes to.
 *
 * In memory and per-process: enough to tell "created" from "already there",
 * which is the branch `seed.mjs` takes care over, and to answer a re-run with
 * `reused` instead of a duplicate. Nothing else in a sitting reads it.
 */
const users = new Map();

/** Papers created through POST /rest/v1/exams, by id — the seeder's own. */
const papers = new Map();

function send(response, status, payload) {
  const body = payload === undefined ? '' : JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve) => {
    let raw = '';
    request.on('data', (chunk) => {
      raw += chunk;
    });
    request.on('end', () => {
      try {
        resolve(raw === '' ? null : JSON.parse(raw));
      } catch {
        resolve(null);
      }
    });
  });
}

const server = createServer(async (request, response) => {
  requests += 1;
  const url = new URL(request.url, 'http://stub.local');
  const path = url.pathname;
  const method = request.method ?? 'GET';

  if (failRate > 0 && nextRandom() < failRate && failStatuses.length > 0) {
    const status = failStatuses[Math.floor(nextRandom() * failStatuses.length)];
    send(response, status, {
      message: status === 429 ? 'stub: rate limit exceeded' : 'stub: injected server error',
      code: status === 429 ? '429' : 'STUB500',
    });
    return;
  }

  if (method === 'POST' && path === '/auth/v1/token') {
    const body = await readBody(request);
    if (body === null || typeof body.email !== 'string') {
      send(response, 400, { error: 'invalid_grant', error_description: 'stub: email required' });
      return;
    }
    send(response, 200, {
      access_token: `stub.${Buffer.from(JSON.stringify({ sub: body.email })).toString('base64url')}`,
      token_type: 'bearer',
      expires_in: 3600,
      refresh_token: 'stub-refresh',
      user: { id: randomUUID(), email: body.email },
    });
    return;
  }

  if (method === 'GET' && path === '/rest/v1/exams') {
    const title = url.searchParams.get('title');
    if (title !== null && title.startsWith('eq.')) {
      // The seeder asks by title to find a paper it made earlier. Answering from
      // a store this stub keeps is what makes both branches — "reuse the paper"
      // and "create one" — reachable in a test.
      const wanted = title.slice('eq.'.length);
      const matches = wanted === 'Stub paper'
        ? [{ id: examId, title: 'Stub paper' }]
        : [...papers.values()].filter((paper) => paper.title === wanted);
      send(response, 200, matches);
      return;
    }
    send(response, 200, [{ id: examId, title: 'Stub paper', duration_minutes: 180 }, ...papers.values()]);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/exams') {
    const body = await readBody(request);
    const paper = {
      id: randomUUID(),
      title: body?.title ?? 'Stub paper',
      duration_minutes: body?.duration_minutes ?? 180,
      is_published: body?.is_published ?? true,
    };
    papers.set(paper.id, paper);
    send(response, 201, [paper]);
    return;
  }

  if (method === 'DELETE' && path === '/rest/v1/exams') {
    const id = url.searchParams.get('id');
    if (id !== null && id.startsWith('eq.')) papers.delete(id.slice('eq.'.length));
    response.writeHead(204, { 'Content-Length': '0' });
    response.end();
    return;
  }

  if (method === 'POST' && path === '/rest/v1/exam_submissions') {
    const body = await readBody(request);
    send(response, 201, [{
      id: randomUUID(),
      exam_id: body?.exam_id ?? examId,
      student_id: body?.student_id ?? null,
      status: 'ongoing',
    }]);
    return;
  }

  if (method === 'GET' && path === '/rest/v1/exam_submissions') {
    send(response, 200, [{ id: randomUUID(), status: 'ongoing' }]);
    return;
  }

  if (method === 'GET' && path === '/rest/v1/questions_public') {
    send(response, 200, questionIds.map((id, index) => ({
      id,
      exam_id: examId,
      question_text: `Stub question ${index + 1}`,
      question_type: 'multiple_choice',
      options: ['a', 'b', 'c', 'd'],
      points: 1,
    })));
    return;
  }

  if (method === 'POST' && path === '/rest/v1/rpc/record_consent') {
    send(response, 200, [{
      consent_id: randomUUID(),
      consent_version: 'stub',
      accepted_at: new Date().toISOString(),
      is_current: true,
    }]);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/rpc/merge_submission_answer') {
    // `merge_submission_answer` returns void: PostgREST answers 204 with no body,
    // and the client has to treat an empty body as success rather than a parse
    // error.
    response.writeHead(204, { 'Content-Length': '0' });
    response.end();
    return;
  }

  if (method === 'POST' && path === '/rest/v1/rpc/record_heartbeat') {
    const body = await readBody(request);
    if (body?.p_submission_id === undefined) {
      send(response, 400, { message: 'stub: p_submission_id is required', code: '22023' });
      return;
    }
    // Every third beat is throttled, so the report's throttle counter has
    // something to count on the happy path too.
    const outcome = requests % 3 === 0 ? 'throttled' : 'recorded';
    send(response, 200, [{ outcome, recorded_at: new Date().toISOString(), beat_count: 1 }]);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/rpc/register_violation') {
    send(response, 200, [{ warning_count: 1, disqualified: false, flagged: false }]);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/rpc/submit_exam') {
    send(response, 200, [{ result_status: 'submitted', final_score: 7 }]);
    return;
  }

  // ---- What `seed/seed.mjs` touches -------------------------------------
  // Not part of a sitting: these are the setup endpoints, kept here so the
  // seeder's control flow (create-or-reuse, find-or-create the paper, write the
  // plan) can be run on a laptop instead of only against a real project.

  if (method === 'GET' && path === '/stub/stats') {
    // The one way a test can see what a run actually did to the "project".
    send(response, 200, { requests, users: [...users.values()].map((user) => user.email) });
    return;
  }

  if (method === 'GET' && path === '/rest/v1/proctoring_consent_config') {
    send(response, 200, [{ id: 1, current_version: 'stub-1' }]);
    return;
  }

  if (path === '/auth/v1/admin/users') {
    if (method === 'GET') {
      send(response, 200, { aud: 'authenticated', users: [...users.values()] });
      return;
    }
    if (method === 'POST') {
      const body = await readBody(request);
      if (typeof body?.email !== 'string' || typeof body?.password !== 'string') {
        send(response, 422, {
          code: 422,
          error_code: 'validation_failed',
          msg: 'stub: email and password are required',
        });
        return;
      }
      const key = body.email.toLowerCase();
      if (users.has(key)) {
        // GoTrue's own answer for a duplicate. The seeder reads this, finds the
        // account and resets its password — the path a second run takes.
        send(response, 422, {
          code: 422,
          error_code: 'email_exists',
          msg: 'A user with this email address has already been registered',
        });
        return;
      }
      const user = {
        id: randomUUID(),
        email: body.email,
        email_confirmed_at: body.email_confirm === true ? new Date().toISOString() : null,
      };
      users.set(key, user);
      send(response, 200, user);
      return;
    }
  }

  const adminUser = path.match(/^\/auth\/v1\/admin\/users\/([0-9a-fA-F-]{36})$/);
  if (adminUser !== null) {
    const id = adminUser[1].toLowerCase();
    if (method === 'PUT') {
      await readBody(request);
      send(response, 200, { id });
      return;
    }
    if (method === 'DELETE') {
      for (const [key, user] of users) {
        if (user.id.toLowerCase() === id) users.delete(key);
      }
      response.writeHead(204, { 'Content-Length': '0' });
      response.end();
      return;
    }
  }

  if (method === 'GET' && path === '/rest/v1/profiles') {
    // No staff account exists: the seeder has to make its own supervisor to own
    // the paper, which is the branch worth exercising.
    send(response, 200, []);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/profiles') {
    await readBody(request);
    send(response, 201, []);
    return;
  }

  if (method === 'GET' && path === '/rest/v1/questions') {
    send(response, 200, []);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/questions') {
    await readBody(request);
    send(response, 201, []);
    return;
  }

  if (method === 'POST' && path === '/rest/v1/exam_allowed_students') {
    await readBody(request);
    send(response, 201, []);
    return;
  }

  send(response, 404, { message: `stub: no route for ${method} ${path}` });
});

server.listen(Number(values.port), '127.0.0.1', () => {
  process.stdout.write(`${JSON.stringify({ port: server.address().port })}\n`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}
