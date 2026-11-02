# Weighted strikes — proposal

**Status:** Proposal only. Not implemented.

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

| Signal | Weight | Rationale |
|--------|--------|-----------|
| `looking_away` / `gaze_left` / `gaze_right` | 1.0 | A glance off screen is common; three is still a pattern. Unchanged. |
| `no_face` | 1.0 | Camera may glitch. Three sustained absences are a real concern. |
| `app_minimized` | 1.0 | Same tier as looking away. |
| `right_click` | 0.0 | A right-click blocker already prevents the action; an OS-level right-click that bypasses the blocker is worth noting but should not auto-disqualify. |
| `copy_paste` / `paste` | 0.0 | Undetectable without a fully locked-down kiosk; marking it as zero means it is recorded but never triggers auto-DQ. |
| `idle` | 0.0 | The AFK watcher already has a long debounce. Logged for the supervisor's review but never auto-disqualifies. |
| `audio_noise` | 0.0 | A noisy room is environmental, not necessarily cheating. Logged for review only. |
| `multiple_faces` | 3.0 | A second person in frame is the most serious integrity failure. |
| `virtual_camera` | 3.0 | An attempt to bypass the camera entirely. |
| `secondary_display` | 3.0 | Answers being read from another screen. |
| `devtools_open` | 3.0 | Developer tools over the exam page. |

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
  ('right_click',          0.0),
  ('copy_paste',           0.0),
  ('paste',                0.0),
  ('idle',                 0.0),
  ('audio_noise',          0.0),
  ('multiple_faces',       3.0),
  ('virtual_camera',       3.0),
  ('secondary_display',    3.0),
  ('devtools_open',        3.0)
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
   - Three `right_click` rows → status unchanged (weight 0.0 each).
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
right-click, idle and paste — weight 0.0 each) are not automatically
disqualified.

### Follow-up: option shuffling

This proposal does not touch question-order shuffling (handled in a separate
feature behind the `exams.shuffle_questions` flag). Options within a question
are also not shuffled yet (noted as a follow-up — it needs index mapping so
stored option indices stay correct).
