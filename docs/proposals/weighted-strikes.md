# Weighted strikes — proposal

**Status:** Implemented, with a different shape than proposed below. The proposal
was written before the review's findings landed; what shipped keeps its core idea
(weight per `action_type`, read from a table, threshold in points) and changes three
things it argued for:

* the table is `public.violation_weights` with `weight int` and
  `counts_toward_dq boolean` (not `numeric(4,2)` with a 1.0 default), so a soft
  signal is explicitly *not counted* rather than merely worth zero;
* the threshold is **3 weighted points** (not 4.0), and every counted type weighs
  1, which keeps "three hard signals" as the rule for the signals that deserve it;
* reaching it produces **`flagged_for_review`**, not `disqualified` - a supervisor
  decides through `resolve_flagged_attempt()`, audited in `attempt_review_logs` -
  and there is **no reconciliation UPDATE** ("§4" below): an attempt that was
  already disqualified stays disqualified, because deciding after the fact that it
  should have been a review is a human's call.

Where it landed: `supabase/migrations/20261104090000_violation_weights.sql`,
`supabase/migrations/20261104090100_weighted_strikes_and_flagged_review.sql`,
`supabase/schema.sql` §5a / the escalation block, `mobile/lib/features/proctoring/
domain/entities/violation.dart` (the mirrors) and `supabase/tests/
weighted_strikes_check.sql`. Tuning is a README section, not a migration.

**Later change (20261108090000):** two of the five "soft, weight 0" rows below were
re-priced — `looking_away` and `audio_noise` are counted strikes at weight 1, so
three glances off screen or three noisy-room strikes close the sitting
for review exactly as three faces in frame do (a noisy room reaches a strike either by
holding above the room's measured floor for two unbroken seconds or by repeating
bursts of at least 300 ms - three of them, or 4 s in total, inside a rolling
60-second window; see `mobile/lib/core/services/proctoring_thresholds.dart`).
`copy_paste_attempt`,
`right_click_blocked` and `idle_afk` stay at 0. The threshold (3), the ending
(`flagged_for_review`) and the human decision (`resolve_flagged_attempt`) are
unchanged. The prose below is the original proposal and is kept as written, except
that its weight table now describes the *first* seed rather than the current one.

## Problem

The current 3-strike rule in `register_violation` (`supabase/schema.sql` §5)
counts every violation the same: three logged rows — any three — flip
`exam_submissions.status` to `disqualified`. This means a student who pastes a
single line, idles for ten seconds, and has one camera glitch is disqualified
alongside someone with three confirmed multiple-face sightings.

The system already distinguishes *kinds* of evidence. The client-side
`ProctoringRisk` index (`proctoring_risk.dart`) has a `severeSignals` set
(`multipleFaces`, `virtualCameraDetected`, `secondaryDisplayDetected`,
`devtoolsDetected`) and weights those 15 points versus 10 for an extra distinct
type. But the server's auto-disqualification threshold — the only enforcement
that cannot be skipped — still counts three straws as the same weight as three
bricks.

## Proposal

Replace the `count(*) >= 3` hard stop in `register_violation` with a weighted
accumulator. Each `action_type` gets a weight (1.0 by default, 0 for signals
that should never auto-disqualify, 3.0 for severe signals), and the
disqualification threshold becomes a configurable sum rather than a row count.

### Weight table (new column or separate config table)

The eleven rows below are exactly the `proctoring_logs_action_type_check` vocabulary
in `supabase/schema.sql` §5 — the same list `ViolationType.dbValue` sends from the
app. A complete row per type is deliberate: a type with no row would silently take
the 1.0 default.

| Signal | Weight | Rationale |
|--------|--------|-----------|
| `looking_away` | 1.0 | A glance off screen is common; three is still a pattern. Unchanged. (Gaze direction is not a separate `action_type`: `looking_away` is the one the app sends.) |
| `no_face` | 1.0 | Camera may glitch. Three sustained absences are a real concern. |
| `app_minimized` | 1.0 | Same tier as looking away. |
| `right_click_blocked` | 0.0 | The blocker already prevents the action; the signal records that it was tried, and should not auto-disqualify. |
| `copy_paste_attempt` | 0.0 | Undetectable without a fully locked-down kiosk; marking it as zero means it is recorded but never triggers auto-DQ. |
| `idle_afk` | 0.0 | The AFK watcher already has a long debounce. Logged for the supervisor's review but never auto-disqualifies. |
| `audio_noise` | 0.0 | A noisy room is environmental, not necessarily cheating. Logged for review only. |
| `multiple_faces` | 3.0 | A second person in frame is the most serious integrity failure. |
| `virtual_camera_detected` | 3.0 | An attempt to bypass the camera entirely. |
| `secondary_display_detected` | 3.0 | Answers being read from another screen. |
| `devtools_detected` | 3.0 | Developer tools over the exam page. |

### Disqualification threshold

Raise the bar from `3` (rows) to **4.0** (weighted score). This means:
- Three `looking_away` strikes → 3.0 → not yet disqualified (one more would do
  it).
- One `multiple_faces` + one `looking_away` → 4.0 → disqualified immediately.
- Two `multiple_faces` → 6.0 → disqualified.

### Migration outline

```sql
-- 1. Add a weight lookup table.
create table if not exists public.proctoring_action_weights (
  action_type text primary key,
  weight      numeric(4,2) not null default 1.0
);

insert into public.proctoring_action_weights (action_type, weight) values
  -- Camera / session signals (1.0 - a pattern of three, as today)
  ('looking_away',             1.0),
  ('no_face',                  1.0),
  ('app_minimized',            1.0),
  -- Browser exam lockdown (0.0 - recorded, never auto-DQ)
  ('copy_paste_attempt',       0.0),
  ('right_click_blocked',      0.0),
  -- Device integrity (3.0 - one sighting plus a 1.0 signal crosses the threshold)
  ('devtools_detected',        3.0),
  ('secondary_display_detected', 3.0),
  ('virtual_camera_detected',  3.0),
  -- Inactivity and environment (0.0 - logged for review only)
  ('idle_afk',                 0.0),
  ('audio_noise',              0.0),
  -- The most serious single signal in the set.
  ('multiple_faces',           3.0)
on conflict (action_type) do nothing;

-- 2. Replace the 3-strike hard stop in register_violation.
--    Current:
--      if (select count(*) from public.proctoring_logs
--          where submission_id = v_submission_id) >= 3 then
--        update public.exam_submissions
--          set status = 'disqualified'
--          where id = v_submission_id and status = 'ongoing';
--      end if;
--
--    New:
--      declare v_weighted numeric;
--      begin
--        select coalesce(sum(coalesce(w.weight, 1.0)), 0)
--          into v_weighted
--          from public.proctoring_logs l
--          left join public.proctoring_action_weights w
--            on w.action_type = l.action_type
--          where l.submission_id = v_submission_id;
--        if v_weighted >= 4.0 then
--          update public.exam_submissions
--            set status = 'disqualified'
--            where id = v_submission_id and status = 'ongoing';
--        end if;
--      end;

-- 3. Grant privileges on the new table.
grant select on public.proctoring_action_weights to authenticated;

-- 4. One-time reconciliation of in-progress attempts.
update public.exam_submissions s
  set status = 'disqualified'
  where s.status = 'ongoing'
    and (
      select coalesce(sum(coalesce(w.weight, 1.0)), 0)
        from public.proctoring_logs l
        left join public.proctoring_action_weights w
          on w.action_type = l.action_type
        where l.submission_id = s.id
    ) >= 4.0;
```

### Client changes

1. **`ViolationType` enum** — add a `weight` getter that mirrors the server
   table's values (or a fallback of 1.0). Used by the supervisor dashboard for
   display, not enforcement.
2. **`ProctoringRisk`** — update the doc comment to reference the server's
   weighted disqualification threshold rather than the `3-strike` rule. The
   client-side risk index is unaffected (it remains a 0-100 heuristic), but
   the explanation text (the `explanation` getter) may benefit from noting
   weight.
3. **Supervisor dashboard** — show the weighted score alongside the raw strike
   count so a supervisor scanning the grid can see who is close to auto-DQ.
4. **The `ExamInstructionsDialog`** — update the "Three confirmed strikes close
   the attempt" wording to describe the weighting.

### Tests needed

1. **Migration test**: verify `proctoring_action_weights` contains every known
   `action_type` with the expected weight.
2. **Server test** (SQL-only):
   - Three `looking_away` rows → status unchanged (weight 3.0 < 4.0).
   - One `multiple_faces` + one `looking_away` → status changed to
     `disqualified` (weight 4.0 >= 4.0).
   - Three `right_click_blocked` rows → status unchanged (weight 0.0 each).
   - A mix of zero-weight and low-weight signals → no DQ until the weighted
     sum reaches the threshold.
3. **Client unit tests**:
   - `ProctoringRisk` still computes the same index.
   - The new weight getters match the server table.
   - The supervisor dashboard renders the weighted score.
4. **Contract test (`schema_contract_test.dart`)**:
   - The new table's rows match the `ViolationType.dbValue` strings.
   - The weight values match the Flutter mirror.

### Risk to in-progress attempts

**Low.** This change is additive: existing `proctoring_logs` rows keep the
weights their `action_type` maps to. An attempt that has two stored violations
under the old 3-strike rule continues to accumulate weight under the new rule.
The one-time reconciliation in §4 of the migration re-checks every ongoing
submission so that borderline cases (three violations that happened to be
`right_click_blocked`, `idle_afk` and `copy_paste_attempt` — weight 0.0 each) are
not automatically disqualified.

### Follow-up: option shuffling

This proposal does not touch question-order shuffling (handled in a separate
feature behind the `exams.shuffle_questions` flag). Options within a question
are also not shuffled yet (noted as a follow-up — it needs index mapping so
stored option indices stay correct).
