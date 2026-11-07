# Staging load test

Runs N complete *student sittings* against a **staging** Supabase project and
prints what the server did: p50/p95/p99 latency, error rate, and counts of 429s
and 5xx per operation.

It exists to answer one question before a real cohort asks it — *does the project
still hold up when 500 students start at once?* — and to answer it without
touching production.

Two rules it keeps:

* **It will not run against production.** Three independent facts are checked
  before the first request: the URL's project ref, the `ref` claim inside the API
  key, and the production ref recorded by `supabase link`
  (`supabase/.temp/project-ref`). Any disagreement is exit code 2 and no traffic.
  There is deliberately no `--force`.
* **No app code is touched.** Everything here is a separate Node script that
  speaks to Supabase over the same HTTP API the app does.

## Layout

| File | What it is |
| --- | --- |
| `load.mjs` | the load test — a ramp of concurrent sittings, then the report |
| `seed/seed.mjs` | creates the student accounts and the paper the run sits |
| `lib/guard.mjs` | the production guard (used by both scripts) |
| `lib/http.mjs` | the HTTP client: timeouts, no retries, status as a value |
| `lib/session.mjs` | one student's sitting, in the app's own call order |
| `lib/metrics.mjs` | the recorder: samples, percentiles, 429/5xx counters |
| `lib/report.mjs` | the text report and the JSON one, plus thresholds |
| `lib/stages.mjs` | `"50:2m,200:3m,500:3m"` → a ramp schedule |
| `stub/fake_supabase.mjs` | a fake project, so the scripts can be tested locally |
| `test/*.test.mjs` | `node:test` suite over all of the above |

No dependencies: Node ≥ 18 (`fetch`, `crypto.randomUUID`,
`AbortSignal.timeout`), nothing to install.

## Quick start

Environment variables are read by both scripts; flags win over env. On Windows
PowerShell set them with `$env:LOADTEST_URL = '...'` per line.

```sh
# 1. once per staging project (needs the service_role key)
export LOADTEST_URL=https://<staging-ref>.supabase.co
export LOADTEST_SERVICE_KEY=<service_role key>
node tools/loadtest/seed/seed.mjs --count 500

# 2. check what a run would do (needs only the anon key)
export LOADTEST_ANON_KEY=<anon key>
node tools/loadtest/load.mjs --plan plan.json --dry-run

# 3. run it, smallest stage first
node tools/loadtest/load.mjs --plan plan.json \
  --stages "50:2m" --p95-ms 1500 --error-rate 0.01 --out report.json
```

`--dry-run` is the way to see the whole plan — target, plan size, ramp, the
traffic each sitting sends, and how long the run will take — without sending
anything. It is worth reading once before a long run.

## Step 1: seed

```sh
node tools/loadtest/seed/seed.mjs --help
```

The seeder creates, against the staging project:

* **N auth accounts**, `<prefix>-<tag>-<n>@<domain>`, pre-confirmed (no inbox),
  each with its `profiles` row (`role = 'student'`, and the `faculty`/
  `department`/`level` labels when `--faculty`/`--department`/`--level` are
  given);
* **a supervisor** `<prefix>-<tag>-teacher@<domain>`, because `exams.created_by`
  is `not null` and a paper needs an owner — the seeder makes its own rather than
  asking you to click through the dashboard first;
* **a published paper** titled `[loadtest] <--title>` with `--questions`
  multiple-choice questions, no scheduling window (`starts_at`/`ends_at` null, so
  the run measures the server and not the clock);
* **the exception list** (`exam_allowed_students`) for every seeded account, so
  the paper is reachable whatever labels the paper was aimed at;
* **`plan.json`**, which is all `load.mjs` needs:

```json
{
  "generatedAt": "2026-01-01T00:00:00.000Z",
  "url": "https://<staging-ref>.supabase.co",
  "projectRef": "<staging-ref>",
  "examId": "…",
  "consentVersion": "…",
  "password": "Loadtest!2026",
  "students": [{ "id": "…", "email": "loadtest-staging-1@proctorguard.test" }]
}
```

Run it twice and nothing doubles: existing accounts are found and their password
is re-set (so `plan.json` is always the truth), and the paper is reused.
`--reset` deletes this seeder's paper and accounts first — their attempts,
answers and violations cascade — which is how a run starts from zero.

`consentVersion` is **read from the project**, not assumed: the acceptance has to
match `current_proctoring_consent_version()` or every attempt is refused with a
403 that looks like a server fault.

**Why the seeder takes the service key and the load test does not.** Creating
accounts and publishing a paper is privileged setup. A load generator holding
`service_role` could answer all 500 sessions without ever touching RLS — and RLS
is half of what a run is measuring. So the key stays in the seeder, and the run
uses the anon key, like a student.

## Step 2: run

```sh
node tools/loadtest/load.mjs --help
```

The two flags that matter:

* `--stages "50:2m,200:3m,500:3m"` — ramp to 50 over two minutes, then to 200
  over three, then to 500. New sittings only start while the ramp runs; after
  that the run drains, because a sitting in progress is still a student in an
  exam and cutting it off would delete the `submit_exam` leg.
* `--plan plan.json` — one student, one sitting. A student id is used once, so
  the plan's size is the hard ceiling on how many sittings a run can start.

Each sitting is the app's own sequence: sign in → list published papers →
`record_consent` → insert the attempt → `questions_public` → then every 30 s a
`merge_submission_answer`, every 15 s a `record_heartbeat`, and occasionally a
`register_violation` → `submit_exam`. Nothing is retried: a load test that
retries measures the retry policy, not the server.

### Options

| Flag | Env | Default | Meaning |
| --- | --- | --- | --- |
| `--url` | `LOADTEST_URL` | — | staging project URL |
| `--anon-key` | `LOADTEST_ANON_KEY` | — | the same key the app ships with |
| `--plan` | `LOADTEST_PLAN` | `plan.json` | output of the seeder |
| `--stages` | `LOADTEST_STAGES` | `50:2m,200:3m,500:3m` | ramp schedule |
| `--answer-every` | | `30` | seconds between answers, per student |
| `--heartbeat-every` | | `15` | seconds between heartbeats (see throttling below) |
| `--violations-per-minute` | | `0.5` | per student; `0` turns violations off |
| `--violation-type` | | `looking_away` | a weight-0 type, so a run cannot disqualify itself |
| `--session-seconds` | | `300` | how long one sitting lasts before it submits |
| `--timeout-ms` | | `20000` | per-request timeout; a timeout is counted as an error |
| `--seed` | | `1` | PRNG seed: same seed, same answers and violation moments |
| `--p95-ms`, `--error-rate`, `--max-5xx`, `--max-429` | | none | thresholds (see exit codes) |
| `--out` | | — | write the JSON report |
| `--dry-run`, `--quiet`, `--help` | | | |

`LOADTEST_PROD_REF` supplies the production ref when
`supabase/.temp/project-ref` is absent (a checkout that has never run
`supabase link`). `LOADTEST_ALLOW_FOREIGN_HOST=1` is for a self-hosted staging
stack — nothing here can tell that apart from production, so it has to be said
out loud.

## Reading the report

```
requests      12043   errors 31 (0.26%)
latency       p50 84ms   p95 401ms   p99 1120ms
```

then a table per operation (`auth`, `exams_list`, `consent`, `start_attempt`,
`questions`, `answer`, `heartbeat`, `violation`, `submit`), then every status
code seen, then the first few raw failures, then the thresholds.

What to look for, in order:

1. **Which operation is slow.** `auth` climbing is GoTrue (rate limits, password
   hashing); `start_attempt` climbing is Postgres (row locks, the attempt
   uniqueness check); `answer` climbing is the write path.
2. **429s.** Rate limiting. Counted as an error on purpose: it is the first sign
   the ramp went past what the project allows, and it is answered *before* the
   project breaks.
3. **5xx.** Read the project's logs for the same window before believing the
   latency numbers — a 500 that returns in 20 ms is still a 500.
4. **Failures with bodies.** PostgREST's own message is printed (`permission
   denied for table …`, `55000 attempt already submitted`, …), which is usually
   enough to name the cause.

### `throttled` is not an error

`record_heartbeat` ignores a beat that arrives inside its throttle window and
answers `outcome = "throttled"`. That is a working server declining to write a
duplicate row — the report counts it separately and does not call it an error.
The default 15 s cadence is outside the window; only a `--heartbeat-every` below
8 s produces throttles (`--dry-run` says so too).

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | the run finished and every threshold passed |
| `1` | a threshold failed, or the run could not finish and the numbers are partial |
| `2` | bad configuration, or the production guard refused — nothing was sent |

Thresholds are opt-in: an absent flag is not a threshold of zero. A CI job is
`--p95-ms 1500 --error-rate 0.01 --max-5xx 0`.

## Supabase limits, and which ones bite first

Free-plan numbers are as published at the time of writing; the dashboard's usage
page is the source of truth, and a paid project has different ones.

| Limit (free plan) | Where it bites | What a run shows |
| --- | --- | --- |
| Database/PostgREST connection pool (a few dozen on the smallest compute) | `start_attempt`, `answer`, `submit` | p95 climbing in steps, then 5xx; `--timeout-ms` errors if the pool stops answering at all |
| Egress, 5 GB/month | everything — every response counts | a 500-session run moves a few hundred MB; several a day will exhaust it |
| Realtime, ~200 concurrent connections | not this harness (it uses PostgREST, not subscriptions) | — |
| Database size, 500 MB | answers, heartbeats and violations grow forever | `--reset` between runs, and delete the seeded paper afterwards |
| MAU, 50 000 | 500 seeded accounts are 500 MAU | keep `--count` to what the stage needs |
| Auth rate limits | `auth` | 429s at the start of a ramp; the per-op table shows it |

A free project also pauses after about a week of inactivity — wake it (open the
dashboard) before a run, or every request fails as a transport error.

## Cleaning up

```sh
# delete the seeded paper, accounts, attempts, answers and violations
node tools/loadtest/seed/seed.mjs --count 500 --reset
```

`--reset` removes what this seeder made, matched by email prefix and the
`[loadtest]` title marker. Anything else on the project is left alone — which is
the reason the marker exists.

## Tests

```sh
node --test 'tools/loadtest/test/*.test.mjs'
```

The suite starts `stub/fake_supabase.mjs` on an ephemeral port and runs the real
scripts against it: a complete sitting, injected 429s and 5xx, a threshold miss
exiting 1, the guard exiting 2, the seeder creating a cohort and re-running as a
no-op. No network, no credentials, no project.
