-- =====================================================================
-- PROCTORGUARD - THE STILLS GET A LIFETIME TOO
-- Adds `public.purge_expired_snapshots(interval, boolean)` and the retention
-- windows for the snapshot bucket, `profiles` and `exam_submissions`.
--
-- WHY THIS FILE EXISTS
--   `retention_policy.sql` gave `proctoring_logs` and `proctor_heartbeats` a
--   lifetime and said, in as many words, that it does not touch
--   `storage.objects`. That left the most sensitive artefact in this system
--   with no expiry at all: a photograph of a student's face, kept in the private
--   `proctor-snapshots` bucket, outliving the incident it explains and the
--   appeal it might be needed for, forever. "We delete your snapshots after N
--   days" is a sentence in the consent notice now
--   (`20261106090000_proctoring_consents.sql`), so something has to make it
--   true.
--
-- WHAT IT ADDS
--   1. Three retention windows, seeded and never overwritten:
--        ('proctor_snapshots', 30)   - the photographs;
--        ('profiles', 180)           - an account's own row, i.e. its personal
--                                      data, after the person has gone;
--        ('exam_submissions', 180)   - the attempt record (answers, mark,
--                                      status) an appeal is argued from.
--      The two 180s are documented as "align with your appeals period" rather
--      than as a legal opinion: the number an institution needs is the length of
--      the window in which a student can contest a mark, and only the
--      institution knows it.
--   2. `purge_expired_snapshots(p_older_than interval default '30 days',
--      p_dry_run boolean default false)` - deletes the `storage.objects` rows for
--      stills older than the window that do not belong to a live attempt, and
--      nulls `proctoring_logs.snapshot_url` for each one. Where the deployment
--      permits a SQL delete: on hosted Supabase the trigger described below
--      refuses it, and the function says so instead of half-doing it.
--
-- WHAT THE FUNCTION DELIBERATELY KEEPS
--   * The incident row itself. A violation that happened still happened after
--     its photograph is gone - the type, the strike weight, the time and the
--     attempt it belongs to all survive. Only the pointer to the image is
--     nulled, which is the honest record: "there was a still here, it expired".
--   * Every still belonging to an attempt that is still `ongoing`. Same guard,
--     same reason as the other two purges: a live sitting is exactly when a
--     still matters, and an abandoned attempt left open for months keeps its
--     evidence. That is the safe failure direction.
--   * Anything newer than the window, whatever its attempt's status.
--
-- READ THIS BEFORE SCHEDULING IT: A DELETED ROW IS NOT A DELETED FILE
--   Deleting from `storage.objects` removes Storage's *bookkeeping* row. Whether
--   the underlying file in the object store goes with it depends on the
--   deployment: Supabase's own Storage API issues both, a raw SQL delete does
--   not. So:
--     * on a Supabase project the supported path is the `purge-snapshots` Edge
--       Function in `supabase/functions/purge-snapshots/`, which goes through the
--       Storage API and therefore removes the file as well;
--     * this function exists for the setups where the Storage API cannot be
--       reached (self-hosted behind a firewall, a project without Edge
--       Functions) and as the documented fallback the requirement asked for;
--     * **do not run both on the same window.** This function consumes the
--       bookkeeping row, and an object with no row is invisible to the Storage
--       API - so running this one first leaves files nobody can enumerate
--       afterwards. Run the Edge Function, or this, never a race between them.
--   Both write the same result into `proctoring_logs` (the pointer is nulled), so
--   the app and the console read the same thing either way.
--
-- READ THIS TOO: ON A HOSTED PROJECT THE SQL ROUTE IS BLOCKED, NOT JUST LIMITED
--   On hosted Supabase, `storage.objects` carries a `protect_delete` trigger
--   (`storage.protect_delete()`) that refuses *every* SQL DELETE from it:
--       42501  Direct deletion from storage tables is not allowed
--   It lets a delete through only when the session has set
--   `storage.allow_delete_query = 'true'` - the flag the Storage API sets on
--   itself while it is the one deleting. This function deliberately does **not**
--   set that flag, because on such a project a SQL delete would strand the file
--   anyway (see above): it removes the bookkeeping row, never reaches the object
--   store, and leaves an object nothing can enumerate again. So:
--     * on a hosted project `purge-snapshots` is the **only supported route** -
--       the live path of this function raises 42501, with a message naming that
--       Edge Function, and purges nothing (the pointer update rolls back with it,
--       so a refused run leaves the database exactly as it was);
--     * the dry run works everywhere, trigger or no trigger: it counts and
--       deletes nothing, so "what would expire?" can always be asked;
--     * where the trigger is absent (a self-hosted or base image that has not
--       added it) the live path does run, with the caveat above about the file.
--
-- WHAT THIS FILE DOES NOT DO
--   * It does not schedule anything. A cron job that deletes photographs is a
--     decision an operator makes deliberately, with the appeals period in front
--     of them - the README documents both routes (pg_cron via `net.http_post`,
--     or the dashboard's scheduled functions). Nothing here runs by itself.
--   * It does not delete `profiles` or `exam_submissions` rows. Those windows are
--     *recorded* so the institution has one place that states its retention, and
--     so a future purge (or an export-and-erase job) has a number to read. A
--     row-level purge of `profiles` is an account-deletion decision with its own
--     cascade; it is not something a nightly job should start doing because a
--     migration added a row to this table.
--   * It does not touch `session_reset_logs` or `attempt_review_logs`. Both are
--     audit trails of staff decisions, not telemetry.
--
-- SAFETY
--   * Safe to re-run: `insert ... on conflict do nothing`, `create or replace
--     function`.
--   * Additive only, and it deletes nothing until an operator calls it.
--   * PREREQUISITES: `public.retention_policies` from
--     `supabase/migrations/retention_policy.sql` (apply that file first - the
--     seeds below report SKIP and this file still creates the function if it is
--     missing); `public.proctoring_logs.snapshot_url` and the
--     `proctor-snapshots` bucket from `schema.sql` section 6.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261106090100_snapshot_retention.sql
--   * Verify (expect counts, and nothing deleted):
--       select * from public.retention_policies order by table_name;
--       select public.purge_expired_snapshots(p_dry_run => true);
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The windows
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.retention_policies') is null then
    raise notice
      'snapshot_retention: public.retention_policies is missing - apply '
      'supabase/migrations/retention_policy.sql first and re-run this file. '
      'The purge function below is created either way.';
    return;
  end if;

  -- `on conflict do nothing` on purpose: a second run must never reset a window
  -- an operator has already edited to match their own appeals period.
  insert into public.retention_policies (table_name, retention_days) values
    -- The photographs. Short, because a still is identification-grade data and
    -- its evidential value is front-loaded: it matters in the week after a
    -- sitting, not in month four.
    ('proctor_snapshots', 30),
    -- Align both of these with the institution's appeals period. 180 days is a
    -- default, not a recommendation: it is the shortest round number that covers
    -- a semester's marking plus a result-and-appeal cycle.
    ('profiles', 180),
    ('exam_submissions', 180)
  on conflict (table_name) do nothing;

  raise notice 'snapshot_retention: retention windows seeded (existing values kept)';
end $$;

comment on table public.retention_policies is
  'How long rows in a public table are kept. Read by '
  'public.purge_expired_proctoring_logs(), '
  'public.purge_expired_proctor_heartbeats() and the purge-snapshots Edge '
  'Function; change retention_days here rather than editing a function or a '
  'schedule. The profiles / exam_submissions windows are recorded for the '
  'institution''s own erasure and export path - no job deletes those rows.';

comment on column public.retention_policies.retention_days is
  'Rows (or objects, for proctor_snapshots) older than this many days are '
  'deleted by the retention job. Align profiles and exam_submissions with your '
  'appeals period.';


-- ---------------------------------------------------------------------
-- 2. The purge
-- ---------------------------------------------------------------------
-- One pass, two writes, in this order: the pointer goes first, the object row
-- second. If the delete fails after the nulling, an incident row points at
-- nothing and the object is retried on the next run - whereas the other order
-- leaves a log row pointing at a path that no longer exists, which is
-- indistinguishable from evidence somebody removed deliberately.
--
-- The candidate set is computed once into `v_paths` so the dry run and the real
-- run cannot disagree about what "expired" means, and so the two writes touch
-- exactly the same list.
create or replace function public.purge_expired_snapshots(
  p_older_than interval default interval '30 days',
  p_dry_run    boolean  default false
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_paths   text[];
  v_count   bigint;
  v_deleted bigint := 0;
begin
  -- A zero or negative window would mean "delete every still, including the one
  -- from the sitting happening now". Refused rather than clamped: an operator
  -- who passes 0 has a bug, and guessing which window they meant is worse.
  if p_older_than is null or p_older_than <= interval '0' then
    raise exception 'purge_expired_snapshots: the window must be greater than zero.'
      using errcode = '22023';
  end if;

  -- The folder is the submission id (`<submission_id>/<action_type>_<ms>.jpg`,
  -- schema.sql section 6), so the attempt's status is one lookup away. Three
  -- cases, and only one keeps the object:
  --   * folder resolves to an `ongoing` attempt  -> kept, whatever its age;
  --   * folder resolves to any other attempt     -> expired, aged out;
  --   * folder resolves to nothing (orphaned by a reset) -> expired, aged out.
  -- `created_at` is the upload time. A NULL created_at is never "older than",
  -- which errs towards keeping the object - the direction that can be fixed by
  -- hand later.
  select coalesce(array_agg(o.name order by o.name), '{}'::text[])
    into v_paths
    from storage.objects o
   where o.bucket_id = 'proctor-snapshots'
     and o.created_at < now() - p_older_than
     and coalesce(
           (select s.status
              from public.exam_submissions s
             where s.id::text = (storage.foldername(o.name))[1]),
           'gone'
         ) <> 'ongoing';

  v_count := coalesce(array_length(v_paths, 1), 0);

  if p_dry_run then
    raise notice 'retention: would purge % snapshot object(s) older than %',
      v_count, p_older_than;
    return v_count;
  end if;

  if v_count = 0 then
    raise notice 'retention: no snapshot objects older than %', p_older_than;
    return 0;
  end if;

  -- The incident survives; the photograph does not. `snapshot_url` is the object
  -- path (not a URL), so it is compared directly against the names Storage
  -- holds - the same value `register_violation()` validated when the strike was
  -- recorded.
  update public.proctoring_logs l
     set snapshot_url = null
   where l.snapshot_url = any (v_paths);

  -- On hosted Supabase `storage.objects` carries the `protect_delete` trigger
  -- (`storage.protect_delete()`), which refuses *every* SQL DELETE from that
  -- table -
  --     42501  Direct deletion from storage tables is not allowed
  -- unless the session has set `storage.allow_delete_query = 'true'`: the flag
  -- the Storage API sets on itself while it deletes (see this file's header).
  -- This function does not set that flag. Where the trigger is installed, a SQL
  -- delete only removes the bookkeeping row and strands the file - an object the
  -- Storage API can never enumerate again - which is the worse of the two
  -- outcomes. So the refusal is translated, not bypassed.
  --
  -- The nested block earns its keep twice: the original SQLSTATE (42501) is kept
  -- in the re-raise, so a caller's own `when sqlstate '42501'` still matches, and
  -- PL/pgSQL rolls a block's changes back when its handler catches - which means
  -- the pointer update above goes with it. A refused run therefore changes
  -- nothing at all: no log row is left pointing at an object that was not
  -- deleted.
  begin
    delete from storage.objects o
     where o.bucket_id = 'proctor-snapshots'
       and o.name = any (v_paths);
    get diagnostics v_deleted = row_count;
  exception
    when insufficient_privilege then
      raise exception
        'purge_expired_snapshots: the storage.objects delete was refused (%) and '
        'nothing was purged. On hosted Supabase that is the '
        'storage.protect_delete() trigger, which blocks every SQL delete: run the '
        'purge-snapshots Edge Function there instead - it goes through the Storage '
        'API, so the file goes with its row.', sqlerrm
        using errcode = '42501',
              hint = 'What would expire, deleting nothing: '
                     'select public.purge_expired_snapshots(p_dry_run => true);';
  end;

  raise notice 'retention: purged % snapshot object(s) older than % (of % expired)',
    v_deleted, p_older_than, v_count;

  -- The count that matters is what actually went, not what was attempted. A
  -- refusal is *not* one of these numbers: it raised, above, rather than
  -- returning a 0 that would read as "nothing had expired".
  return v_deleted;
end;
$$;

comment on function public.purge_expired_snapshots(interval, boolean) is
  'Deletes proctor-snapshots objects older than the window (default 30 days) and nulls the proctoring_logs.snapshot_url pointer to each, keeping the incident row. Never touches an attempt that is still ongoing, a dry run deletes nothing, and a window of zero or less is refused. Removes the storage.objects rows only - the file is removed by the purge-snapshots Edge Function (Storage API) or a bucket lifecycle rule. On hosted Supabase the storage.protect_delete() trigger refuses every SQL delete, so the live run raises 42501 naming the Edge Function and purges nothing; read this file''s header before scheduling either.';

revoke all on function public.purge_expired_snapshots(interval, boolean)
  from public, anon, authenticated;
grant execute on function public.purge_expired_snapshots(interval, boolean)
  to service_role;

