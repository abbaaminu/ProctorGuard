-- =====================================================================
-- PROCTORGUARD - THE NOTICE A STUDENT ACCEPTS BEFORE AN ATTEMPT EXISTS
-- Adds `public.proctoring_consents` and the current notice version, names the
-- predicate "has this student accepted the current notice for this paper?" and
-- makes that predicate a condition of `submissions_insert_own_ongoing`.
--
-- WHY THIS FILE EXISTS
--   Everything the proctoring engine does to a student - the camera, the
--   microphone's noise floor, the still that is kept when something is flagged,
--   the supervisor who reads it - happened on the strength of a paragraph in an
--   instructions dialog nobody could prove had been shown. Consent was a claim
--   the client made by *starting*, which is not a record: it cannot say what
--   wording the student saw, when they saw it, or whether they saw anything at
--   all. That is the gap this file closes.
--
--   It is also what makes the snapshots defensible. A photograph of somebody's
--   face is the most sensitive row in this schema, and the answer to "on what
--   basis was this captured?" has to be a row in a table, written before the
--   first frame, not an implied agreement in an app store listing.
--
-- WHAT IT ADDS
--   1. `public.proctoring_consent_config` - one row naming the notice version
--      that is currently in force. The *server* decides what "current" means;
--      the app carries the matching text (and its own copy of the version
--      string) so a build that never shipped the new wording cannot accept it
--      for the student. The two are pinned together by
--      `mobile/test/schema_contract_test.dart`.
--   2. `public.proctoring_consents` - one row per (student, paper, version), or
--      per (student, version) when `exam_id` is null (a general acceptance that
--      covers every paper). Immutable by construction: see "WHY IT CANNOT BE
--      EDITED" below.
--   3. `public.record_consent(p_exam_id, p_version)` - the only writer. It
--      stores what the client says it rendered, stamps the transport's own
--      `user-agent` (not one the body claims), and answers whether the version
--      it stored is the one currently in force.
--   4. `public.student_has_consent(p_exam_id)` - the predicate the attempt
--      policy now asks.
--   5. `submissions_insert_own_ongoing` recreated with one added arm:
--      `and public.student_has_consent(exam_id)`.
--
-- WHY THE CHECK IS NOT FOLDED INTO `student_can_access_exam()`
--   That predicate answers "may this student ever sit this paper?" and it is
--   asked by `exams_select` (the tile in the portal), `questions_public` (the
--   paper itself while it is open) and the insert policy. Consent cannot be part
--   of it: a student has to be able to *see* the paper to decide whether to
--   accept the notice for it, so wrapping the two together would produce a paper
--   nobody could consent to and a notice nobody could read. The audience of each
--   question stays separate, and only the caller that creates an attempt asks
--   both.
--
-- WHY IT CANNOT BE EDITED (the control is an absence)
--   `proctoring_consents` gets an INSERT policy (own row only), a SELECT policy
--   (own rows, or the intervention tier), and nothing else: no UPDATE policy, no
--   DELETE policy, and `authenticated` is granted only `select, insert`. A
--   consent record that its subject can rewrite or remove is not a record. There
--   is no `record_consent` twin for deletion either - withdrawing consent is an
--   administrative act (delete the account, or the institution's own erasure
--   path), not something a client RPC does silently while an appeal is open.
--
-- WHY THE INSERT POLICY, AND NOT A CLIENT-SIDE GUARD
--   Same reason every other rule in this schema lives in a policy: the screen
--   that asks is a screen that can be patched. An attempt row is the parent of
--   every other row - answers, incident logs, snapshots, the roster card - so
--   "was the notice accepted?" has to be answered where the row is created. A
--   client that skips the consent screen gets a 42501 on the insert and no
--   attempt, which is the correct outcome even though it is the client's own bug.
--
-- WHAT THIS FILE DOES NOT DO
--   * It does not write a row on behalf of a student, and it does not accept a
--     consent on the basis of an "I agree" flag in a request body. The row is
--     written by `record_consent()` under the student's own session, and the
--     version stored is the one the client says it displayed - the honest limit
--     of what a server can know, and the reason a mismatch is reported back
--     (`is_current = false`) rather than silently accepted.
--   * It does not touch `proctoring_logs`, `proctor_heartbeats`,
--     `exam_submissions.status` or any other policy.
--   * It does not attach the notice text to the row. The text lives in the app
--     (`ProctorConsentConfig` in
--     `mobile/lib/features/exam/domain/entities/proctor_consent.dart`) and is
--     versioned by the string this table stores; copying legal wording into a
--     database column would create a second copy that could be edited after the
--     fact, which is worse than a version string that pins a commit.
--
-- SAFETY
--   * Safe to re-run: `create table if not exists`, `insert ... on conflict do
--     nothing`, `create or replace function`, `drop policy if exists` + `create
--     policy`.
--   * Fail-closed on a missing config: with no row in
--     `proctoring_consent_config`, `current_proctor_consent_version()` is NULL,
--     `student_has_consent()` is therefore false for everybody, and no attempt
--     can be started. That is deliberate - "we cannot say what notice is in
--     force" must not degrade into "no notice is required" - and the seed below
--     is what keeps it from ever being the state of a normal install.
--   * AFTER THIS FILE IS APPLIED, no attempt can be started until the student's
--     client calls `record_consent()`. Deploy the app build that carries the
--     consent screen together with this migration, or students sitting an exam
--     in progress will be refused at the insert. The refusal is a clean 42501 on
--     a row that was never created - not a half-written attempt.
--   * PREREQUISITES: `public.profiles` (schema.sql section 1),
--     `public.exams` (section 2), `public.exam_submissions` (section 4),
--     `public.student_can_access_exam(uuid)` (20261103090100...),
--     `public.is_exam_supervisor()` (schema.sql section 1).
--   * APPLY ORDER: after `20261103090400_submissions_insert_own_ongoing.sql`
--     (this file replaces the policy that file creates). Re-running that older
--     file after this one puts the old, consent-free policy straight back, so
--     re-apply this file after it - the same rule
--     `20261103090800_snapshot_purge_not_live_attempt.sql` states for its own.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261106090000_proctoring_consents.sql
--   * Verify (expect the consent arm inside the policy):
--       select pg_get_expr(polwithcheck, polrelid)
--         from pg_policy
--        where polrelid = 'public.exam_submissions'::regclass
--          and polname = 'submissions_insert_own_ongoing';
--     and (expect one row, `2026-11-v1` as shipped):
--       select * from public.proctoring_consent_config;
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Which notice is currently in force
-- ---------------------------------------------------------------------
-- One row, keyed by a constant `id`. A table rather than a hard-coded string in
-- `student_has_consent()` on purpose: bumping the wording has to be an `update`,
-- not a migration, because the day the institution's legal team changes a
-- sentence is not the day anybody wants to edit a function body.
create table if not exists public.proctoring_consent_config (
  id              smallint primary key default 1,
  -- The version the app's `ProctorConsentConfig.version` must equal. Free text
  -- (a date, a semver, a hash of the wording) - the only property that matters is
  -- that changing the text changes this string.
  current_version text not null
                  check (length(btrim(current_version)) between 1 and 64),
  updated_at      timestamptz not null default now(),
  -- One row, enforced: a second row would make "the current version" ambiguous
  -- and the answer would depend on scan order.
  constraint proctoring_consent_config_single_row check (id = 1)
);

-- Seeded, not assumed: the fail-closed behaviour below means an empty table
-- blocks every attempt, so the migration itself puts the shipped version in
-- place. `on conflict do nothing` leaves a version an operator has edited alone.
insert into public.proctoring_consent_config (id, current_version)
values (1, '2026-11-v1')
on conflict (id) do nothing;

comment on table public.proctoring_consent_config is
  'The proctoring consent notice version a student must have accepted before an attempt can be created. One row. Read by current_proctor_consent_version() / student_has_consent(); set current_version here when the wording changes, and ship an app build whose ProctorConsentConfig.version matches it.';

comment on column public.proctoring_consent_config.current_version is
  'The notice version in force. A consent row only satisfies student_has_consent() when consent_version equals this, so a stale acceptance does not carry over to new wording.';

alter table public.proctoring_consent_config enable row level security;

-- Readable by any signed-in caller (a client may want to tell a student that its
-- bundled wording is out of date), writable by nobody through the API: no
-- insert/update/delete policy at all, and no grant beyond `select`. `postgres`
-- (the SQL editor) and `service_role` bypass this, which is where it is meant to
-- be changed.
revoke all on table public.proctoring_consent_config from anon, authenticated;
grant select on table public.proctoring_consent_config to authenticated;
grant all on table public.proctoring_consent_config to service_role;

drop policy if exists "consent_config_read_all" on public.proctoring_consent_config;
create policy "consent_config_read_all"
  on public.proctoring_consent_config for select
  to authenticated
  using (true);

-- The version, for anything that needs to name it (the predicate below, an
-- operator, a screen that compares its bundled text against the server's).
-- SECURITY DEFINER with a pinned search_path, like every other helper here: the
-- table's policies are not part of the answer.
create or replace function public.current_proctor_consent_version()
returns text
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select c.current_version
    from public.proctoring_consent_config c
   where c.id = 1;
$$;

comment on function public.current_proctor_consent_version() is
  'The proctoring consent notice version currently in force, or NULL when none is configured (which makes every student_has_consent() call false - fail-closed, never "no notice required").';

revoke execute on function public.current_proctor_consent_version() from public, anon;
grant execute on function public.current_proctor_consent_version()
  to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 2. The consent records
-- ---------------------------------------------------------------------
-- `exam_id` is NULLABLE and has no foreign key, both deliberately:
--   * NULL means "a general acceptance that covers every paper" - the shape an
--     institution wants when its notice is one document for the whole exam
--     period, so a student accepts once instead of once per paper;
--   * no FK because this table is *evidence of what a person agreed to*. A
--     cascade from `exams` would let deleting a paper erase the acceptance that
--     was given to sit it - the same argument `attempt_review_logs` and
--     `session_reset_logs` make for keeping their ids as plain evidence. The id
--     is still the paper's id; it just outlives the row.
-- `student_id` *does* cascade from `profiles`: an account deletion is the one
-- path that is supposed to take the person's record with it.
create table if not exists public.proctoring_consents (
  id              uuid primary key default uuid_generate_v4(),
  student_id      uuid not null references public.profiles(id) on delete cascade,
  -- The paper this acceptance is for, or NULL for a general acceptance.
  exam_id         uuid,
  -- Which wording was displayed. Compared against
  -- `proctoring_consent_config.current_version` by `student_has_consent()`, so a
  -- row is never "consent to the notice" in the abstract - it is consent to a
  -- named version of it.
  consent_version text not null
                  check (length(btrim(consent_version)) between 1 and 64),
  -- Server time. Not a client timestamp: when a record of consent was given is
  -- exactly the kind of fact a device clock must not be able to move.
  accepted_at     timestamptz not null default now(),
  -- The transport's User-Agent, captured by `record_consent()`. Unbounded text on
  -- purpose - validated nowhere, because the only use is a human asking "was this
  -- the app or a desktop browser?" during an appeal.
  user_agent      text
);

comment on table public.proctoring_consents is
  'One row per acceptance of the proctoring consent notice: which version, for which paper (NULL = every paper), by whom, when, from what client. Written only by record_consent(); no update or delete path exists for an API caller.';

comment on column public.proctoring_consents.exam_id is
  'The paper this acceptance covers, or NULL for a general acceptance covering every paper. No foreign key: the record of consent outlives the paper it was given for.';

comment on column public.proctoring_consents.consent_version is
  'The notice version the client reported displaying. Only a row matching proctoring_consent_config.current_version satisfies student_has_consent().';

-- Two unique indexes rather than one constraint, because `exam_id` is nullable
-- and NULLs are distinct in a unique index: without the partial split a student
-- could accumulate any number of "general" rows, and `record_consent()` would
-- stop being idempotent exactly where it is hardest to notice.
create unique index if not exists proctoring_consents_exam_version_key
  on public.proctoring_consents (student_id, exam_id, consent_version)
  where exam_id is not null;

create unique index if not exists proctoring_consents_general_version_key
  on public.proctoring_consents (student_id, consent_version)
  where exam_id is null;

-- The lookup `student_has_consent()` performs, and the one an administrator makes
-- when an appeal asks "when did they accept?": newest first, per student.
create index if not exists proctoring_consents_student_accepted_idx
  on public.proctoring_consents (student_id, accepted_at desc);

alter table public.proctoring_consents enable row level security;

drop policy if exists "consents_insert_own" on public.proctoring_consents;
drop policy if exists "consents_select_own_or_supervisor" on public.proctoring_consents;

-- Accepting is the student's own act, in their own name: no row may be written
-- for somebody else. `student_id` is compared to `auth.uid()` and cannot be
-- supplied by the caller anyway (`record_consent()` writes `auth.uid()`), but the
-- policy states the rule at the row, where it holds for any future writer.
create policy "consents_insert_own"
  on public.proctoring_consents for insert
  to authenticated
  with check (student_id = auth.uid());

-- Read: the student's own acceptances and the intervention tier - the same
-- `is_exam_supervisor()` (admin + supervisor) that may act on an attempt. Not
-- `is_staff()`: a lecturer reads the evidence of a sitting (`proctoring_logs`,
-- the roster), while "did this person agree, and to what wording?" is a
-- supervisory/administrative question. Widening it later is an `alter policy`.
create policy "consents_select_own_or_supervisor"
  on public.proctoring_consents for select
  to authenticated
  using (
    student_id = auth.uid()
    or public.is_exam_supervisor()
  );

-- Select and insert only: no UPDATE, no DELETE - and no policy for either, so
-- the grant is not what stops a rewrite. Both halves are stated anyway. The
-- schema's default privileges (`grant_api_roles_public_schema.sql`) hand every
-- new table `all` to `authenticated`, so the grants are revoked explicitly here
-- rather than assumed absent: "there is no grant" should be a statement a reader
-- can check. `truncate` goes with them - it ignores RLS entirely.
-- `service_role` keeps full access for the institution's own erasure/export path.
revoke all on table public.proctoring_consents from anon;
revoke update, delete, truncate on table public.proctoring_consents from authenticated;
grant select, insert on table public.proctoring_consents to authenticated;
grant all on table public.proctoring_consents to service_role;


-- ---------------------------------------------------------------------
-- 3. "Has this student accepted the current notice for this paper?"
-- ---------------------------------------------------------------------
-- The predicate `submissions_insert_own_ongoing` now asks. Three terms, and each
-- one is load-bearing:
--   * `student_id = auth.uid()` - your own acceptance, never somebody else's;
--   * `consent_version = current` - consent to wording that has since been
--     replaced is not consent to the wording in force, which is the whole reason
--     the version is stored;
--   * `exam_id is null or exam_id = p_exam_id` - a general acceptance covers
--     every paper, an exam-scoped one covers exactly one.
--
-- SECURITY DEFINER with an explicit ownership term: the answer must not depend on
-- how tightly `consents_select_own_or_supervisor` is drawn, or a future
-- tightening of the read policy would silently start refusing attempts. The same
-- shape (and the same reason) as `student_can_access_exam()`.
create or replace function public.student_has_consent(p_exam_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.proctoring_consents c
     where c.student_id = auth.uid()
       and c.consent_version = public.current_proctor_consent_version()
       and (c.exam_id is null or c.exam_id = p_exam_id)
  );
$$;

comment on function public.student_has_consent(uuid) is
  'True when the caller has accepted the proctoring consent notice currently in force, either for this paper or as a general acceptance (exam_id NULL). False when no notice version is configured - fail-closed by design. Asked by submissions_insert_own_ongoing; it grants nothing else.';

revoke execute on function public.student_has_consent(uuid) from public, anon;
grant execute on function public.student_has_consent(uuid) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 4. Recording an acceptance (RPC)
-- ---------------------------------------------------------------------
--   * the caller is the student - `auth.uid()`, never a supplied id;
--   * the version is non-empty and is stored verbatim: it is the client's
--     statement of what it displayed, and a server that "corrected" it would be
--     writing a claim nobody made;
--   * an exam-scoped acceptance is only accepted for a paper the student may sit
--     (`student_can_access_exam()`), so a random uuid cannot be used to fill the
--     table;
--   * `user_agent` comes from the transport headers, not the body: a client can
--     lie in JSON, and the point of recording it is to be independent of the
--     client's account of itself;
--   * idempotent - a retry after a lost response returns the row that already
--     exists instead of a second one or a unique-violation the student cannot
--     act on;
--   * `is_current` tells the client whether the version it sent is the one in
--     force. `false` means "this build shows an older notice", which the consent
--     screen reports as "update the app" rather than letting the student accept
--     wording the institution has replaced and then be refused at the insert.
create or replace function public.record_consent(
  p_exam_id uuid default null,
  p_version text default null
)
returns table (
  consent_id      uuid,
  consent_version text,
  accepted_at     timestamptz,
  is_current      boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_student    uuid := auth.uid();
  v_version    text;
  v_user_agent text;
  v_id         uuid;
  v_accepted   timestamptz;
begin
  if v_student is null then
    raise exception 'Sign in before accepting the proctoring notice.'
      using errcode = '28000';
  end if;

  v_version := nullif(btrim(coalesce(p_version, '')), '');
  if v_version is null then
    raise exception 'The consent notice version is required.'
      using errcode = '22023';
  end if;
  if length(v_version) > 64 then
    raise exception 'The consent notice version is longer than 64 characters.'
      using errcode = '22023';
  end if;

  -- "May this student sit this paper at all?" is the same predicate the attempt
  -- policy asks, so an acceptance can never be stored for a paper the student has
  -- no access to. A general acceptance (no paper) skips the question.
  if p_exam_id is not null and not public.student_can_access_exam(p_exam_id) then
    raise exception 'That paper is not offered to you, so there is nothing to accept for it.'
      using errcode = '42501';
  end if;

  -- The transport's header, when there is one. Wrapped because
  -- `request.headers` is a PostgREST setting that a direct psql session does not
  -- have, and its absence must not fail an acceptance: this column is evidence,
  -- not a condition.
  begin
    v_user_agent := nullif(btrim(coalesce(
      (current_setting('request.headers', true)::jsonb) ->> 'user-agent', '')), '');
  exception
    when others then
      v_user_agent := null;
  end;

  -- The table is aliased (`as c`) and every name in the RETURNING list is
  -- qualified, because this function's own OUT parameters are `consent_id`,
  -- `consent_version`, `accepted_at` and `is_current`. PL/pgSQL resolves a bare
  -- column name in a SQL statement against the variables first, so an unqualified
  -- `accepted_at` in the RETURNING list is ambiguous between the column and the
  -- OUT parameter and the call fails at run time with
  --   42702  column reference "accepted_at" is ambiguous
  -- which no test could see: it only happens when the function is first executed.
  insert into public.proctoring_consents as c (
    student_id, exam_id, consent_version, user_agent
  )
  values (
    v_student, p_exam_id, v_version, v_user_agent
  )
  -- No conflict target on purpose: the two partial unique indexes above split on
  -- `exam_id is null`, and "swallow whichever one this row hit" is exactly the
  -- intent - either shape is already stored, once.
  on conflict do nothing
  returning c.id, c.accepted_at into v_id, v_accepted;

  if v_id is null then
    select c.id, c.accepted_at into v_id, v_accepted
      from public.proctoring_consents c
     where c.student_id = v_student
       and c.consent_version = v_version
       and c.exam_id is not distinct from p_exam_id
     order by c.accepted_at
     limit 1;
  end if;

  return query
    select v_id, v_version, v_accepted,
           v_version = public.current_proctor_consent_version();
end;
$$;

comment on function public.record_consent(uuid, text) is
  'Records the caller''s acceptance of the proctoring consent notice for one paper (or generally, when p_exam_id is NULL). Stores the version the client says it displayed plus the transport User-Agent, is idempotent, and reports is_current = false when the version sent is not the one in force. The only writer of public.proctoring_consents.';

revoke execute on function public.record_consent(uuid, text) from public, anon;
grant execute on function public.record_consent(uuid, text) to authenticated, service_role;


-- ---------------------------------------------------------------------
-- 5. The attempt policy: consent is now a condition of starting
-- ---------------------------------------------------------------------
-- Every check from `20261103090400_submissions_insert_own_ongoing.sql` is kept
-- verbatim - the ownership, the fresh-attempt shape, the cohort rule
-- (`student_can_access_exam()`), the schedule window - plus one arm:
--
--     and public.student_has_consent(exam_id)
--
-- This is the change that makes the consent screen a rule rather than a screen.
-- A dismissed dialog, a patched build or a hand-written POST now produce a 42501
-- and no attempt row, and the refusal appears in exactly the same place as every
-- other "you may not start this" refusal.
--
-- Safe to re-run: `drop policy if exists` + `create policy`. Narrowing only:
-- every insert that was refused before is still refused, and the only client that
-- can notice the new arm is one that was starting attempts without showing the
-- notice.
drop policy if exists "submissions_insert_own_ongoing" on public.exam_submissions;

create policy "submissions_insert_own_ongoing"
  on public.exam_submissions for insert
  to authenticated
  with check (
    student_id = auth.uid()
    and status = 'ongoing'
    and score is null
    and answers = '{}'::jsonb
    and submitted_at is null
    and started_at = now()
    and public.student_can_access_exam(exam_id)
    and public.student_has_consent(exam_id)
    and exists (
      select 1 from public.exams e
      where e.id = exam_id
        and (e.starts_at is null or now() >= e.starts_at)
        and (e.ends_at   is null or now() <= e.ends_at)
    )
  );

