-- =====================================================================
-- PROCTORGUARD - RETENTION POLICY FOR public.proctoring_logs
--
-- One incident row per violation, per attempt, forever. `proctoring_logs` is
-- the table that grows without bound in a live project: a class of 200 sitting
-- three exams a term writes thousands of rows a week, and the rows are only
-- ever *read* by the monitor during the sitting and by an appeal afterwards.
-- This migration gives them a lifetime, and a pg_cron job that enforces it.
--
-- It also enforces the lifetime of `public.proctor_heartbeats`
-- (`20261105090000_proctor_heartbeats.sql`), the liveness beats behind coverage
-- reporting. That table is the one that *really* grows without bound - a beat
-- every 15 seconds is ~240 rows per student per hour of sitting, an order of
-- magnitude more than the incident log - and it is worthless once the sitting is
-- over and the coverage question has been answered. Same mechanism, same guards,
-- separate function and schedule so either window can be changed alone.
--
-- WHAT IS CONFIGURABLE
--   `public.retention_policies` holds the window (`retention_days`) per table.
--   It is seeded with 30 days for proctoring_logs and is the single place to
--   change it - no function body has a magic number in it:
--
--     update public.retention_policies
--        set retention_days = 14, updated_at = now()
--      where table_name = 'proctoring_logs';
--
--   The job reads the row on every run, so a change takes effect the next night
--   without a deploy. Setting `enabled = false` suspends deletion while keeping
--   the schedule in place.
--
-- WHY A CLOSED-ATTEMPT GUARD
--   `register_violation()` (in `schema.sql`) counts a submission's rows to
--   decide the third strike. Deleting rows out from under an *ongoing* attempt
--   would silently raise the number of strikes a student can collect, so the
--   purge only touches rows whose submission is no longer `ongoing`. An
--   abandoned attempt left open for months therefore keeps its evidence; that
--   is the safe failure direction for a proctoring system.
--
-- WHAT THIS FILE DOES NOT DO
--   * It does not delete from `storage.objects`, and it never will. Removing rows
--     there through SQL leaves the underlying object in S3, which is worse than
--     leaving the row: the snapshot still exists and nothing points at it any
--     more. The stills got their own answer later -
--     `20261106090100_snapshot_retention.sql` (the `proctor_snapshots` window and
--     `public.purge_expired_snapshots()`) and the `purge-snapshots` Edge Function,
--     which goes through the Storage API so the file goes with the row. The reset
--     path (`DashboardRepositoryImpl.resetSubmission()`) still purges the objects
--     it owns. Here, the `snapshot_url` path simply stops being reachable when its
--     row is purged, and that is the property that matters for the student's
--     privacy.
--   * It does not touch `session_reset_logs`. That is an audit trail of staff
--     actions, not telemetry; retention for it is a policy decision this file
--     leaves alone.
--   * It does not require pg_cron to be *enabled*. The function is created
--     either way, so a project without pg_cron can call it from an external
--     scheduler (or by hand) until the extension is turned on in
--     Dashboard -> Database -> Extensions.
--
-- SAFETY
--   * Safe to re-run: `create table if not exists`, `insert ... on conflict do
--     nothing`, `create or replace function`, and the job is unscheduled before
--     it is scheduled again.
--   * Additive only: no existing table, policy or function is modified.
--   * Verify with:
--       select * from public.retention_policies;
--       select public.purge_expired_proctoring_logs(p_dry_run => true);
--       select public.purge_expired_proctor_heartbeats(p_dry_run => true);
--     Each dry run reports how many rows the next real run would delete, and
--     changes nothing.
--   * Apply after `schema.sql` (or the migrations that precede it): the function
--     and its index use `exam_submissions.status`.
-- =====================================================================
-- RE-RUNNING THIS FILE, AND WHAT IT CANNOT UNDO
--   Unlike the other historical files (`private_proctor_snapshots.sql`,
--   `staff_attempt_resets.sql`, `secure_exam_access_and_deadlines.sql`), this one
--   creates no RLS policy at all: it owns a fixed, short list of objects and
--   nothing else - `public.retention_policies`, `public.purge_expired_proctoring_logs(boolean)`,
--   `public.purge_expired_proctor_heartbeats(boolean)` and their two cron jobs. The
--   hardening pass in `supabase/migrations/2026110309*.sql` replaces none of them,
--   so re-running this file cannot put a narrowed policy back.
--   Two things to know before doing it anyway:
--     * the seed is `on conflict (table_name) do nothing`, so a re-run leaves an
--       edited `retention_days` exactly as it is - it does not reset it to 30;
--     * `create or replace function` does overwrite the body, so if a later
--       migration ever replaces the purge, check that ordering first.
--   The files that DO reinstate replaced storage policies are named at the bottom
--   of `20261103090800_snapshot_purge_not_live_attempt.sql`.
-- ---------------------------------------------------------------------
-- 1. The window
-- ---------------------------------------------------------------------
create table if not exists public.retention_policies (
  -- The table this policy applies to. Named rather than implied so a second
  -- policy can be added without changing the function's shape.
  table_name     text primary key,
  -- Days a row is kept after it was written. The upper bound is a decade: a
  -- typo of `30000` is a policy that never deletes anything.
  retention_days integer not null
                   check (retention_days between 1 and 3650),
  -- Lets an operator suspend deletion without losing the schedule or the value.
  enabled        boolean not null default true,
  updated_at     timestamptz not null default now()
);

comment on table public.retention_policies is
  'How long rows in a public table are kept. Read by '
  'public.purge_expired_proctoring_logs(); change retention_days here rather '
  'than editing the function or the cron job.';

comment on column public.retention_policies.retention_days is
  'Rows older than this many days are deleted by the retention job.';

-- Seeded, not assumed: the function returns 0 when there is no enabled row.
insert into public.retention_policies (table_name, retention_days)
values ('proctoring_logs', 30)
on conflict (table_name) do nothing;

-- The heartbeat series. Seeded at the same 30 days as the evidence it explains -
-- a coverage finding is only useful for as long as somebody can still appeal the
-- sitting - and it can be shortened on its own without touching the incident log:
--
--     update public.retention_policies
--        set retention_days = 7, updated_at = now()
--      where table_name = 'proctor_heartbeats';
--
-- Nothing in `proctoring_coverage()` assumes the rows are still there: a pruned
-- series reports the beats it still has, and the attempts that predate the client
-- change report none at all. Both read as "no evidence", never as "clean".
insert into public.retention_policies (table_name, retention_days)
values ('proctor_heartbeats', 30)
on conflict (table_name) do nothing;


-- The app has no business reading or writing a retention window, and nothing
-- but the job owner needs to. RLS with no policy denies every API caller;
-- `postgres` (the SQL editor) and `service_role` bypass it, which is where this
-- is meant to be changed.
alter table public.retention_policies enable row level security;

revoke all on table public.retention_policies from anon, authenticated;
grant select, insert, update, delete on table public.retention_policies
  to service_role;

-- ---------------------------------------------------------------------
-- 2. The purge
-- ---------------------------------------------------------------------
-- Returns the number of rows deleted (or, with `p_dry_run`, the number that
-- *would* be deleted), so the caller - and the cron run's output - can see what
-- happened instead of guessing.
--
-- SECURITY DEFINER because the job runs as its owner and must be able to delete
-- rows RLS would otherwise hide; execute is revoked from every API role below,
-- so this is not an RPC a student can call to erase a classmate's evidence.
create or replace function public.purge_expired_proctoring_logs(
  p_dry_run boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days    integer;
  v_deleted bigint := 0;
begin
  select rp.retention_days
    into v_days
    from public.retention_policies rp
   where rp.table_name = 'proctoring_logs'
     and rp.enabled
   limit 1;

  if v_days is null then
    raise notice
      'retention: no enabled policy for proctoring_logs, nothing purged';
    return 0;
  end if;

  if p_dry_run then
    select count(*)
      into v_deleted
      from public.proctoring_logs l
      join public.exam_submissions s on s.id = l.submission_id
     where l.timestamp < now() - make_interval(days => v_days)
       and s.status <> 'ongoing';

    raise notice
      'retention: would purge % proctoring_logs row(s) older than % day(s)',
      v_deleted, v_days;
    return v_deleted;
  end if;

  delete from public.proctoring_logs l
   using public.exam_submissions s
   where s.id = l.submission_id
     and l.timestamp < now() - make_interval(days => v_days)
     and s.status <> 'ongoing';

  get diagnostics v_deleted = row_count;

  raise notice
    'retention: purged % proctoring_logs row(s) older than % day(s)',
    v_deleted, v_days;
  return v_deleted;
end;
$$;

comment on function public.purge_expired_proctoring_logs(boolean) is
  'Deletes proctoring_logs rows older than the window in '
  'public.retention_policies, except rows belonging to an attempt that is still '
  'ongoing. p_dry_run => true only counts them. Returns the row count.';

revoke all on function public.purge_expired_proctoring_logs(boolean)
  from public, anon, authenticated;
grant execute on function public.purge_expired_proctoring_logs(boolean)
  to service_role;

-- ---------------------------------------------------------------------
-- 2b. The heartbeat purge
-- ---------------------------------------------------------------------
-- Same shape as the incident purge above, for the same reasons and with the same
-- guard: a beat belonging to an attempt that is still `ongoing` is never deleted.
-- Deleting those would punch holes in a coverage report that is still being
-- written, and the coverage functions would then report a gap the client never
-- caused - the worst kind of false positive in this system.
--
-- `received_at` is the column this prunes on, not `client_time`: the server clock
-- is the only timestamp a replayed offline beat cannot move backwards.
create or replace function public.purge_expired_proctor_heartbeats(
  p_dry_run boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_days    integer;
  v_deleted bigint := 0;
begin
  select rp.retention_days
    into v_days
    from public.retention_policies rp
   where rp.table_name = 'proctor_heartbeats'
     and rp.enabled
   limit 1;

  if v_days is null then
    raise notice
      'retention: no enabled policy for proctor_heartbeats, nothing purged';
    return 0;
  end if;

  if p_dry_run then
    select count(*)
      into v_deleted
      from public.proctor_heartbeats h
      join public.exam_submissions s on s.id = h.submission_id
     where h.received_at < now() - make_interval(days => v_days)
       and s.status <> 'ongoing';

    raise notice
      'retention: would purge % proctor_heartbeats row(s) older than % day(s)',
      v_deleted, v_days;
    return v_deleted;
  end if;

  delete from public.proctor_heartbeats h
   using public.exam_submissions s
   where s.id = h.submission_id
     and h.received_at < now() - make_interval(days => v_days)
     and s.status <> 'ongoing';

  get diagnostics v_deleted = row_count;

  raise notice
    'retention: purged % proctor_heartbeats row(s) older than % day(s)',
    v_deleted, v_days;
  return v_deleted;
end;
$$;

comment on function public.purge_expired_proctor_heartbeats(boolean) is
  'Deletes proctor_heartbeats rows older than the window in '
  'public.retention_policies, except rows belonging to an attempt that is still '
  'ongoing. p_dry_run => true only counts them. Returns the row count.';

revoke all on function public.purge_expired_proctor_heartbeats(boolean)
  from public, anon, authenticated;
grant execute on function public.purge_expired_proctor_heartbeats(boolean)
  to service_role;


-- ---------------------------------------------------------------------
-- 3. The schedule
-- ---------------------------------------------------------------------
-- Supabase ships pg_cron as an available extension, not an installed one, and a
-- self-hosted PostgreSQL needs `shared_preload_libraries = 'pg_cron'` plus a
-- restart. Neither is something this file can do, and neither should fail the
-- migration: the notice below is the instruction, and the function above stays
-- callable by hand or from an external scheduler until it is followed.
do $$
begin
  create extension if not exists pg_cron;
exception
  when others then
    raise notice
      'retention: pg_cron is not available here (%). Enable it in '
      'Dashboard -> Database -> Extensions, then re-run this file, or call '
      'public.purge_expired_proctoring_logs() from your own scheduler. '
      'Nothing else in this migration depends on it.', sqlerrm;
end $$;

do $$
begin
  if to_regnamespace('cron') is null then
    raise notice 'retention: no cron schema, so the job was not scheduled';
    return;
  end if;

  -- Re-runnable: one job per name, whatever was scheduled before.
  if exists (select 1 from cron.job where jobname = 'proctoring-logs-retention') then
    begin
      perform cron.unschedule('proctoring-logs-retention');
    exception
      when undefined_function then
        -- pg_cron older than 1.5 only has the id-based overload.
        execute 'select cron.unschedule(jobid) from cron.job where jobname = $1'
          using 'proctoring-logs-retention';
    end;
  end if;

  -- 03:23 UTC: after the last sitting has ended in every timezone the app is
  -- deployed in, and off the whole hour so a fleet of Supabase projects on this
  -- file does not all purge at 03:00.
  perform cron.schedule(
    'proctoring-logs-retention',
    '23 3 * * *',
    'select public.purge_expired_proctoring_logs()'
  );

  raise notice
    'retention: proctoring_logs purge scheduled nightly at 03:23 UTC';
end $$;

-- The heartbeat purge, on its own schedule. 04:07 UTC, later than the incident
-- purge on purpose: the two touch different tables, but they both walk
-- `exam_submissions`, and giving them half an hour of distance keeps the nightly
-- vacuum away from the window in which attempts are still closing.
do $$
begin
  if to_regnamespace('cron') is null then
    raise notice
      'retention: no cron schema, so the heartbeat purge was not scheduled';
    return;
  end if;

  if exists (select 1 from cron.job where jobname = 'proctor-heartbeats-retention') then
    begin
      perform cron.unschedule('proctor-heartbeats-retention');
    exception
      when undefined_function then
        execute 'select cron.unschedule(jobid) from cron.job where jobname = $1'
          using 'proctor-heartbeats-retention';
    end;
  end if;

  perform cron.schedule(
    'proctor-heartbeats-retention',
    '7 4 * * *',
    'select public.purge_expired_proctor_heartbeats()'
  );

  raise notice
    'retention: proctor_heartbeats purge scheduled nightly at 04:07 UTC';
end $$;



