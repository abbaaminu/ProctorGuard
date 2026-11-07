-- =====================================================================
-- PROCTORGUARD - PROCTORING HEARTBEATS: PROVING THE WATCHER WAS AWAKE
-- Adds `public.proctor_heartbeats`, `exam_submissions.last_heartbeat_at`, the
-- `record_heartbeat()` write path and the `proctoring_coverage[ _for_exam ]()`
-- reporting functions.
--
-- WHY THIS FILE EXISTS
--   Every other piece of evidence this system stores is a *negative*: no
--   `proctoring_logs` rows means no violations were recorded. That silence has two
--   causes the database could not tell apart - the client was running, watching,
--   and saw nothing; or the client was never running at all (closed tab, killed
--   app, blocked script, no network, a JS error before the first frame). An
--   unproctored sitting and a clean sitting looked identical, which is the one gap
--   a proctoring product must not have.
--   A heartbeat is the positive signal: the client says "still here, camera live,
--   monitor up" every 15s, and a hole in that series becomes a fact a human can
--   weigh instead of an assumption nobody examined.
--
-- WHAT IT DOES NOT DO (see README, "Proctoring heartbeats and coverage gaps")
--   * It does not attest to application integrity. A patched or scripted client
--     can send beats while doing nothing, exactly as it can fabricate a violation
--     photo. Play Integrity / App Attest is the step that would change that, and it
--     is future work, not this migration.
--   * It never changes an attempt's status. Coverage produces `risk_flag` for a
--     supervisor to read; a 90-second gap is a dropped network as often as it is
--     anything else, and this file contains no branch that disqualifies, flags or
--     grades anything.
--   * `received_at` (server clock) is the timestamp coverage uses. A beat replayed
--     from the offline queue carries a `client_time` in the past and proves the
--     client is alive *now*, not that it was honest earlier.
--
-- SAFETY
--   Re-runnable: every object is `if not exists` / `create or replace`, the column
--   is added with `add column if not exists`, and no existing row is rewritten.
--   Safe on a live database with attempts in progress - the table starts empty and
--   `last_heartbeat_at` starts null, which reads as "no evidence either way" and is
--   the truth for attempts that predate the client change.
--
-- DEPENDENCIES
--   `supabase/schema.sql` (or `20261104090100_weighted_strikes_and_flagged_review.sql`)
--   must already be applied: this uses `public.owns_exam()`, `public.is_exam_supervisor()`
--   and `auth.uid()`. Applied after those, this migration brings the database to
--   exactly the shape `schema.sql` describes, and the two are kept in step
--   (`mobile/test/schema_contract_test.dart` fails if they drift).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The liveness column the live grid reads
-- ---------------------------------------------------------------------
-- Denormalised on purpose: the supervisor console already streams
-- `exam_submissions`, so "is this client still here?" costs no join per row.
-- NULL means *nothing has ever checked in*, which is not the same statement as
-- "checked in and saw nothing" - and that difference is the whole feature.
alter table public.exam_submissions
  add column if not exists last_heartbeat_at timestamptz;

comment on column public.exam_submissions.last_heartbeat_at is
  'Server time of the last accepted proctoring heartbeat (record_heartbeat()). NULL = the client never reported, which is not evidence of a clean sitting. Written only by record_heartbeat(); never by a client update.';

-- ---------------------------------------------------------------------
-- 2. The series itself
-- ---------------------------------------------------------------------
create table if not exists public.proctor_heartbeats (
  id             uuid primary key default uuid_generate_v4(),
  submission_id  uuid not null references public.exam_submissions(id) on delete cascade,
  received_at    timestamptz not null default now(),
  client_time    timestamptz,
  camera_ok      boolean not null default true,
  monitoring_ok  boolean not null default true,
  app_version    text,
  client_event_id uuid
);

comment on table public.proctor_heartbeats is
  'Proctoring client liveness beats. Answers "was anything watching?", which an empty proctoring_logs feed cannot. Proves a client claimed to be running - never that it was doing its job (no application attestation).';
comment on column public.proctor_heartbeats.received_at is
  'Server clock at insert. The only timestamp coverage trusts: a beat replayed from the offline queue has a client_time in the past.';
comment on column public.proctor_heartbeats.camera_ok is
  'Whether the camera had a live track when the beat was produced. false is the "monitor running but blind" case an empty log feed used to hide.';
comment on column public.proctor_heartbeats.monitoring_ok is
  'Whether the monitor as a whole (detector loop, foreground app) was up. false covers backgrounded, paused or ended early.';
comment on column public.proctor_heartbeats.client_event_id is
  'Idempotency key for the offline queue: record_heartbeat() stores one row per beat however many times it is replayed.';

-- One row per queued beat, however many times the retry replays it.
create unique index if not exists idx_heartbeats_client_event_id
  on public.proctor_heartbeats(client_event_id)
  where client_event_id is not null;

-- The coverage functions walk one attempt's beats in time order; the retention
-- job prunes by age and needs the other index.
create index if not exists idx_heartbeats_submission_received
  on public.proctor_heartbeats(submission_id, received_at);
create index if not exists idx_heartbeats_received_at
  on public.proctor_heartbeats(received_at);


-- ---------------------------------------------------------------------
-- 3. Row level security: readable by the same three audiences as the evidence
-- ---------------------------------------------------------------------
alter table public.proctor_heartbeats enable row level security;

drop policy if exists "heartbeats_select_own_or_supervisor" on public.proctor_heartbeats;

-- The student whose attempt it is, the lecturer who wrote the paper
-- (`owns_exam()`), and the intervention tier. Anything broader turns a liveness
-- table into a presence tracker for the whole institution.
create policy "heartbeats_select_own_or_supervisor"
  on public.proctor_heartbeats for select
  to authenticated
  using (
    exists (
      select 1 from public.exam_submissions s
      where s.id = submission_id
        and (s.student_id = auth.uid() or public.owns_exam(s.exam_id))
    )
    or public.is_exam_supervisor()
  );

-- Deliberately NO insert / update / delete policy, the shape `proctoring_logs`
-- already uses. `record_heartbeat()` is SECURITY DEFINER and re-checks ownership
-- and status; letting clients write this table directly would hand a tampered
-- client the one thing the table exists to make hard - a tidy series of beats it
-- never sent.
grant select on public.proctor_heartbeats to authenticated;
revoke all on public.proctor_heartbeats from anon;

-- ---------------------------------------------------------------------
-- 4. The write path: record_heartbeat()
-- ---------------------------------------------------------------------
-- The complement of `register_violation()`: that RPC records what the client
-- *saw*, this one records that the client was *there to see it*.
--
--   * ownership and status are re-checked here, never trusted from the request;
--   * one row per beat, deduplicated on `client_event_id` so the offline queue can
--     replay a batch without inflating the series;
--   * a beat inside the rate-limit window is answered (`throttled`), not raised -
--     the client beats on a timer and must not special-case "too early";
--   * the same transaction stamps `exam_submissions.last_heartbeat_at`, refreshed
--     for `recorded`, `duplicate` and `throttled` alike: all three mean the client
--     is alive *now*, and only the insert is skipped.
create or replace function public.record_heartbeat(
  p_submission_id   uuid,
  p_camera_ok       boolean     default true,
  p_monitoring_ok   boolean     default true,
  p_app_version     text        default null,
  p_client_time     timestamptz default null,
  p_client_event_id uuid        default null
)
returns table (
  outcome     text,
  recorded_at timestamptz,
  beat_count  int
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- The client beats every 15s (mobile ProctoringHeartbeatService). The window is
  -- deliberately shorter so jitter never throttles an honest client, while a
  -- script hammering the RPC still cannot write a thousand rows a second.
  c_min_interval constant interval := interval '8 seconds';
  v_now   timestamptz := now();
  v_sub   public.exam_submissions;
  v_last  timestamptz;
  v_first timestamptz;
  v_count int;
begin
  if auth.uid() is null then
    raise exception 'record_heartbeat: sign in before reporting a heartbeat'
      using errcode = '28000';
  end if;

  -- `for update` serialises two beats that arrive together, so the rate-limit read
  -- below cannot be raced into writing two rows inside one window.
  select * into v_sub
  from public.exam_submissions s
  where s.id = p_submission_id
  for update;

  if not found then
    raise exception 'record_heartbeat: no attempt with id %', p_submission_id
      using errcode = 'P0002';
  end if;

  if v_sub.student_id <> auth.uid() then
    raise exception 'record_heartbeat: attempt % belongs to another student', p_submission_id
      using errcode = '42501';
  end if;

  -- A closed attempt cannot report for duty: accepting these would let an ended or
  -- flagged sitting keep its coverage looking healthy after the fact.
  if v_sub.status <> 'ongoing' then
    raise exception 'record_heartbeat: attempt % is %, not ongoing', p_submission_id, v_sub.status
      using errcode = '22023';
  end if;

  select count(*) into v_count
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  -- Idempotency first: a replay of a stored beat is not "too early", it is done.
  if p_client_event_id is not null then
    select h.received_at into v_last
    from public.proctor_heartbeats h
    where h.client_event_id = p_client_event_id;

    if v_last is not null then
      update public.exam_submissions
         set last_heartbeat_at = v_now
       where id = p_submission_id;
      return query select 'duplicate'::text, v_last, v_count;
      return;
    end if;
  end if;

  select max(h.received_at) into v_last
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  if v_last is not null and v_last > v_now - c_min_interval then
    update public.exam_submissions
       set last_heartbeat_at = v_now
     where id = p_submission_id;
    return query select 'throttled'::text, v_last, v_count;
    return;
  end if;

  insert into public.proctor_heartbeats (
    submission_id, received_at, client_time, camera_ok, monitoring_ok,
    app_version, client_event_id
  )
  values (
    p_submission_id,
    v_now,
    p_client_time,
    coalesce(p_camera_ok, true),
    coalesce(p_monitoring_ok, true),
    p_app_version,
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing
  returning received_at into v_first;

  update public.exam_submissions
     set last_heartbeat_at = v_now
   where id = p_submission_id;

  -- The insert can be swallowed by the unique index if two deliveries of the same
  -- beat raced; either way the attempt is alive and the series holds one row.
  -- The cast is not decoration: `count(*)` is bigint, `beat_count` is int, and a
  -- RETURN QUERY is checked against the declared row type exactly (unlike
  -- `select ... into`, which applies an assignment cast). Without it the RPC
  -- fails at run time with "Returned type bigint does not match expected type
  -- integer in column 3".
  return query select
    case when v_first is null then 'duplicate' else 'recorded' end,
    coalesce(v_first, v_now),
    (select count(*)::integer from public.proctor_heartbeats h
      where h.submission_id = p_submission_id);
end;
$$;
revoke execute on function public.record_heartbeat(uuid, boolean, boolean, text, timestamptz, uuid) from public, anon;
grant execute on function public.record_heartbeat(uuid, boolean, boolean, text, timestamptz, uuid) to authenticated, service_role;

comment on function public.record_heartbeat(uuid, boolean, boolean, text, timestamptz, uuid) is
  'The single write path for proctoring heartbeats: ownership- and status-checked, idempotent per client_event_id, rate-limited to one stored beat per 8s, and the only writer of exam_submissions.last_heartbeat_at. Proves a client was running, never that it was doing its job.';

-- ---------------------------------------------------------------------
-- 5. The reporting path: proctoring_coverage()
-- ---------------------------------------------------------------------
-- "Was this attempt actually watched?" answered with numbers a supervisor can
-- check. `risk_flag` means *look at this*, never *punish this*:
--
--   beats = 0                  nothing ever checked in
--   longest_gap_seconds > 60   proctoring stopped for a while
--   camera_down_beats > 0      the monitor was up with no camera behind it
--   coverage_ratio < 0.5       most of the expected beats never arrived
--
-- The 90s grace exists because every attempt blinks at the start (boot, camera
-- permission, detector model); flagging that would make the report noise. No
-- branch touches `exam_submissions.status`.
create or replace function public.proctoring_coverage(p_submission_id uuid)
returns table (
  submission_id         uuid,
  student_id            uuid,
  exam_id               uuid,
  status                text,
  started_at            timestamptz,
  ended_at              timestamptz,
  beats                 int,
  expected_beats        int,
  coverage_ratio        numeric,
  first_beat_at         timestamptz,
  last_beat_at          timestamptz,
  longest_gap_seconds   int,
  silent_seconds        int,
  camera_down_beats     int,
  monitoring_down_beats int,
  risk_flag             boolean,
  reason                text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c_expected_interval constant numeric  := 15;   -- the client's cadence
  c_gap_threshold     constant int      := 60;   -- "worth a human's time"
  c_grace             constant interval := interval '90 seconds';

  v_sub      public.exam_submissions;
  v_now      timestamptz := now();
  v_end      timestamptz;
  v_window   numeric;
  v_beats    int;
  v_expected int;
  v_ratio    numeric;
  v_first    timestamptz;
  v_last     timestamptz;
  v_gap      int;
  v_head     int;
  v_tail     int;
  v_camera   int;
  v_monitor  int;
  v_silent   int;
  v_flag     boolean := false;
  v_reasons  text[]  := '{}';
begin
  select * into v_sub
  from public.exam_submissions s
  where s.id = p_submission_id;

  if not found then
    raise exception 'proctoring_coverage: no attempt with id %', p_submission_id
      using errcode = 'P0002';
  end if;

  -- SECURITY DEFINER, so the rule the RLS policy on `proctor_heartbeats` would have
  -- applied has to be spelled out here: same three audiences, same order.
  if not (
    v_sub.student_id = auth.uid()
    or public.owns_exam(v_sub.exam_id)
    or public.is_exam_supervisor()
  ) then
    raise exception 'proctoring_coverage: attempt % is not yours to read', p_submission_id
      using errcode = '42501';
  end if;

  v_end := coalesce(v_sub.submitted_at, v_now);

  select count(*),
         min(h.received_at),
         max(h.received_at),
         count(*) filter (where not h.camera_ok),
         count(*) filter (where not h.monitoring_ok)
    into v_beats, v_first, v_last, v_camera, v_monitor
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  -- Longest silence between stored beats, then the two ends: the head gap (attempt
  -- started, nothing checked in yet) and the tail (client went quiet before the
  -- attempt closed). All three are one fact - a stretch with no evidence of a
  -- running monitor - so the report keeps the largest.
  select coalesce(max(g.seconds), 0) into v_gap
  from (
    select extract(epoch from (h.received_at
             - lag(h.received_at) over (order by h.received_at)))::int as seconds
    from public.proctor_heartbeats h
    where h.submission_id = p_submission_id
  ) g
  where g.seconds is not null;

  v_head := greatest(0, extract(epoch from (coalesce(v_first, v_end) - v_sub.started_at))::int);
  v_tail := greatest(0, extract(epoch from (v_end - coalesce(v_last, v_sub.started_at)))::int);
  v_gap  := greatest(v_gap, v_head, v_tail);

  v_window   := greatest(0, extract(epoch from (v_end - v_sub.started_at)));
  v_expected := floor(v_window / c_expected_interval)::int + 1;
  v_ratio    := round(v_beats::numeric / greatest(v_expected, 1), 3);

  -- Silence now only means something while the attempt is live; a closed attempt's
  -- silence is already in the tail gap above.
  v_silent := case
    when v_sub.status = 'ongoing'
      then greatest(0, extract(epoch from (v_now - coalesce(v_last, v_sub.started_at)))::int)
    else 0
  end;

  if v_sub.status = 'ongoing' and v_now - v_sub.started_at < c_grace then
    -- Too early to say anything: a row is still returned (a console can show "0
    -- beats so far") but no gap is claimed.
    v_reasons := array_append(v_reasons, 'attempt just started - too early to judge');
  else
    if v_beats = 0 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        'the proctoring client never checked in - no evidence of monitoring for this attempt');
    end if;
    if v_gap > c_gap_threshold then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('proctoring went quiet for %ss (longest, including the ends)', v_gap));
    end if;
    if v_camera > 0 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('the camera was not streaming on %s heartbeat(s)', v_camera));
    end if;
    if v_ratio < 0.5 then
      v_flag := true;
      v_reasons := array_append(v_reasons,
        format('only %s of ~%s expected heartbeats arrived', v_beats, v_expected));
    end if;
    if v_monitor > 0 and v_camera = 0 then
      v_reasons := array_append(v_reasons,
        format('%s heartbeat(s) reported monitoring inactive', v_monitor));
    end if;
    if v_flag then
      v_reasons := array_append(v_reasons,
        'flag for human review only - a gap can be a dropped network or a broken webcam; coverage never disqualifies an attempt');
    elsif v_reasons = '{}' then
      v_reasons := array_append(v_reasons,
        format('%s heartbeats, largest gap %ss - proctoring was running throughout', v_beats, v_gap));
    end if;
  end if;

  return query select
    v_sub.id, v_sub.student_id, v_sub.exam_id, v_sub.status,
    v_sub.started_at,
    case when v_sub.submitted_at is null then null else v_end end,
    v_beats, v_expected, v_ratio, v_first, v_last,
    v_gap, v_silent, v_camera, v_monitor, v_flag,
    array_to_string(v_reasons, '; ');
end;
$$;
revoke execute on function public.proctoring_coverage(uuid) from public, anon;
grant execute on function public.proctoring_coverage(uuid) to authenticated, service_role;

comment on function public.proctoring_coverage(uuid) is
  'Per-attempt heartbeat coverage: beats received vs expected, longest gap, silent time and camera-down beats, plus a risk_flag that marks the attempt for human review. Never changes exam_submissions.status - a gap can be a network drop, so coverage informs, it does not disqualify.';

-- Every attempt in one sitting, for the supervisor who is about to decide
-- something: one call, no joins. Visibility is filtered before the lateral call so
-- a student asking about their exam gets their own row instead of an exception for
-- a classmate's.
create or replace function public.proctoring_coverage_for_exam(p_exam_id uuid)
returns setof record
language sql
security invoker
set search_path = public, pg_temp
as $$
  select c.*
  from public.exam_submissions s
  cross join lateral public.proctoring_coverage(s.id) c
  where s.exam_id = p_exam_id
    and (
      s.student_id = auth.uid()
      or public.owns_exam(s.exam_id)
      or public.is_exam_supervisor()
    )
  order by c.risk_flag desc, c.last_beat_at nulls first;
$$;
revoke execute on function public.proctoring_coverage_for_exam(uuid) from public, anon;
grant execute on function public.proctoring_coverage_for_exam(uuid) to authenticated, service_role;

comment on function public.proctoring_coverage_for_exam(uuid) is
  'proctoring_coverage() for every attempt in one exam, risk-flagged rows first. Returns setof record, so callers must name the columns: select * from proctoring_coverage_for_exam(...) as c(submission_id uuid, student_id uuid, exam_id uuid, status text, started_at timestamptz, ended_at timestamptz, beats int, expected_beats int, coverage_ratio numeric, first_beat_at timestamptz, last_beat_at timestamptz, longest_gap_seconds int, silent_seconds int, camera_down_beats int, monitoring_down_beats int, risk_flag boolean, reason text).';

-- ---------------------------------------------------------------------
-- 6. Retention
-- ---------------------------------------------------------------------
-- ~240 rows per student per hour of sitting. `retention_policy.sql` carries the
-- `proctor_heartbeats` policy and `purge_expired_proctor_heartbeats()`; run it
-- after this file if it has not been applied yet, or the table grows forever.
-- Coverage keeps working on what survives: a pruned series reads as "we no longer
-- have the beats", not as an attribution.
