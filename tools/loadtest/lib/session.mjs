/**
 * One student, one sitting — the traffic shape the app produces, in the order
 * the app produces it.
 *
 * The sequence is not invented here; it is the call order a real student
 * generates (see `mobile/lib/features/exam/data/repositories/exam_repository_impl.dart`
 * and `.../proctoring/data/repositories/proctoring_repository_impl.dart`):
 *
 *   1. password sign-in (the session's own JWT from here on),
 *   2. the published-paper list the student's home screen loads,
 *   3. `record_consent` — required before step 4 by `submissions_insert_own_ongoing`,
 *   4. insert the attempt row (`exam_submissions`),
 *   5. `questions_public` for that paper,
 *   6. every 30 s a `merge_submission_answer`, every 15 s a `record_heartbeat`,
 *      and occasionally a `register_violation`,
 *   7. `submit_exam` to close it.
 *
 * Two deliberate choices:
 *
 *   * **No retries.** The app retries (it has an offline queue); a load test
 *     must not, or the number it reports is the retry policy's.
 *   * **`looking_away` by default for the violation type.** It is a weight-0
 *     row in `violation_weights`, so a run cannot disqualify its own attempts
 *     half-way through and start reporting `55000` from `merge_submission_answer`
 *     — a self-inflicted failure that looks exactly like a server fault.
 *
 * The heartbeat default is 15 s, not the 30 s of the answer loop, because the
 * app beats every 15 s and `record_heartbeat` throttles anything inside 8 s.
 * Beating faster is allowed by the script and is reported honestly: rows come
 * back with `outcome = 'throttled'`, which is a server *answer*, not an error.
 */

import { HttpClient } from './http.mjs';

export const DEFAULTS = {
  answerEverySeconds: 30,
  heartbeatEverySeconds: 15,
  violationsPerMinute: 0.5,
  sessionSeconds: 300,
  violationType: 'looking_away',
  questionPageSize: 200,
};

/** The server's throttle window in `record_heartbeat`; beating inside it is throttled. */
export const HEARTBEAT_FLOOR_SECONDS = 8;

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
}

/**
 * Deterministic PRNG (mulberry32), so two runs with the same seed send the same
 * answer choices and violation moments. Reproducibility is what lets a second
 * run answer "did that change help?" instead of "the traffic is different now".
 */
export function createRng(seed = 1) {
  let state = seed >>> 0;
  return function next() {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Probability that a violation happens on one answer tick, from a per-minute rate. */
export function violationProbability(violationsPerMinute, intervalSeconds) {
  if (!Number.isFinite(violationsPerMinute) || violationsPerMinute <= 0) return 0;
  if (!Number.isFinite(intervalSeconds) || intervalSeconds <= 0) return 0;
  // Exponential arrival, so "0.5 per minute" means the same thing whether the
  // loop ticks every 30 s or every 5 s. Capped because a rate above one per tick
  // is a per-tick probability, not an arrival rate.
  return Math.min(1, 1 - Math.exp(-(violationsPerMinute * intervalSeconds) / 60));
}

function fail(outcome, reason) {
  outcome.submitted = false;
  outcome.reason = reason;
  return outcome;
}

/**
 * Runs one complete sitting.
 *
 * @param {object} options
 * @param {HttpClient} options.client      shared HTTP client (one recorder for the run)
 * @param {{ email: string, id: string }} options.student
 * @param {object} options.plan            the seeder's plan.json
 * @param {object} options.settings        DEFAULTS-shaped, overridden by CLI flags
 * @param {string} options.sessionId       for log lines
 * @param {() => number} [options.rng]     deterministic source
 * @param {() => number} [options.now]     monotonic clock in ms, injectable for tests
 */
export async function runStudentSession({
  client,
  student,
  plan,
  settings,
  sessionId,
  rng = Math.random,
  now = () => performance.now(),
}) {
  const config = { ...DEFAULTS, ...settings };
  const outcome = {
    sessionId,
    email: student.email,
    submitted: false,
    reason: null,
    answers: 0,
    heartbeats: 0,
    heartbeatsThrottled: 0,
    heartbeatsDuplicated: 0,
    violations: 0,
    violationsDisqualified: 0,
    questions: 0,
    startedAt: new Date().toISOString(),
  };

  // ---- 1. Sign in -------------------------------------------------------
  const auth = await client.call('auth', '/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: { email: student.email, password: plan.password },
  });
  if (!auth.ok) return fail(outcome, `sign-in ${auth.status}: ${HttpClient.errorMessage(auth)}`);
  const token = auth.data?.access_token;
  if (typeof token !== 'string' || token === '') return fail(outcome, 'sign-in returned no access_token');

  // ---- 2. The paper list -------------------------------------------------
  const examList = await client.call(
    'exams_list',
    '/rest/v1/exams?select=id,title,duration_minutes&is_published=eq.true&order=created_at.desc&limit=20',
    { token },
  );
  if (!examList.ok) return fail(outcome, `exam list ${examList.status}: ${HttpClient.errorMessage(examList)}`);

  const examId = plan.examId
    ?? (Array.isArray(examList.data) ? examList.data[0]?.id : undefined);
  if (typeof examId !== 'string' || examId === '') {
    return fail(outcome, 'no published paper to sit (run the seeder, or publish the staging paper)');
  }
  outcome.examId = examId;

  // ---- 3. Consent --------------------------------------------------------
  const consent = await client.call('consent', '/rest/v1/rpc/record_consent', {
    method: 'POST',
    token,
    body: { p_exam_id: examId, p_version: plan.consentVersion ?? 'loadtest' },
  });
  if (!consent.ok) {
    return fail(outcome, `consent ${consent.status}: ${HttpClient.errorMessage(consent)}`);
  }

  // ---- 4. Start (or resume) the attempt ----------------------------------
  const started = await client.call('start_attempt', '/rest/v1/exam_submissions', {
    method: 'POST',
    token,
    headers: { Prefer: 'return=representation' },
    body: { exam_id: examId, student_id: student.id, status: 'ongoing' },
  });

  let submission;
  if (started.ok) {
    submission = Array.isArray(started.data) ? started.data[0] : started.data;
  } else if (started.status === 409) {
    // `unique (student_id, exam_id)`: a re-run against the same staging project
    // resumes the row a previous run left behind instead of failing outright.
    const existing = await client.call(
      'resume_attempt',
      `/rest/v1/exam_submissions?select=id,status&exam_id=eq.${examId}&student_id=eq.${student.id}`,
      { token },
    );
    if (!existing.ok) return fail(outcome, `resume ${existing.status}: ${HttpClient.errorMessage(existing)}`);
    submission = Array.isArray(existing.data) ? existing.data[0] : existing.data;
  } else {
    // 403 here means the paper is closed, not targeted at this student, or the
    // consent row did not satisfy `student_has_consent`. All three are seeding
    // problems, and all three are worth the server's own words.
    return fail(outcome, `start attempt ${started.status}: ${HttpClient.errorMessage(started)}`);
  }

  if (submission === null || typeof submission?.id !== 'string') {
    return fail(outcome, 'start attempt returned no submission id');
  }
  const submissionId = submission.id;
  outcome.submissionId = submissionId;
  if (submission.status !== undefined && submission.status !== 'ongoing') {
    // Left over from an earlier run: nothing may be written to it, and saying so
    // is better than a session that silently measures nothing but refusals.
    return fail(outcome, `attempt already ${submission.status} (reset the staging project or reseed)`);
  }

  // ---- 5. The paper ------------------------------------------------------
  const questions = await client.call(
    'questions',
    `/rest/v1/questions_public?select=id,question_type,options&exam_id=eq.${examId}&limit=${config.questionPageSize}`,
    { token },
  );
  if (!questions.ok) return fail(outcome, `questions ${questions.status}: ${HttpClient.errorMessage(questions)}`);
  const rows = Array.isArray(questions.data) ? questions.data : [];
  outcome.questions = rows.length;
  if (rows.length === 0) {
    return fail(outcome, 'questions_public returned no rows (is the paper window open and the student targeted?)');
  }

  // ---- 6. The sitting ----------------------------------------------------
  const startMs = now();
  const deadlineMs = startMs + config.sessionSeconds * 1000;
  const answerEveryMs = Math.max(1, config.answerEverySeconds * 1000);
  const beatEveryMs = Math.max(1, config.heartbeatEverySeconds * 1000);
  const violationChance = violationProbability(config.violationsPerMinute, config.answerEverySeconds);

  let nextAnswerAt = startMs + answerEveryMs;
  let nextBeatAt = startMs + beatEveryMs;
  let answerIndex = 0;
  let closed = null;

  while (closed === null) {
    const clock = now();
    if (clock >= deadlineMs) break;

    const due = Math.min(nextAnswerAt, nextBeatAt, deadlineMs);
    if (due > clock) await sleep(due - clock);
    const at = now();
    if (at >= deadlineMs) break;

    if (nextBeatAt <= at) {
      nextBeatAt = at + beatEveryMs;
      const beat = await client.call('heartbeat', '/rest/v1/rpc/record_heartbeat', {
        method: 'POST',
        token,
        body: {
          p_submission_id: submissionId,
          p_camera_ok: true,
          p_monitoring_ok: true,
          p_app_version: 'loadtest',
          p_client_time: new Date().toISOString(),
          p_client_event_id: crypto.randomUUID(),
        },
      });
      if (beat.ok) {
        outcome.heartbeats += 1;
        const row = Array.isArray(beat.data) ? beat.data[0] : beat.data;
        if (row?.outcome === 'throttled') outcome.heartbeatsThrottled += 1;
        if (row?.outcome === 'duplicate') outcome.heartbeatsDuplicated += 1;
      } else if (beat.status === 429) {
        await sleep(500 + rng() * 500);
      } else if (beat.status === 400 || beat.status === 403 || beat.status === 404) {
        // "attempt is submitted/flagged", "no attempt with that id", "belongs to
        // another student": all terminal for this sitting, and all reported in
        // the server's own words rather than as a guess.
        closed = `heartbeat ${beat.status}: ${HttpClient.errorMessage(beat)}`;
      }
    } else if (nextAnswerAt <= at) {
      nextAnswerAt = at + answerEveryMs;
      const question = rows[answerIndex % rows.length];
      answerIndex += 1;
      const answer = await client.call('answer', '/rest/v1/rpc/merge_submission_answer', {
        method: 'POST',
        token,
        body: {
          p_submission_id: submissionId,
          p_question_id: question.id,
          p_selected_option: Math.floor(rng() * 4),
        },
      });
      if (answer.ok) {
        outcome.answers += 1;
      } else if (answer.status === 429) {
        await sleep(500 + rng() * 500);
      } else if (answer.status === 400 || answer.status === 403 || answer.status === 409) {
        closed = `answer ${answer.status}: ${HttpClient.errorMessage(answer)}`;
      }

      if (closed === null && violationChance > 0 && rng() < violationChance) {
        const violation = await client.call('violation', '/rest/v1/rpc/register_violation', {
          method: 'POST',
          token,
          body: {
            p_submission_id: submissionId,
            p_action_type: config.violationType,
            p_client_timestamp: new Date().toISOString(),
            p_client_event_id: crypto.randomUUID(),
          },
        });
        if (violation.ok) {
          outcome.violations += 1;
          const row = Array.isArray(violation.data) ? violation.data[0] : violation.data;
          if (row?.flagged === true || row?.disqualified === true) {
            // Only reachable when the operator chose a hard violation type. The
            // sitting is over from the server's point of view; submitting would
            // answer 55000.
            outcome.violationsDisqualified += 1;
            closed = row.disqualified ? 'disqualified mid-session' : 'flagged for review mid-session';
          }
        }
      }
    }
  }

  if (closed !== null) return fail(outcome, closed);

  // ---- 7. Submit ---------------------------------------------------------
  const submit = await client.call('submit', '/rest/v1/rpc/submit_exam', {
    method: 'POST',
    token,
    body: { p_submission_id: submissionId },
  });
  if (!submit.ok) return fail(outcome, `submit ${submit.status}: ${HttpClient.errorMessage(submit)}`);

  outcome.submitted = true;
  const row = Array.isArray(submit.data) ? submit.data[0] : submit.data;
  outcome.resultStatus = row?.result_status ?? null;
  return outcome;
}
