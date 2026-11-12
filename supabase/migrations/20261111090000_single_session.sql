-- =====================================================================
-- PROCTORGUARD - ONE ACTIVE LOGIN PER ACCOUNT
-- The session claim, the record of every takeover, and the gate the five write
-- paths ask before they write.
--
-- WHY THIS FILE EXISTS
--   Supabase keeps every session it mints, and signing in somewhere else does not
--   end the session that came before. The Flutter client's `signOut()` is
--   `SignOutScope.local` (gotrue-dart 2.27.3), so the first device keeps a valid
--   access token; the auth server keeps no revocation list, so a JWT cannot be
--   withdrawn before `exp` - one hour by default. For that hour two devices can
--   write into one account's sitting: a student answering on a phone while somebody
--   else sits the same paper on a laptop, a violation arriving from a session
--   nobody is watching, and `submit_exam` closing the attempt from the device that
--   lost the account to the one still taking it.
--
--   A client can end the *other* session politely - `signOut(scope:
--   SignOutScope.others)` revokes its refresh token - and that is what this
--   release's app does, together with `claim_session()` on sign-in and an
--   `is_current_session()` check every 30 seconds and on resume. But the polite
--   half is only as reliable as the client running it, so the half that is
--   *enforced* is here: `public.active_sessions` keeps one row per account - the
--   one session that may write - and the five paths that write during a sitting ask
--   `public.is_current_session()` first.
--
-- WHAT CHANGES
--   1. `public.session_claim()` and `public.session_issued_at()` - the caller's own
--      `session_id` and `iat` claims, read from `request.jwt.claims`. Two small
--      helpers, so this file and every later gate read the same two values the same
--      way.
--   2. `public.active_sessions` - one row per account (`user_id` is the primary
--      key), holding the `session_id` that may write, the `iat` that won it, when
--      it was claimed, and the coarse device label. RLS: an account may read its own
--      row; there is deliberately no write policy, so `claim_session()` is the only
--      writer and a device cannot overwrite or delete its own claim through
--      PostgREST.
--   3. `public.session_supersessions` - one row per takeover, written by
--      `claim_session()` when a *different* session takes the account, with the
--      attempt that was open at that moment (`submission_id`, `exam_id`) when there
--      was one. Mirrors `session_reset_logs`: no foreign keys, because the row is
--      evidence that outlives the attempt it names. Read by the administrator, and
--      by the lecturer and the supervisor of the paper it names.
--   4. `public.claim_session(p_device_label)` - takes the claim for the calling
--      token and answers `(accepted, active_session_id, claimed_at,
--      replaced_session_id)`. A row rather than an exception for the losing side,
--      because losing is the normal outcome of signing in on a second device.
--   5. `public.is_current_session()` - "is this request from the session that
--      currently holds the account?". True when the row is absent, when the caller
--      has no `session_id` claim, or when the stored session is the caller's own;
--      false only when a row exists and names another session. Read by the five
--      paths below and by one INSERT policy.
--   6. The five write paths re-created with the gate, and nothing else about them
--      changed: `merge_submission_answer`, `merge_submission_text_answer`,
--      `submit_exam`, `register_violation`, `record_heartbeat`. Each refuses with
--      SQLSTATE `PT409` (a project's own code, not a standard one), so a client can
--      tell "another device signed in" from "the attempt closed" (`55000`) and from
--      "not yours" (`42501`).
--   7. `submissions_insert_own_ongoing` re-created with the gate, so a superseded
--      device cannot open a *second* attempt on the account while the first is
--      running - the shape of two people sitting one paper on two phones.
--
-- WHO WINS: the newest token, ordered by `iat` - `claim_session()` compares it and
-- refuses a claim older than the one held, so a restored tab or a resumed app cannot
-- take an account back.
--
-- WHAT IT DOES NOT DO
--   * It does not revoke a token, and it does not touch `auth.*`. Nothing in this
--     schema can make an access token stop being *valid*; what it can do is refuse
--     to act on one that a newer sign-in replaced. The window is narrowed to "until
--     the losing client asks", not closed to zero.
--   * It does not gate reads. A superseded device can still read its attempt until
--     its token expires. Gating reads would break the monitor, the marking queue and
--     every other console read in the deployment for a case the client already
--     handles (it signs that device out).
--   * It does not gate the snapshot upload. That is a storage policy on
--     `storage.objects`, which cannot see `active_sessions`; an upload already
--     started completes.
--   * It does not lock anybody out. An account with no claim row - a client older
--     than this file, a client that was offline at claim time, the SQL editor, the
--     `service_role` key - is treated as current, because nothing exists to
--     contradict it. That is deliberate: a store build that has not updated must
--     keep working, and the gate is an improvement, not a cliff.
--   * It does not stop a patched client that never claims. The gate compares a token
--     with a token; a client that stops calling `claim_session()` leaves no row and
--     is let through. What changes is that the *shipped* app cannot leave two live
--     sessions behind, and `session_supersessions` records every takeover it does
--     make.
--   * It does not backfill. Nothing is claimed until an account signs in with this
--     release, so the file can be applied during the day without a maintenance
--     window.
--
-- PREREQUISITES
--   * `supabase/schema.sql` as of `20261110090200_supervisor_profile_read.sql`:
--     `public.profiles`, `public.is_admin()`, `public.owns_exam(uuid)`,
--     `public.can_supervise_exam(uuid)`, `public.exams`, `public.exam_submissions`
--     and the `submissions_insert_own_ongoing` policy this file re-creates. The
--     VERIFY block at the end raises by name if one of them is missing.
--   * Order: after every other migration in the repository. This file re-creates
--     five functions and one policy; any later file that re-creates one of them must
--     carry the gate in it, and this file is the reference for that gate.
--
-- HOW TO APPLY
--   SQL Editor (paste the whole file, Run), or through the CLI:
--     supabase db query --linked -f supabase/migrations/20261111090000_single_session.sql
--   Then `supabase/tests/single_session_check.sql` passes.
--
-- VERIFY (by hand, before and after - the block at the end raises if the result is
-- wrong, so this is for reading, not for passing):
--     -- 1. the two tables
--     select user_id, session_id, issued_at, device_label, claimed_at
--       from public.active_sessions order by claimed_at desc;
--     select user_id, previous_session_id, new_session_id, exam_id, superseded_at
--       from public.session_supersessions order by superseded_at desc limit 20;
--     -- 2. the two RPCs answer as an account, not as the editor
--     select public.session_claim(), public.session_issued_at();  -- null, null
--     select * from public.claim_session('sql-editor');           -- raises 28000
--     -- 3. the gate is in every write path (five rows, each saying true)
--     select p.proname, p.prosrc like '%is_current_session%' as gated
--       from pg_proc p
--      where p.pronamespace = 'public'::regnamespace
--        and p.proname in ('merge_submission_answer','merge_submission_text_answer',
--                          'submit_exam','register_violation','record_heartbeat')
--      order by 1;
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. THE CLAIM, THE TABLE IT LIVES IN, AND THE AUDIT
-- ---------------------------------------------------------------------
-- Exactly as `supabase/schema.sql` section 1b has them - the two copies are pinned
-- against each other by `mobile/test/schema_contract_test.dart`, so an edit here
-- without the same edit there fails the build. `create ... if not exists`
-- throughout, so re-running this file on a project that already has them is a no-op
-- rather than an error.

create or replace function public.session_claim()
returns text
language sql
stable
as $$
  select nullif(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id',
    ''
  )
$$;

comment on function public.session_claim() is
  'The session_id claim of the request''s own access token - the auth.sessions row the token was minted for - or null when the request carries no token (SQL editor, migration, service_role). It reads nothing but the request''s own claims.';

revoke execute on function public.session_claim() from public, anon;
grant execute on function public.session_claim() to authenticated, service_role;

create or replace function public.session_issued_at()
returns timestamptz
language sql
stable
as $$
  select to_timestamp(
    nullif(
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'iat',
      ''
    )::bigint
  )
$$;

comment on function public.session_issued_at() is
  'The iat claim of the request''s own access token as a timestamptz - when this sign-in happened, which is what orders two devices on one account - or null when the request carries no token.';

revoke execute on function public.session_issued_at() from public, anon;
grant execute on function public.session_issued_at() to authenticated, service_role;

-- The claim itself: one row per account, holding the one session that may write.
-- A row is created by the account's first `claim_session()` and replaced - never
-- stacked - by every sign-in after it, so `user_id` is the primary key and there is
-- no way for two rows to disagree. `issued_at` is the winning token's `iat`, which
-- is what a later claim is compared against; `device_label` is the coarse platform
-- name the app sends (`android`, `ios`, `web`, ...) and exists so a supervisor
-- reading `session_supersessions` can tell a phone from a lab desktop.
create table if not exists public.active_sessions (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  session_id   text not null,
  issued_at    timestamptz not null,
  device_label text,
  claimed_at   timestamptz not null default now()
);

alter table public.active_sessions enable row level security;

-- Read your own row (the app shows nothing of it, but a client may ask), and no
-- write policy at all: `claim_session()` is `security definer` and is the only
-- writer, so a device cannot overwrite or delete its own claim with a PostgREST
-- call and talk its way past the gate.
drop policy if exists "active_sessions_select_own" on public.active_sessions;
create policy "active_sessions_select_own"
  on public.active_sessions for select
  to authenticated
  using (user_id = auth.uid());

-- The audit: one row per takeover, written by `claim_session()` when a *different*
-- session takes an account's claim. Mirrors `session_reset_logs` - no foreign
-- keys, because the row is evidence: deleting the attempt, the paper or the account
-- afterwards must not delete the record that two logins happened, and
-- `submission_id` is there to answer the question a supervisor actually asks ("did
-- the second login happen while the paper was open?"). Rows with no attempt running
-- are kept too: they still say when an account changed hands.
create table if not exists public.session_supersessions (
  id                  uuid primary key default uuid_generate_v4(),
  user_id             uuid not null,
  previous_session_id text not null,
  new_session_id      text not null,
  submission_id       uuid,
  exam_id             uuid,
  device_label        text,
  superseded_at       timestamptz not null default now()
);

alter table public.session_supersessions enable row level security;

-- The administrator reads the whole record; a lecturer and a supervisor read the
-- rows that bear on a paper they run, through the same two predicates every other
-- staff read uses. A student reads none of it - their own rows included - because
-- the table exists to tell *staff* what a login did, and `claim_session()` already
-- told the student, on the device that lost the session.
drop policy if exists "session_supersessions_select_staff" on public.session_supersessions;
create policy "session_supersessions_select_staff"
  on public.session_supersessions for select
  to authenticated
  using (
    public.is_admin()
    or public.can_supervise_exam(exam_id)
    or public.owns_exam(exam_id)
  );

create index if not exists idx_session_supersessions_user_id
  on public.session_supersessions(user_id, superseded_at desc);
create index if not exists idx_session_supersessions_exam_id
  on public.session_supersessions(exam_id);

-- Take the account's claim for the session that is calling. Called once per
-- sign-in (see `SupabaseService.claimSession`), and again harmlessly whenever the
-- app checks in: a repeat from the *same* session is a no-op that keeps the
-- original `claimed_at`, so that value means "when this device took the account".
--
-- The answer is a row rather than an exception for the losing side, because losing
-- is not an error - it is the normal outcome of signing in on a second device, and
-- the client turns `accepted = false` into a sign-out with a message.
create or replace function public.claim_session(
  p_device_label text default null
)
returns table (
  accepted            boolean,
  active_session_id   text,
  claimed_at          timestamptz,
  replaced_session_id text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user       uuid := auth.uid();
  v_session    text := public.session_claim();
  v_issued     timestamptz;
  v_prev       public.active_sessions;
  v_submission uuid;
  v_exam       uuid;
begin
  if v_user is null then
    raise exception 'claim_session: sign in before claiming a session'
      using errcode = '28000',
            hint = 'this RPC is called with a signed-in access token; the SQL editor and the service_role key carry none';
  end if;

  if v_session is null then
    raise exception 'claim_session: this request carries no session_id claim'
      using errcode = '22023',
            hint = 'the token must come from a password or magic-link sign-in; an older auth server may not mint session_id';
  end if;

  -- `iat` is missing only on a token this server did not mint. `now()` is then the
  -- best ordering available, and it still keeps "the later claim wins" monotonic
  -- for that one device.
  v_issued := coalesce(public.session_issued_at(), now());

  select a.* into v_prev
    from public.active_sessions a
   where a.user_id = v_user
     for update;

  if v_prev.user_id is not null then
    if v_prev.session_id = v_session then
      -- The same session asking again: an app restart, a reconnect, the liveness
      -- check. Keep the moment it took the account and refresh the label.
      update public.active_sessions
         set device_label = coalesce(p_device_label, active_sessions.device_label)
       where user_id = v_user;

      return query select true, v_session, v_prev.claimed_at, null::text;
      return;
    end if;

    -- A superseded device coming back. Its token is older than the one already
    -- held, so it is refused - otherwise a restored tab or a resumed app would take
    -- the account back the moment it woke up, and "newest wins" would mean "last to
    -- call wins".
    if v_prev.issued_at > v_issued then
      -- Nothing was replaced, so the fourth column says so: the session that lost is
      -- the caller's own, and it already knows which one that is.
      return query select false, v_prev.session_id, v_prev.claimed_at, null::text;
      return;
    end if;
  end if;

  insert into public.active_sessions (user_id, session_id, issued_at, device_label, claimed_at)
  values (v_user, v_session, v_issued, p_device_label, now())
  on conflict (user_id) do update
    set session_id   = excluded.session_id,
        issued_at    = excluded.issued_at,
        device_label = coalesce(excluded.device_label, public.active_sessions.device_label),
        claimed_at   = now();

  -- A takeover, not a first claim: record it, with the attempt that was open at
  -- that moment, if there was one. `submission_id` is not a foreign key, so this row
  -- survives the reset that clears the attempt.
  if v_prev.user_id is not null and v_prev.session_id <> v_session then
    select s.id, s.exam_id into v_submission, v_exam
      from public.exam_submissions s
     where s.student_id = v_user
       and s.status = 'ongoing'
     order by s.started_at desc
     limit 1;

    insert into public.session_supersessions (
      user_id, previous_session_id, new_session_id, submission_id, exam_id, device_label
    ) values (
      v_user, v_prev.session_id, v_session, v_submission, v_exam, p_device_label
    );
  end if;

  return query select true, v_session, now(), v_prev.session_id;
end;
$$;

comment on function public.claim_session(text) is
  'Takes the account''s single active session for the caller''s own token and answers (accepted, active_session_id, claimed_at, replaced_session_id). A different session wins only if its iat is newer than the stored one, so a superseded device replaying an older token is refused; a repeat from the winning session is a no-op that keeps claimed_at. security definer, serialised on the account row, and the only writer of active_sessions.';

revoke execute on function public.claim_session(text) from public, anon;
grant execute on function public.claim_session(text) to authenticated, service_role;

-- "Is this request coming from the session that currently holds the account?"
--
-- Yes for the holder; yes for a caller with no claim row, which is how an account
-- that has never claimed - an older client, a client that was offline at claim
-- time, the SQL editor, a migration, the service_role key - keeps working exactly as
-- it did before this section existed; yes for a token with no `session_id` claim, for
-- the same reason. Only "a row exists and it names another session" answers false,
-- and that is the one case this section exists to refuse.
--
-- `security definer` so the answer does not depend on the read policy above, and
-- `stable` so it may be folded once per statement - which is also why it is not a
-- cache: a statement that began before a takeover can still see the pre-takeover
-- row, and the next statement cannot.
create or replace function public.is_current_session()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (
      select public.session_claim() is null
          or a.session_id = public.session_claim()
        from public.active_sessions a
       where a.user_id = auth.uid()
    ),
    true
  )
$$;

comment on function public.is_current_session() is
  'True unless a sign-in newer than this token holds the account: the claim row is absent, or this request carries no session_id claim, or the stored session_id is the caller''s own. Read by the five gated write paths and by submissions_insert_own_ongoing.';

revoke execute on function public.is_current_session() from public, anon;
grant execute on function public.is_current_session() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2. THE FIVE WRITE PATHS, RE-CREATED WITH THE GATE
-- ---------------------------------------------------------------------
-- Whole bodies, not a patch: `create or replace function` installs the statement it
-- is given. The gate is the block asking `public.is_current_session()` directly after
-- the `auth.uid() is null` check, so it runs before any ownership or status work and
-- the caller learns `PT409` rather than a message about an attempt that is, in fact,
-- theirs.
--
-- Nothing else in these five functions changed. Their grants are untouched too -
-- `create or replace` preserves the ACL - so there is nothing to re-`grant` here.
create or replace function public.register_violation(
  p_submission_id    uuid,
  p_action_type      text,
  p_snapshot_url     text default null,
  p_client_timestamp timestamptz default null,
  p_client_event_id  uuid default null
)
returns table(warning_count int, disqualified boolean, flagged boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  -- The bar, in weighted points. Three, because every seeded hard type weighs 1:
  -- "any three hard signals" is the rule this replaces for the signals that
  -- deserve it, and a soft type at weight 0 can never reach it alone. This is the
  -- one number to change if an institution wants a stricter or looser ceiling -
  -- changing a *type's* contribution does not need a migration at all (README,
  -- "Tuning the violation weights").
  c_flag_threshold constant int := 3;

  v_count  int;
  v_status text;
  v_snapshot_path text;
  v_weighted int;
begin

  if auth.uid() is null then
    raise exception 'authentication is required to register a violation'
      using errcode = '42501';
  end if;

  -- One active login per account (section 1b). A device whose session a newer
  -- sign-in replaced may not keep writing evidence: the client signs itself out
  -- when `is_current_session()` turns false, and this is the half a client that
  -- never asks cannot skip. `PT409` is the code the app reads as "another device
  -- signed in" rather than as a failed write.
  if not public.is_current_session() then
    raise exception 'register_violation: this session was replaced by a newer sign-in'
      using errcode = 'PT409',
            hint = 'sign in again; only the most recent sign-in on an account may write';
  end if;

  -- SECURITY DEFINER is required here (a student may neither insert into
  -- proctoring_logs nor update exam_submissions), which is exactly why the
  -- function has to re-check who is asking: without this guard any signed-in
  -- account could disqualify a classmate by calling the RPC with their
  -- submission id.
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

  -- Frames that arrive after the attempt closed (submitted, under review, or
  -- already disqualified) must not append more evidence or resurrect the session:
  -- report the final state instead of raising, so a late callback is harmless.
  -- `flagged` is read from the stored status, so a client that missed the ruling
  -- still learns the attempt is under review.
  if v_status <> 'ongoing' then
    select count(*) into v_count
    from public.proctoring_logs
    where submission_id = p_submission_id;
    return query select v_count, (v_status = 'disqualified'),
                        (v_status = 'flagged_for_review');
    return;
  end if;

  -- `on conflict` + the unique index on client_event_id is what makes the
  -- client's offline retry safe: the same event replayed inserts nothing, and the
  -- strike count below is read from the table, so a retry can never turn one
  -- violation into two strikes. A client that reuses an id on purpose only
  -- suppresses its own strike - and a client that controls the app can skip
  -- calling this at all, so the idempotency key costs the rule nothing.
  --
  -- Only THIS attempt's own snapshot object is stored, and only in the exact
  -- shape `SupabaseService.snapshotPath()` mints:
  --     <p_submission_id>/<action_type>_<epoch-ms>.(jpg|png)
  -- `[a-z_]+` is the action_type vocabulary (every member is lowercase ASCII and
  -- underscores), `[0-9]+` is the epoch-millisecond stamp, and the two extensions
  -- are the only mime types the bucket accepts (section 6). Everything else is
  -- stored as NULL, because each rejected shape is a hole of its own:
  --   * another submission's folder - evidence poisoning (an incident of *this*
  --     sitting that shows somebody else's face, on which an appeal is judged) and
  --     a delete-by-proxy (a reset reads these paths back and removes the objects
  --     they name);
  --   * a path outside the bucket, a full URL (the shape a build that predates the
  --     private bucket wrote), a traversal such as `<own id>/../../other` - none of
  --     them addresses a still of this attempt;
  --   * a folder-shaped name this app never minted (`<own id>/evidence.jpg`,
  --     `<own id>/nested/x.jpg`, `<own id>/x_1.gif`) - what a patched client would
  --     send to park an arbitrary object where a reviewer believes a snapshot of
  --     this student is.
  -- A `~` on NULL yields NULL, which takes the `else` arm, so a missing path stays
  -- missing. Storing NULL rather than raising is deliberate: a malformed path must
  -- not buy a strike back - the incident is the fact, the photograph is the
  -- optional attachment.
  v_snapshot_path := case
    when p_snapshot_url ~ ('^' || p_submission_id::text || '/[a-z_]+_[0-9]+\.(jpg|png)$')
      then p_snapshot_url
    else null
  end;

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

  -- The weighted score for the whole attempt, recomputed from the stored rows -
  -- never an increment. A replayed `client_event_id` inserts nothing, a retried
  -- delivery inserts nothing, and a queue replayed twice must arrive at exactly the
  -- same number as the evidence actually held.
  --
  -- `left join` + coalesce is the fail-closed shape: a row whose action_type has no
  -- weight yet scores one point, so widening the check constraint (section 5) can
  -- never hand out a free signal. `counts_toward_dq` gates the point, so a soft
  -- type contributes 0 even if somebody later gives it a weight.
  select coalesce(sum(
           case
             when coalesce(w.counts_toward_dq, true) then coalesce(w.weight, 1)
             else 0
           end
         ), 0)::int
    into v_weighted
  from public.proctoring_logs l
  left join public.violation_weights w on w.action_type = l.action_type
  where l.submission_id = p_submission_id;

  if v_weighted >= c_flag_threshold then
    -- The sitting stops, but nobody has decided anything: `flagged_for_review`
    -- means "a person must look at this", and `resolve_flagged_attempt()` below is
    -- that person. `submitted_at` is written once - a replayed call keeps the
    -- original close time - and `score` is cleared because marking does not start
    -- until the review ends.
    update public.exam_submissions
       set status = 'flagged_for_review',
           submitted_at = coalesce(submitted_at, now()),
           score = null
     where id = p_submission_id
       and status = 'ongoing';
    return query select v_count, false, true;
    return;
  end if;

  return query select v_count, false, false;
end;
$$;

create or replace function public.record_heartbeat(
  p_submission_id   uuid,
  p_camera_ok       boolean     default true,
  p_monitoring_ok   boolean     default true,
  p_app_version     text        default null,
  p_client_time     timestamptz default null,
  p_client_event_id uuid        default null
)
returns table (
  -- 'recorded' | 'duplicate' | 'throttled'. Not an error for the last two: the
  -- client's job is to keep the beat going, not to negotiate about one.
  outcome     text,
  recorded_at timestamptz,
  beat_count  int
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- The client beats every 15s (mobile: ProctoringHeartbeatService). The window is
  -- deliberately *shorter* than that so an honest client is never throttled by
  -- jitter, while a script hammering the RPC still cannot write a thousand rows a
  -- second.
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

  -- One active login per account (section 1b): a superseded device stops keeping
  -- the monitor's coverage green, which is the point of gating this RPC. The client
  -- signs itself out on the same condition; the refusal is for a client that does
  -- not ask.
  if not public.is_current_session() then
    raise exception 'record_heartbeat: this session was replaced by a newer sign-in'
      using errcode = 'PT409',
            hint = 'sign in again; only the most recent sign-in on an account may write';
  end if;

  -- `for update` serialises two beats that arrive together, so the rate-limit
  -- read below cannot be raced into writing two rows inside one window.
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

  -- A closed attempt cannot report for duty. Accepting these would let an ended
  -- (or flagged) sitting keep its coverage looking healthy after the fact.
  if v_sub.status <> 'ongoing' then
    raise exception 'record_heartbeat: attempt % is %, not ongoing', p_submission_id, v_sub.status
      using errcode = '22023';
  end if;

  select count(*) into v_count
  from public.proctor_heartbeats h
  where h.submission_id = p_submission_id;

  -- Idempotency first: a replay of a beat that is already stored is not "too
  -- early", it is already done.
  if p_client_event_id is not null then
    select h.received_at into v_last
    from public.proctor_heartbeats h
    where h.client_event_id = p_client_event_id;

    if v_last is not null then
      -- Still refresh liveness: the client is talking to us *now*, whatever the
      -- beat it replayed was about.
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

  -- The insert may have been swallowed by the unique index if two deliveries of
  -- the same beat raced; either way the attempt is alive and the series holds one
  -- row, so both answers are honest.
  -- `count(*)` is bigint and `beat_count` is int: a RETURN QUERY is checked
  -- against the declared row type exactly (no assignment cast, unlike
  -- `select ... into`), so the cast is what keeps the RPC from failing with
  -- "Returned type bigint does not match expected type integer in column 3".
  return query select
    case when v_first is null then 'duplicate' else 'recorded' end,
    coalesce(v_first, v_now),
    (select count(*)::integer from public.proctor_heartbeats h
      where h.submission_id = p_submission_id);
end;
$$;

create or replace function public.merge_submission_answer(
  p_submission_id uuid,
  p_question_id uuid,
  p_selected_option int
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication is required to save an exam answer'
      using errcode = '42501';
  end if;

  -- One active login per account (section 1b): the device that lost the account may
  -- not keep saving into the attempt. `PT409` rather than `55000`, so the client can
  -- tell "another device signed in" from "the attempt closed".
  if not public.is_current_session() then
    raise exception 'merge_submission_answer: this session was replaced by a newer sign-in'
      using errcode = 'PT409',
            hint = 'sign in again; only the most recent sign-in on an account may write';
  end if;

  update public.exam_submissions as s
  set answers = jsonb_set(
        coalesce(s.answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(p_selected_option),
        true
      )
  where s.id = p_submission_id
    and s.student_id = auth.uid()
    and s.status = 'ongoing'
    and exists (
      select 1
      from public.exams e
      where e.id = s.exam_id
        -- The paper's own close is a hard close: an answer that arrives after
        -- `ends_at` is refused even while the attempt's duration has time left.
        and clock_timestamp() < public.attempt_deadline(
          s.started_at, e.duration_minutes, e.ends_at
        )
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;

create or replace function public.submit_exam(
  p_submission_id uuid,
  p_disqualified  boolean default false
)
returns table(result_status text, final_score numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_student uuid;
  v_exam    uuid;
  v_status  text;
  v_started_at timestamptz;
  v_duration_minutes int;
  v_ends_at timestamptz;
  v_submitted_at timestamptz;
  v_score   numeric;
begin
  if auth.uid() is null then
    raise exception 'authentication is required to submit an exam'
      using errcode = '42501';
  end if;

  -- One active login per account (section 1b). Closing the attempt is the write a
  -- superseded device must not make: submitting is idempotent, so a late replay
  -- would otherwise succeed silently and lock the account that *is* signed in out of
  -- its own sitting. `PT409` tells the client to sign in again, not to retry.
  if not public.is_current_session() then
    raise exception 'submit_exam: this session was replaced by a newer sign-in'
      using errcode = 'PT409',
            hint = 'sign in again; only the most recent sign-in on an account may write';
  end if;

  select s.student_id, s.exam_id, s.status, s.started_at,
         e.duration_minutes, e.ends_at
    into v_student, v_exam, v_status, v_started_at,
         v_duration_minutes, v_ends_at
  from public.exam_submissions s
  join public.exams e on e.id = s.exam_id
  where s.id = p_submission_id
  for update of s;

  if v_student is null then
    raise exception 'submission % does not exist', p_submission_id
      using errcode = 'P0002';
  end if;

  if v_student <> auth.uid() and not public.can_supervise_exam(v_exam) then
    raise exception 'submission % does not belong to the caller', p_submission_id
      using errcode = '42501';
  end if;

  -- Already closed: report the stored outcome (retry-safe).
  if v_status <> 'ongoing' then
    return query
      select s.status, s.score
      from public.exam_submissions s
      where s.id = p_submission_id;
    return;
  end if;

  -- Expired attempts are closed and graded from answers saved before the
  -- deadline. Record the deadline as the effective submit time for late closes:
  -- `attempt_deadline()` is the attempt's own duration capped by the paper's
  -- close, so a late arrival inside a scheduled window records the window's end.
  v_submitted_at := least(
    clock_timestamp(),
    public.attempt_deadline(v_started_at, v_duration_minutes, v_ends_at)
  );

  -- A disqualified attempt is never graded: a score would imply it counts.
  if p_disqualified then
    update public.exam_submissions
    set status = 'disqualified', submitted_at = now(), score = null
    where id = p_submission_id;

    return query select 'disqualified'::text, null::numeric;
    return;
  end if;

  -- Grading is a sum of `questions.points` over the questions the student got
  -- right, and it has to cover every automatically graded shape:
  --   * multiple choice: the stored jsonb number equals `correct_option`
  --   * true/false and fill in the blank: the stored jsonb string matches
  --     `correct_text_answer` case-insensitively after trimming, so "  http "
  --     counts for "HTTP" and "TRUE" counts for "true"
  -- A 'subjective' row never matches: it has no key, and its marks arrive later
  -- through `grade_submission()` after a person read it. An unanswered question
  -- stores nothing, so `->>` is NULL and the comparison is NULL (never true) - it
  -- simply does not score.
  --
  -- The sum itself lives in `auto_graded_score()` so this close and a later
  -- `grade_submission()` cannot drift apart about which answers count.
  v_score := public.auto_graded_score(p_submission_id);

  update public.exam_submissions
  set status = 'submitted', submitted_at = v_submitted_at, score = v_score
  where id = p_submission_id;

  return query select 'submitted'::text, v_score;
end;
$$;

create or replace function public.merge_submission_text_answer(
  p_submission_id uuid,
  p_question_id   uuid,
  p_answer        text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication is required to save an exam answer'
      using errcode = '42501';
  end if;

  -- One active login per account (section 1b) - the free-text twin of the option
  -- merge above, and refused the same way.
  if not public.is_current_session() then
    raise exception 'merge_submission_text_answer: this session was replaced by a newer sign-in'
      using errcode = 'PT409',
            hint = 'sign in again; only the most recent sign-in on an account may write';
  end if;

  update public.exam_submissions as s
  set answers = jsonb_set(
        coalesce(s.answers, '{}'::jsonb),
        array[p_question_id::text],
        to_jsonb(left(coalesce(p_answer, ''), 2000)),
        true
      )
  where s.id = p_submission_id
    and s.student_id = auth.uid()
    and s.status = 'ongoing'
    and exists (
      select 1
      from public.exams e
      where e.id = s.exam_id
        -- Same deadline as the option merge: whichever comes first, the
        -- attempt's duration or the paper's close.
        and clock_timestamp() < public.attempt_deadline(
          s.started_at, e.duration_minutes, e.ends_at
        )
    );

  if not found then
    raise exception 'submission is not active or its exam deadline has passed'
      using errcode = '55000';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. THE START ROW, GATED
-- ---------------------------------------------------------------------
-- The one write during a sitting that is not an RPC, re-created with the gate as a
-- fourth question beside "is it your paper", "is it open" and "did you accept the
-- notice": a superseded device must not be able to open a *second* attempt on the
-- account while the first is still running.
--
-- The `drop` is here, unlike the five functions above, because `create policy` has no
-- `or replace`: without it a second run of this file would stop at "policy already
-- exists" and the VERIFY block would never be reached.
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
    and public.is_current_session()
    and exists (
      select 1 from public.exams e
      where e.id = exam_id
        and (e.starts_at is null or now() >= e.starts_at)
        and (e.ends_at  is null or now() <= e.ends_at)
    )
  );

-- ---------------------------------------------------------------------
-- 4. VERIFY
-- ---------------------------------------------------------------------
-- Reads the catalogue rather than this file, so it states what the *server* will do.
-- Raises on the first thing that is wrong, by name, instead of reporting success.
do $verify$
declare
  v_missing text;
  v_src     text;
  v_qual    text;
  v_check   text;
  v_row     record;
begin
  -- The two tables exist and have row level security on. A table created by hand on
  -- an older project can exist without it, and everything below would still install
  -- while the policies were consulted by nobody.
  if to_regclass('public.active_sessions') is null then
    raise exception 'FAIL: public.active_sessions does not exist';
  end if;
  if to_regclass('public.session_supersessions') is null then
    raise exception 'FAIL: public.session_supersessions does not exist';
  end if;

  select string_agg(c.relname, ', ') into v_missing
  from pg_class c
  where c.oid in ('public.active_sessions'::regclass,
                  'public.session_supersessions'::regclass)
    and not c.relrowsecurity;
  if v_missing is not null then
    raise exception 'FAIL: row level security is off on % - the policies in this file would be consulted by nobody', v_missing;
  end if;

  -- The claim's shape: one row per account, and the four values the RPC agrees on.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.active_sessions'::regclass
       and contype = 'p'
       and conkey = array[
         (select attnum from pg_attribute
           where attrelid = 'public.active_sessions'::regclass and attname = 'user_id')
       ]::smallint[]
  ) then
    raise exception 'FAIL: public.active_sessions has no primary key on user_id - two rows could then disagree about which session may write';
  end if;

  select string_agg(a.attname, ', ' order by a.attname)
    into v_missing
  from pg_attribute a
  where a.attrelid = 'public.active_sessions'::regclass
    and a.attnum > 0 and not a.attisdropped
    and a.attname in ('user_id', 'session_id', 'issued_at', 'device_label', 'claimed_at')
    and a.attnum not in (0);
  if v_missing is distinct from 'claimed_at, device_label, issued_at, session_id, user_id' then
    raise exception 'FAIL: public.active_sessions columns are % - expected claimed_at, device_label, issued_at, session_id, user_id', coalesce(v_missing, 'none');
  end if;

  -- The audit survived a hostile history: no cascade from the attempt it names.
  if exists (
    select 1 from pg_constraint
     where conrelid = 'public.session_supersessions'::regclass
       and contype = 'f'
  ) then
    raise exception 'FAIL: public.session_supersessions has a foreign key - a reset or a deleted account would take the takeover record with it';
  end if;
  -- The two claims read the request's own token, not a table.
  if (select count(*) from pg_proc
       where pronamespace = 'public'::regnamespace
         and proname in ('session_claim', 'session_issued_at')) <> 2 then
    raise exception 'FAIL: session_claim()/session_issued_at() are missing - create them from schema.sql section 1b';
  end if;

  for v_row in
    select p.proname, p.prosrc
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('session_claim', 'session_issued_at')
  loop
    if v_row.prosrc not like '%request.jwt.claims%' then
      raise exception 'FAIL: public.%() does not read request.jwt.claims - it cannot see the caller''s token', v_row.proname;
    end if;
  end loop;

  -- claim_session(): a definer function that locks the row, refuses an older token,
  -- and writes the audit.
  select p.prosrc into v_src
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'claim_session'
    and p.pronargs = 1;
  if v_src is null then
    raise exception 'FAIL: public.claim_session(text) does not exist';
  end if;
  if not exists (
    select 1 from pg_proc
     where pronamespace = 'public'::regnamespace and proname = 'claim_session'
       and pronargs = 1 and prosecdef
  ) then
    raise exception 'FAIL: claim_session() is not security definer - a client cannot write active_sessions itself';
  end if;
  if v_src not like '%for update%' then
    raise exception 'FAIL: claim_session() no longer locks the account row - two devices claiming at once could both be told they won';
  end if;
  if v_src not like '%issued_at > v_issued%' then
    raise exception 'FAIL: claim_session() no longer refuses an older token - a superseded device could take the account back';
  end if;
  if v_src not like '%insert into public.session_supersessions%' then
    raise exception 'FAIL: claim_session() no longer records a takeover in session_supersessions';
  end if;

  -- is_current_session(): reads the claim, and fails open for an account that has
  -- never claimed (the coalesce is the whole compatibility story).
  select p.prosrc into v_src
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = 'is_current_session';
  if v_src is null then
    raise exception 'FAIL: public.is_current_session() does not exist';
  end if;
  if v_src not like '%active_sessions%' or v_src not like '%session_claim%' then
    raise exception 'FAIL: is_current_session() does not compare the caller''s session_id with the claim';
  end if;
  if v_src not like '%coalesce%' then
    raise exception 'FAIL: is_current_session() lost its fail-open default - an account that never claimed would be locked out of its own sitting';
  end if;

  -- The gate, in all five write paths.
  for v_row in
    select p.proname, p.prosrc
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('merge_submission_answer', 'merge_submission_text_answer',
                        'submit_exam', 'register_violation', 'record_heartbeat')
  loop
    if v_row.prosrc not like '%public.is_current_session()%' then
      raise exception 'FAIL: public.%() does not ask is_current_session() - a superseded device can still write through it', v_row.proname;
    end if;
    if v_row.prosrc not like '%PT409%' then
      raise exception 'FAIL: public.%() refuses without the PT409 code - a client cannot tell a takeover from a closed attempt', v_row.proname;
    end if;
  end loop;
  if (select count(*) from pg_proc
       where pronamespace = 'public'::regnamespace
         and proname in ('merge_submission_answer', 'merge_submission_text_answer',
                         'submit_exam', 'register_violation', 'record_heartbeat')) <> 5 then
    raise exception 'FAIL: one of the five gated write paths is missing entirely';
  end if;
  -- The start row and the two read policies.
  select with_check into v_check
  from pg_policies
  where schemaname = 'public'
    and tablename = 'exam_submissions'
    and policyname = 'submissions_insert_own_ongoing';
  if v_check is null then
    raise exception 'FAIL: submissions_insert_own_ongoing does not exist - no student could start an attempt at all';
  end if;
  if v_check not like '%is_current_session%' then
    raise exception 'FAIL: submissions_insert_own_ongoing does not ask is_current_session() - a superseded device can open a second attempt';
  end if;
  if v_check not like '%student_has_consent%' or v_check not like '%student_can_access_exam%' then
    raise exception 'FAIL: submissions_insert_own_ongoing lost one of its other questions (consent or paper access) - re-apply it from schema.sql, do not hand-edit it here';
  end if;

  select qual into v_qual
  from pg_policies
  where schemaname = 'public'
    and tablename = 'session_supersessions'
    and policyname = 'session_supersessions_select_staff';
  if v_qual is null then
    raise exception 'FAIL: session_supersessions_select_staff is missing - the takeover record would be readable by nobody but the SQL editor';
  end if;
  if v_qual not like '%can_supervise_exam%' or v_qual not like '%owns_exam%' then
    raise exception 'FAIL: session_supersessions_select_staff is not scoped by the paper (% ) - the record of who signed in where is not a deployment-wide read', v_qual;
  end if;

  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'active_sessions' and cmd = 'SELECT'
  ) then
    raise exception 'FAIL: active_sessions has no read policy - an account cannot read its own claim';
  end if;
  if exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'active_sessions'
       and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) then
    raise exception 'FAIL: active_sessions has a write policy - a device could overwrite or delete its own claim and talk its way past the gate';
  end if;

  raise notice 'single session installed: active_sessions holds one claim per account, claim_session() is its only writer, and the five write paths (plus submissions_insert_own_ongoing) refuse a replaced session with PT409';
end $verify$;



