-- =====================================================================
-- PROCTORGUARD - THE ORPHAN QUESTION IS ASKED WITH THE OWNER'S EYES
-- Replaces the `not exists (... exam_submissions ...)` arm of both snapshot purge
-- policies with `not public.snapshot_attempt_exists(name)`, so the answer no longer
-- depends on what the CALLER is allowed to read.
--
-- Apply through the CLI (it is in README order, `apply_in_order.ps1` and
-- `apply_live_cli.ps1`):
--
--   supabase db query --linked -f supabase/migrations/20261110090100_snapshot_orphan_check.sql
--
-- WHY THIS FILE EXISTS
--   `20261103090800_snapshot_purge_not_live_attempt.sql` put an orphan test in front
--   of the purge tier:
--
--       not exists (select 1 from public.exam_submissions s
--                    where s.id::text = (storage.foldername(name))[1])
--
--   A policy expression is evaluated with the CALLER's privileges, so that subquery
--   is itself filtered by `submissions_select_own_or_supervisor`. When the arm was
--   written that policy handed every staff member every attempt, so the arm asked
--   the question it meant to ask. `20261109090000_supervisor_exam_assignments.sql`
--   then narrowed the policy to
--
--       student_id = auth.uid()
--       or (public.is_staff()
--           and (not public.is_supervisor_only() or public.can_supervise_exam(exam_id)))
--
--   and left these two policies alone. They now disagree with the table they ask
--   about. For a supervisor who is **not assigned** to the paper the attempt row is
--   invisible - so the subquery returns no row, `not exists` is TRUE, and a folder
--   that names a live attempt is reported "orphaned". The account that may not read
--   that attempt (`submissions_select_own_or_supervisor`: 0 rows), may not open its
--   monitor (no attempt streamed) and may not delete it
--   (`submissions_delete_supervisor`: 0 rows) could yet
--
--     * READ every still in that folder - `Proctor snapshots orphan read for purge`,
--       which exists so that a `DELETE ... WHERE` can see what it deletes, and which
--       hands out a signed URL as an ordinary SELECT;
--     * DELETE them - `Proctor snapshots supervisor purge`, i.e. the destructive half
--       of "Reset attempt" without the repair half that has to come first.
--
--   That is the "evidence gone, attempt untouched, no audit row anywhere" outcome
--   `20261103090800` was written to prevent, reachable by the one role it had just
--   been scoped. This file is the follow-up: the orphan test is asked the way it was
--   always meant to be asked - as a fact about the attempt, not as a read the caller
--   is being granted.
--
-- THE FIX (one predicate, one place)
--   `public.snapshot_attempt_exists(p_object_name text)` answers "is there an
--   `exam_submissions` row for this object's folder?" as its OWNER (`security
--   definer`, pinned `search_path`): the row is looked for directly, not through the
--   caller's RLS, so an unassigned supervisor cannot make the table look empty. Both
--   purge policies then read
--
--       bucket_id = 'proctor-snapshots'
--       and public.is_attempt_resetter()
--       and not public.snapshot_attempt_exists(name)
--
--   which is the same three terms as before - the tier, the bucket and the orphan
--   test - with only the third answered the way it was intended.
--
-- WHY A DEFINER HELPER RATHER THAN WIDENING A READ
--   * Widening `submissions_select_own_or_supervisor` back would undo the scope the
--     roster, the monitor, the incident feed and the profile roster all depend on
--     (`20261109090000`). The orphan test is not a read being granted to the caller:
--     it is a yes/no about a row the caller is not allowed to see, which is exactly
--     what a definer helper is for - `owns_exam()`, `can_supervise_exam()`,
--     `can_read_profile()` and `is_attempt_resetter()` are all definer functions
--     called from policies for that reason.
--   * `revoke execute ... from public, anon` keeps it off the client API. It is
--     called by the two policies as `authenticated`, and by `service_role`. An
--     account that could call it directly could ask "does this attempt id exist?"
--     for any id, which is a read the roster scope withholds.
--   * A folder that cannot be an attempt id must not raise. `storage.objects.name`
--     is free text - a stray object (`readme`, `legacy/photo.jpg`) is possible on any
--     project - and a bare `::uuid` cast inside a policy would turn one such row into
--     22P02 for the whole purge statement instead of an answer about one object. The
--     helper shape-tests the segment first and returns false ("this folder names no
--     attempt") for anything that cannot be a submission id, which is the answer the
--     old text comparison gave.
--
-- THE PURGE OF A GENUINELY ORPHANED STILL STILL WORKS
--   A still whose attempt row is gone - the state
--   `DashboardRepositoryImpl.resetSubmission()` creates before it calls
--   `storage.remove()` - resolves to no row for an administrator, a lecturer and a
--   supervisor alike (the helper reads the table, not the reader's scope), so all
--   three may still read and purge it, exactly as today. The two routes that delete
--   without RLS - the `purge-snapshots` Edge Function (`service_role`, Storage API)
--   and `public.purge_expired_snapshots()` (`security definer`, `service_role` only)
--   - never went through these policies and are unaffected: neither reads
--   `snapshot_attempt_exists()` nor depends on the shape of a policy.
--
--   What the fix does *not* change, deliberately: an orphaned still stays purgeable
--   by the reset tier whoever is asking, because "orphaned" is now a fact about the
--   bucket rather than about the caller. It cannot be used to erase a live attempt's
--   evidence - the folder has to name no attempt first, and removing that attempt is
--   `submissions_delete_supervisor`'s scoped decision, audited in
--   `session_reset_logs`.
--
-- WHAT IT DOES NOT DO
--   * No change to `Proctor snapshots read access`, to `Proctor snapshots upload own
--     ongoing session`, to `submissions_select_own_or_supervisor`, or to
--     `is_attempt_resetter()`.
--   * No row, object or path is rewritten and no object is deleted: this is one
--     function and two `drop policy if exists` + `create policy` pairs.
--   * Nothing new is reachable by a student: `is_attempt_resetter()` (admin,
--     supervisor, lecturer) is still the widest term either policy has.
--
-- SAFETY
--   * Safe to re-run: `create or replace function`, `drop policy if exists` +
--     `create policy`.
--   * Fail-closed: a folder that cannot be shown to name no attempt is treated as a
--     live attempt's (`true`), so this file can only take a read or a delete away,
--     never grant one.
--   * One behaviour does differ for a spelling the app never writes: a folder whose
--     text is an UPPER-CASE uuid now resolves to its attempt (`s.id = folder::uuid`)
--     where the old text comparison did not. The direction is the safe one - kept,
--     not purged - and `SupabaseService` writes lowercase uuid text.
--   * PREREQUISITES: `public.exam_submissions` (`schema.sql` section 4),
--     `public.is_attempt_resetter()` (`schema.sql` section 1 or
--     `staff_attempt_resets.sql`), the private `proctor-snapshots` bucket and the
--     policies this file replaces (`private_proctor_snapshots.sql`,
--     `20261103090800_snapshot_purge_not_live_attempt.sql`).
--   * APPLY ORDER: last of the snapshot files, and after
--     `20261109090000_supervisor_exam_assignments.sql` - the narrowing it answers.
--     `private_proctor_snapshots.sql`, `staff_attempt_resets.sql`,
--     `secure_exam_access_and_deadlines.sql` and
--     `20261103090800_snapshot_purge_not_live_attempt.sql` each (re)create one or both
--     of these policies - all but the last without an orphan test at all, and the last
--     with the caller-scoped one - so re-apply THIS file after any of them.
--     `schema.sql` carries the helper and both policies, so a fresh install never needs
--     this file.
--   * Verify (expect `snapshot_attempt_exists` and no inline subquery on
--     `exam_submissions`):
--
--       select polname, pg_get_expr(polqual, polrelid) as using_expr
--         from pg_policy
--        where polrelid = 'storage.objects'::regclass
--          and polname in ('Proctor snapshots supervisor purge',
--                          'Proctor snapshots orphan read for purge');
--
-- `supabase/tests/supervisor_scope_check.sql` blocks (e)ii-iii prove both halves: an
-- unassigned supervisor reads and deletes 0 rows of another paper's live attempt,
-- and an orphaned still is still readable and purgeable by the tier that resets.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE PREDICATE - asked as the owner, never as the caller
-- ---------------------------------------------------------------------
-- `security definer` is the whole point: a policy expression runs with the CALLER's
-- rights, and the caller here may be a supervisor who cannot read the attempt in
-- question (`submissions_select_own_or_supervisor`, narrowed by `20261109090000`).
-- The row it must not see still exists, and this answers for the row rather than for
-- the reader. A definer function is only as trustworthy as its owner - on a Supabase
-- project that is `postgres`, which is also what applies this file.
--
-- STABLE, not VOLATILE: it is asked once per candidate object inside one DELETE and
-- must see `exam_submissions` as of that statement - which is exactly the snapshot in
-- which a reset's earlier `delete from exam_submissions` has already happened.
create or replace function public.snapshot_attempt_exists(p_object_name text)
returns boolean
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_folder text;
begin
  if p_object_name is null then
    return false;
  end if;

  v_folder := (storage.foldername(p_object_name))[1];

  -- `<submission_id>/<action_type>_<epoch-ms>.jpg` is the only path the upload policy
  -- admits, but `storage.objects.name` is free text and an object written before that
  -- policy existed may not follow it. Shape-tested before the cast on purpose: a
  -- `::uuid` that raised on one stray object would abort the whole purge statement
  -- (22P02) instead of answering about that object.
  if v_folder is null
     or v_folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  then
    return false;
  end if;

  -- Compared as a uuid rather than as text, so one folder spelled another way names
  -- the same attempt: the answer for a folder that does name a live attempt has to be
  -- `true` however it is spelled.
  return exists (
    select 1 from public.exam_submissions s where s.id = v_folder::uuid
  );
end;
$$;

-- Called by the two policies below (as `authenticated`) and by nothing else - it is
-- not a client API: an account that could call it directly could ask "does this
-- attempt id exist?" for any id, which is a read the roster scope withholds.
-- `pg_temp` is pinned last in the search path so that a temporary schema cannot
-- shadow `exam_submissions` in front of the definer body.
revoke execute on function public.snapshot_attempt_exists(text) from public, anon;
grant execute on function public.snapshot_attempt_exists(text) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 2. THE TWO POLICIES - same three terms, third one asked properly
-- ---------------------------------------------------------------------
-- Every term but the orphan test is the sentence `20261103090800` wrote, kept word
-- for word: the bucket (no other bucket is in reach), the tier that is allowed to
-- delete an attempt at all (`is_attempt_resetter()`: admin, supervisor, lecturer -
-- not a student, not `anon`), and "the folder names no attempt". Only that last term
-- changes owner.
--
-- The DELETE. `storage.remove()` issues `DELETE ... WHERE name = <path>`, so this is
-- the statement the console's reset and the Edge Function's client-side twin run.
drop policy if exists "Proctor snapshots supervisor purge" on storage.objects;
create policy "Proctor snapshots supervisor purge"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not public.snapshot_attempt_exists(name)
  );

-- The companion SELECT. A DELETE with a WHERE clause must also pass the table's
-- SELECT policies - Postgres only lets a statement delete rows it is allowed to see -
-- and `Proctor snapshots read access` admits a staff member only through an attempt
-- row, while the purge runs exactly when that row is gone. Without this twin the
-- purge matched 0 rows and left the stills behind. Same predicate as the DELETE, on
-- SELECT: it exposes already-orphaned objects to the tier that is about to delete
-- them, and nothing else.
--
-- It is also the policy the hole was *read* through: an unassigned supervisor could
-- SELECT - and therefore request a signed URL for - another paper's live evidence,
-- because the caller's own RLS made `exam_submissions` look empty to the subquery.
-- The helper answers with the owner's eyes, so the folder is no longer "orphaned"
-- just because the reader may not see what is in it.
drop policy if exists "Proctor snapshots orphan read for purge" on storage.objects;
create policy "Proctor snapshots orphan read for purge"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'proctor-snapshots'
    and public.is_attempt_resetter()
    and not public.snapshot_attempt_exists(name)
  );

-- Untouched on purpose, and named so a later reader can see they were considered:
--   "Proctor snapshots read access"               - still resolves the folder to the
--                                                   attempt and asks whose it is
--                                                   (student / `owns_exam()` /
--                                                   `can_supervise_exam()`).
--   "Proctor snapshots upload own ongoing session" - still the owning student's, and
--                                                   only while 'ongoing'.
--   public.is_attempt_resetter()                  - still the tier list.


-- ---------------------------------------------------------------------
-- 3. VERIFY
-- ---------------------------------------------------------------------
-- Raises rather than reporting success, because every statement above is
-- `create or replace` or `drop policy if exists` + `create policy`: a file that ran
-- halfway would otherwise look clean. The `pg_policies` scan is the part that
-- matters - it is the only check that reads what the server will actually evaluate,
-- so a policy that came back through an older file (this one re-applied before, say,
-- `20261103090800`) is caught here rather than by a supervisor who can sign a URL to
-- somebody else's face.
do $$
declare
  v_fn       regprocedure;
  v_definer  boolean;
  v_volatile text;
  v_config   text[];
  v_purge    text;
  v_orphan   text;
begin
  v_fn := to_regprocedure('public.snapshot_attempt_exists(text)');
  if v_fn is null then
    raise exception 'FAIL: public.snapshot_attempt_exists(text) does not exist';
  end if;

  select p.prosecdef, p.provolatile::text, p.proconfig
    into v_definer, v_volatile, v_config
  from pg_proc p
  where p.oid = v_fn;

  if not v_definer then
    raise exception 'FAIL: snapshot_attempt_exists() is not SECURITY DEFINER, so it answers as the caller';
  end if;
  if v_volatile <> 's' then
    raise exception 'FAIL: snapshot_attempt_exists() is not STABLE (provolatile = %)', v_volatile;
  end if;
  if not coalesce(array_to_string(v_config, ' ') like '%search_path%', false) then
    raise exception 'FAIL: snapshot_attempt_exists() does not pin search_path';
  end if;

  if not has_function_privilege('authenticated', v_fn, 'execute') then
    raise exception 'FAIL: authenticated cannot execute snapshot_attempt_exists(), so every purge would fail';
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon')
     and has_function_privilege('anon', v_fn, 'execute') then
    raise exception 'FAIL: anon can execute snapshot_attempt_exists(); it is not a client API';
  end if;

  -- A stray object must be answered about, not raised over: if either of these
  -- aborts, a purge statement that scans such a row dies with 22P02.
  if public.snapshot_attempt_exists('readme/looking_away_1.jpg') then
    raise exception 'FAIL: a non-uuid folder is reported as an attempt';
  end if;
  if public.snapshot_attempt_exists(null) then
    raise exception 'FAIL: a NULL object name is reported as an attempt';
  end if;

  select coalesce(qual, '') into v_purge
  from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and policyname = 'Proctor snapshots supervisor purge';

  select coalesce(qual, '') into v_orphan
  from pg_policies
  where schemaname = 'storage' and tablename = 'objects'
    and policyname = 'Proctor snapshots orphan read for purge';

  if v_purge is null or v_orphan is null then
    raise exception 'FAIL: a purge policy is missing after this file ran';
  end if;

  if v_purge not like '%snapshot_attempt_exists%'
     or v_orphan not like '%snapshot_attempt_exists%' then
    raise exception 'FAIL: a purge policy still asks the orphan question inline';
  end if;

  if v_purge not like '%is_attempt_resetter%'
     or v_orphan not like '%is_attempt_resetter%' then
    raise exception 'FAIL: a purge policy lost its reset-tier term';
  end if;

  -- The regression itself: an inline subquery here is the caller-scoped question this
  -- file exists to remove.
  if v_purge like '%exam_submissions%' or v_orphan like '%exam_submissions%' then
    raise exception 'FAIL: a purge policy still reads exam_submissions as the caller';
  end if;

  -- The other two policies were not touched, and this is how a half-applied file that
  -- dropped one of them shows up.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and policyname = 'Proctor snapshots read access'
       and coalesce(qual, '') like '%can_supervise_exam%'
  ) then
    raise exception 'FAIL: Proctor snapshots read access is missing or no longer asks the paper';
  end if;

  raise notice 'snapshot orphan check installed: both purge policies ask snapshot_attempt_exists(), which answers with the owner''s eyes';
end $$;

