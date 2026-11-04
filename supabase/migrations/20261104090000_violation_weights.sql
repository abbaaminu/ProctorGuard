-- =====================================================================
-- PROCTORGUARD - VIOLATION WEIGHTS: NOT EVERY STRIKE IS A BRICK
-- Creates `public.violation_weights`, the server-side answer to "how much does
-- this signal count towards disqualification?", and seeds one row for every
-- value `proctoring_logs_action_type_check` allows.
--
-- WHY THIS FILE EXISTS
--   `register_violation()` counted rows: `select count(*) ... ; if v_count >= 3`.
--   Three right-clicks, three pasted lines and three sustained second-face
--   sightings were therefore the same evidence, and a student whose camera
--   glitched twice lost the sitting to somebody else's mouse. The vocabulary the
--   check constraint already carries is the distinction the count threw away
--   (`supabase/schema.sql` section 5, `mobile/lib/features/proctoring/domain/
--   entities/violation.dart`), so it becomes data here instead of being hard-coded
--   in the function: an institution can retune a type with one UPDATE instead of
--   a new migration (README, "Tuning the violation weights").
--
-- WHY A TABLE AND NOT A COLUMN ON `proctoring_logs`
--   A weight is a *policy*, not evidence. Storing it beside the row would freeze
--   whichever value was current on the day of the incident, so a supervisor
--   retuning the policy could never re-read an old attempt under the new rule, and
--   a mass UPDATE would rewrite evidence. Here the logs stay untouched (this file
--   deliberately rewrites no `proctoring_logs` row) and only the interpretation
--   moves.
--
-- WHAT A ROW MEANS
--   * `weight` - how many points the type adds to the attempt's disqualification
--     score. `int` and `>= 0`: a soft signal cannot subtract (that would let one
--     type pay for another), and integers keep "3 hard signals" readable.
--   * `counts_toward_dq` - whether the type may contribute *at all*. This is the
--     switch the review asked for; `weight = 0` alone would say the same thing,
--     but a type can then be given a weight for reporting without arming it.
--   * A type with NO row is scored as (weight 1, counted) by `register_violation()`
--     on purpose - see the fail-closed note in 20261104090100. A missing row must
--     never be a free pass for a signal the check constraint already accepts.
--
-- SEED (every one of the eleven allowed action types)
--   Hard, weight 1 - one point each, so three of them reach the threshold of 3
--   exactly as the old rule did for the signals that deserve it:
--     multiple_faces              a second person in frame
--     no_face                     nobody in frame (sustained on the client)
--     app_minimized               left the exam surface: tab hidden, window blurred,
--                                 fullscreen exited or the kiosk escape
--     devtools_detected           developer tools over the exam page
--     secondary_display_detected  answers readable on another screen
--     virtual_camera_detected     the feed is not this device's lens
--   The last three are not in the brief's short "hard" list, and they are hard on
--   purpose: they are exactly the identity-breaking set the client already prices
--   as severe (`ProctoringRisk.severeSignals`), and treating "a recorded video is
--   feeding the camera" as a free signal would leave the one attack this system
--   exists to catch uncounted.
--   Soft, weight 0, never counted - still stored as evidence, still shown to the
--   supervisor, just not this student's automatic disqualification:
--     looking_away                a sustained glance off screen
--     audio_noise                 the room, not necessarily the candidate
--     copy_paste_attempt          the lockdown blocked it; nothing left the page
--     right_click_blocked         the menu was suppressed, nothing was served
--     idle_afk                    logged for review after a long debounce
--
-- SAFETY
--   * Safe to re-run: `create table if not exists`, `drop policy if exists` +
--     `create policy`, and `on conflict (action_type) do nothing` on the seed, so a
--     second run never resets a weight an operator tuned with UPDATE.
--   * Additive only: it creates a table, seeds it, and touches no existing row of
--     `proctoring_logs` or `exam_submissions`. Nothing is backfilled and no
--     existing disqualification is re-read (see 20261104090100 and the README).
--   * PREREQUISITES: `public.is_admin()` (schema.sql section 1), and
--     `public.proctoring_logs` only for the vocabulary this seed copies - the
--     table itself is standalone.
--   * APPLY ORDER: after `20261103090800_snapshot_purge_not_live_attempt.sql`;
--     immediately BEFORE `20261104090100_weighted_strikes_and_flagged_review.sql`,
--     which reads it.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261104090000_violation_weights.sql
--   * Verify (expect eleven rows; six counted, five not):
--       select action_type, weight, counts_toward_dq
--         from public.violation_weights order by counts_toward_dq desc, action_type;
-- =====================================================================

create table if not exists public.violation_weights (
  action_type      text primary key,
  weight           int not null check (weight >= 0),
  counts_toward_dq boolean not null
);

comment on table public.violation_weights is
  'How much each proctoring_logs.action_type counts towards automatic disqualification. Read by register_violation(); a missing row is scored as (1, counted) so a new action type can never be a free pass.';

comment on column public.violation_weights.weight is
  'Points added to the attempt''s disqualification score. Integer >= 0; a soft signal must not be able to subtract.';

comment on column public.violation_weights.counts_toward_dq is
  'Whether this type may contribute at all. false = stored as evidence and shown to the supervisor, never auto-disqualifying.';

-- One row per value `proctoring_logs_action_type_check` allows (schema.sql
-- section 5). `do nothing` on conflict is what makes re-running this file safe on
-- a database whose weights have already been tuned.
insert into public.violation_weights (action_type, weight, counts_toward_dq) values
  -- Hard: camera / session signals
  ('multiple_faces',               1, true),
  ('no_face',                      1, true),
  ('app_minimized',                1, true),
  -- Hard: browser and device integrity
  ('devtools_detected',            1, true),
  ('secondary_display_detected',   1, true),
  ('virtual_camera_detected',      1, true),
  -- Soft: recorded, reviewed, never automatically fatal
  ('looking_away',                 0, false),
  ('audio_noise',                  0, false),
  ('copy_paste_attempt',           0, false),
  ('right_click_blocked',          0, false),
  ('idle_afk',                     0, false)
on conflict (action_type) do nothing;

alter table public.violation_weights enable row level security;

drop policy if exists "violation_weights_select_authenticated" on public.violation_weights;
drop policy if exists "violation_weights_insert_admin" on public.violation_weights;
drop policy if exists "violation_weights_update_admin" on public.violation_weights;
drop policy if exists "violation_weights_delete_admin" on public.violation_weights;

-- Read: every signed-in caller. Both the student's own explanation of a warning
-- and the supervisor's grid need to say *why* a signal did or did not count, and
-- there is nothing sensitive in a policy table - it is the same list this file
-- prints. `anon` reads nothing (revoked below): section 0 of schema.sql grants it
-- every table.
create policy "violation_weights_select_authenticated"
  on public.violation_weights for select
  to authenticated
  using (true);

-- Write: administrators only, split by command so the console's "how much is this
-- worth" edit cannot be joined by a supervisor or a lecturer. `is_admin()` is the
-- same predicate the rest of the schema uses for policy-level configuration.
create policy "violation_weights_insert_admin"
  on public.violation_weights for insert
  to authenticated
  with check (public.is_admin());

create policy "violation_weights_update_admin"
  on public.violation_weights for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "violation_weights_delete_admin"
  on public.violation_weights for delete
  to authenticated
  using (public.is_admin());

-- Privileges, explicitly, so this file is also correct on a project whose
-- `alter default privileges` was never replayed.
grant select, insert, update, delete on public.violation_weights to authenticated;
grant all privileges on public.violation_weights to service_role;
revoke all on public.violation_weights from anon;

-- Verification: the SQL editor prints this. Expect eleven rows, and every
-- `action_type` the check constraint in schema.sql section 5 allows.
select action_type, weight, counts_toward_dq
  from public.violation_weights
 order by counts_toward_dq desc, weight desc, action_type;
