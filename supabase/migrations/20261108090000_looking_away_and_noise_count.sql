-- =====================================================================
-- PROCTORGUARD - A GLANCE AND A NOISY ROOM NOW COUNT
-- Flips two rows of `public.violation_weights` from "recorded for review only"
-- to "worth one point", so `register_violation()`'s weighted threshold can close
-- a sitting on three look-aways or three sustained noisy-room episodes.
--
-- WHY THIS FILE EXISTS
--   `20261104090000_violation_weights.sql` seeded `looking_away` and
--   `audio_noise` at weight 0 / `counts_toward_dq = false`: they were stored as
--   evidence and shown to a supervisor, but they could never end an attempt on
--   their own. That was too lenient for the two signals a camera-and-microphone
--   proctor is actually good at: a candidate who reads the paper off a second
--   screen and a candidate who talks the answers through with somebody in the
--   room produce exactly those two signals, over and over, and neither used to
--   move the score at all.
--   The rule now: **three counted strikes close the attempt** - and a glance and
--   a noisy room are counted strikes.
--
-- WHAT CHANGES
--   Exactly two rows, from (0, false) to (1, true):
--     looking_away   a sustained glance off screen (15 deg on both axes, held
--                    for 2 s - the client's rule, unchanged by this file)
--     audio_noise    the room above its own measured floor, held for 2 s (the
--                    client's rule, unchanged by this file)
--   Nothing else. `copy_paste_attempt`, `right_click_blocked` and `idle_afk`
--   stay weight 0 / not counted; the six identity-breaking signals
--   (`multiple_faces`, `no_face`, `app_minimized`, `devtools_detected`,
--   `secondary_display_detected`, `virtual_camera_detected`) stay at 1 point and
--   are not touched by this file.
--
-- WHAT IT DOES NOT DO
--   * It rewrites **no** `proctoring_logs` row and backfills nothing: the weights
--     are policy, read at call time by `register_violation()`, and the existing
--     evidence keeps its own `action_type` and `client_timestamp`.
--   * It re-reads **no** `exam_submissions` row: an attempt that is already
--     `submitted`, `disqualified` or `flagged_for_review` keeps that status. Only
--     an 'ongoing' attempt can be closed by the rule, and it accumulates under the
--     new weights from its next signal onwards.
--   * It changes no threshold: it is still **3** weighted points
--     (`c_flag_threshold` in `schema.sql`), and it is still
--     `flagged_for_review` - a person decides, never an automatic
--     disqualification.
--   * It does not touch `resolve_flagged_attempt()`, the consent tables, the
--     heartbeat series, retention or the label guards.
--
-- SAFETY
--   * Safe to re-run: one `update ... where action_type in (...)`, so every run
--     writes the same two values and no row is inserted or deleted. Re-running it
--     after an operator retuned one of these two rows puts them back to (1, true) -
--     which is the point of the file, and is why it must not be run casually as
--     part of a repair.
--   * Fail-closed on the *client* side too: the app mirrors these numbers for
--     display only (`ViolationType.weight`), and `schema_contract_test.dart` fails
--     if the mirror and the seed in `schema.sql` drift apart.
--   * The verification block at the bottom raises rather than passing quietly if
--     either row is missing or still not counted - a no-op UPDATE on a project
--     that never applied `20261104090000_violation_weights.sql` would otherwise
--     look like success.
--
-- APPLY ORDER
--   * After `20261104090000_violation_weights.sql` (it creates and seeds the
--     table this file updates) and after
--     `20261104090100_weighted_strikes_and_flagged_review.sql` (the escalation
--     that reads it). Nothing else depends on it, so it sorts last.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261108090000_looking_away_and_noise_count.sql
--   * Or re-run `supabase/schema.sql`, whose seed already carries (1, true) for
--     both types on a fresh install.
--   * Verify (expect exactly the third column, both rows 1 / true):
--       select action_type, weight, counts_toward_dq
--         from public.violation_weights
--        where action_type in ('looking_away', 'audio_noise')
--        order by action_type;
-- =====================================================================

update public.violation_weights
   set weight = 1,
       counts_toward_dq = true
 where action_type in ('looking_away', 'audio_noise');

-- Verify, and refuse to look successful if the table or a row was not there.
do $$
declare
  v_missing text;
begin
  if to_regclass('public.violation_weights') is null then
    raise exception 'FAIL: public.violation_weights does not exist - apply '
      '20261104090000_violation_weights.sql first';
  end if;

  select string_agg(t.action_type, ', ' order by t.action_type)
    into v_missing
  from (values ('looking_away'), ('audio_noise')) as t(action_type)
  where not exists (
    select 1
      from public.violation_weights w
     where w.action_type = t.action_type
       and w.weight = 1
       and w.counts_toward_dq
  );

  if v_missing is not null then
    raise exception 'FAIL: still not counted at weight 1: %', v_missing;
  end if;

  raise notice 'looking_away and audio_noise now count (1 point each; 3 points flags the attempt for review)';
end $$;
