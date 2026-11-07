-- =====================================================================
-- PROCTORGUARD - register_violation: A SNAPSHOT PATH MUST BE THIS ATTEMPT'S
-- Keeps the 3-strike RPC exactly as it is, except that `p_snapshot_url` is only
-- stored when it names an object inside the calling attempt's own folder.
--
-- WHY THIS FILE EXISTS
--   `p_snapshot_url` is the one string a student's device chooses and the database
--   stores verbatim in `proctoring_logs.snapshot_url`. Nothing checked it, so it
--   could name an object in *another* submission's folder, a path outside the
--   bucket, or a URL from somewhere else entirely. Two things follow from that:
--     * evidence poisoning - an incident row that appears to belong to this
--       student's sitting while pointing at a still of somebody else, which is what
--       a supervisor reviews and what an appeal would be judged on;
--     * a delete primitive by proxy - "Reset attempt" reads the paths off these
--       rows and removes the objects they name, so a forged path makes the *next*
--       legitimate resetter delete another student's evidence.
--   The upload policy already keeps a student's `storage.objects` INSERT inside the
--   folder of their own ongoing attempt; this is the same rule for the row that
--   references it, which the upload policy cannot enforce.
--
-- WHAT CHANGES (one statement, inside the function)
--   The value is stored only when it matches
--       ^<p_submission_id>/<action_type>_<epoch-ms>\.(jpg|png)$
--   - the exact name `SupabaseService.snapshotPath()` mints, in this attempt's own
--   folder: `[a-z_]+` is the action_type vocabulary (every member is lowercase
--   ASCII and underscores), `[0-9]+` is the epoch-millisecond stamp, and the two
--   extensions are the only mime types the bucket accepts. Anything else is stored
--   as NULL.
--   The first version of this file only asked for the `<p_submission_id>/` prefix,
--   which left the interesting half open: a folder-shaped name the app never
--   minted (`<own id>/evidence.jpg`, `<own id>/nested/x.jpg`, `<own id>/x_1.gif`)
--   passes a prefix test and can point at any object the account can put there.
--   The regex closes that without touching the folder rule the bucket, the upload
--   policy and the purge all assume.
--   It is *stored as NULL rather than rejected* on purpose: the violation must
--   still count. A client that sends a malformed path - an older build, a device
--   that minted a full URL, a patched one that knows this rule - must not be able
--   to trade a strike for a bad string. The incident is the fact; the photograph
--   is the optional attachment.
--
-- WHAT IS UNCHANGED, DELIBERATELY
--   * The signature, the defaults (`p_snapshot_url`, `p_client_timestamp`,
--     `p_client_event_id`) and the `returns table(warning_count, disqualified)`
--     shape - the Flutter client's `registerViolation()` call is untouched.
--   * `revoke execute ... from public, anon` + `grant execute ... to authenticated,
--     service_role`, restated at the end of this file. A `create or replace`
--     preserves the ACL, but restating it here is what makes this migration
--     readable as a *complete* definition of the RPC's reach.
--   * The ownership check (`s.student_id = auth.uid()`, `for update`), the
--     authentication check, the "late frame after close is harmless" early return,
--     the `on conflict (client_event_id) ... do nothing` idempotency, the strike
--     count read from `proctoring_logs`, and the third-strike disqualification.
--   * Existing rows: nothing is rewritten. Rows written before this file may still
--     hold legacy full URLs, and both clients normalise those back to an object
--     path before signing or purging (`SupabaseService.snapshotObjectPath`), so old
--     evidence stays reviewable and old purges still resolve.
--
-- SAFETY
--   * Re-runnable on its own - **but never after
--     `20261104090100_weighted_strikes_and_flagged_review.sql`**. That file
--     replaces this definition with a three-column return shape
--     (`warning_count, disqualified, flagged`), and `create or replace` cannot
--     change a return type: run this file afterwards and the `create` below fails
--     with
--       42P13  cannot change return type of existing function
--     ("Use DROP FUNCTION ... first") while the statements above it in the file
--     have already run, so the operator sees an error and no rollback. If it is
--     ever run by mistake, re-apply
--     `20261104090100_weighted_strikes_and_flagged_review.sql`.
--   * Otherwise safe to re-run: `create or replace function` + `drop function if
--     exists` for the two pre-offline-queue overloads (an old project may still
--     carry them, and `create or replace` cannot remove a different signature;
--     leaving them would also make a named 3-argument call ambiguous).
--   * A fresh project never needs this file: `supabase/schema.sql` already carries
--     the current `register_violation()`. Migrations are the upgrade path for a
--     project that already exists.
--   * The only refusal that is new is "store NULL instead of that string" - the RPC
--     never raises for a bad path, so no live client breaks.
--   * PREREQUISITES: `public.exam_submissions` / `public.proctoring_logs` with
--     `client_event_id` and its partial unique index, and the private
--     `proctor-snapshots` folder convention (`private_proctor_snapshots.sql`).
--   * APPLY ORDER: after `private_proctor_snapshots.sql` and after
--     `20261103090400_submissions_insert_own_ongoing.sql`; before
--     `20261103090800_snapshot_purge_not_live_attempt.sql`, which narrows the
--     purge that consumes these paths (the two are the write half and the purge
--     half of the same evidence trail).
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090700_register_violation_snapshot_path.sql
--   * Verify (expect true, i.e. the regex CASE expression is in the live definition):
--       select pg_get_functiondef(
--                'public.register_violation(uuid,text,text,timestamptz,uuid)'::regprocedure
--              ) like '%[a-z_]+_[0-9]+%' as validates_path;
-- =====================================================================

-- The pre-offline-queue signatures. An old project can still carry them, and a
-- named 3-argument call would be ambiguous against the defaulted 5-argument form.
drop function if exists public.register_violation(uuid, text);
drop function if exists public.register_violation(uuid, text, text);

create or replace function public.register_violation(
  p_submission_id    uuid,
  p_action_type      text,
  p_snapshot_url     text default null,
  p_client_timestamp timestamptz default null,
  p_client_event_id  uuid default null
)
returns table(warning_count int, disqualified boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count  int;
  v_status text;
  v_snapshot_path text;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to register a violation'
      using errcode = '42501';
  end if;

  -- SECURITY DEFINER is required here (a student may neither insert into
  -- proctoring_logs nor update exam_submissions), which is exactly why the
  -- function has to re-check who is asking.
  select s.status
    into v_status
  from public.exam_submissions s
  where s.id = p_submission_id
    and s.student_id = auth.uid()
  for update;

  if v_status is null then
    raise exception 'submission % does not belong to the caller', p_submission_id
      using errcode = '42501';
  end if;

  -- Frames that arrive after the attempt closed (submitted, or already at
  -- strike 3) must not append more evidence or resurrect the session: report
  -- the final state instead of raising, so a late callback is harmless.
  if v_status <> 'ongoing' then
    select count(*) into v_count
    from public.proctoring_logs
    where submission_id = p_submission_id;
    return query select v_count, (v_status = 'disqualified');
    return;
  end if;

  -- THE NEW RULE. Only this attempt's own snapshot object is stored, and only in
  -- the shape the app mints: `<p_submission_id>/<action_type>_<epoch-ms>.(jpg|png)`.
  -- Anything else becomes NULL and the violation still counts. A `~` on NULL is
  -- NULL, which takes the `else` arm, so a missing path stays missing.
  v_snapshot_path := case
    when p_snapshot_url ~ ('^' || p_submission_id::text || '/[a-z_]+_[0-9]+\.(jpg|png)$')
      then p_snapshot_url
    else null
  end;

  -- `on conflict` + the unique index on client_event_id is what makes the
  -- client's offline retry safe: the same event replayed inserts nothing, and the
  -- strike count below is read from the table, so a retry can never turn one
  -- violation into two strikes.
  insert into public.proctoring_logs (
    submission_id, action_type, snapshot_url, client_timestamp, client_event_id
  )
  values (
    p_submission_id,
    p_action_type,
    v_snapshot_path,
    coalesce(p_client_timestamp, now()),
    p_client_event_id
  )
  on conflict (client_event_id) where client_event_id is not null do nothing;

  select count(*) into v_count
  from public.proctoring_logs
  where submission_id = p_submission_id;

  if v_count >= 3 then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now(), score = null
    where id = p_submission_id and status = 'ongoing';
    return query select v_count, true;
  else
    return query select v_count, false;
  end if;
end;
$$;

revoke execute on function public.register_violation(uuid, text, text, timestamptz, uuid) from public, anon;
grant execute on function public.register_violation(uuid, text, text, timestamptz, uuid) to authenticated, service_role;
