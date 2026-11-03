-- =====================================================================
-- PROCTORGUARD - YOU MAY ONLY START A PAPER THAT IS YOURS TO SIT
-- Replaces `submissions_insert_own_ongoing`: every "fresh attempt" check it had,
-- plus the cohort rule and the schedule window it already carried.
--
-- WHY THIS FILE EXISTS
--   The policy asked "is this exam published and inside its window?" and never
--   asked "is it *this student's* paper". `exams_select` hid an out-of-cohort
--   paper from the list, but a patched client - or a student holding an old link -
--   could POST an `exam_submissions` row and then read the paper's questions
--   through `questions_public`. An attempt is the row every other row hangs from
--   (answers, proctoring logs, snapshots, the console roster card), so starting
--   one is where the cohort rule has to hold; a check only on the tile that is
--   rendered is not a check.
--
-- WHAT CHANGES
--   * Added `public.student_can_access_exam(exam_id)` - published, and aimed at a
--     student who cannot retarget themselves.
--   * The window is unchanged and stays in this policy; this is still the only
--     server-side check on it. Both bounds are optional, so both tests read
--     "NULL, or inside it", and an unscheduled paper - the common case, and every
--     paper authored before scheduling existed - passes exactly as before.
--   * `e.is_published = true` is gone from the window subquery because the helper
--     asserts it; nothing observable changes, and there is now one statement of
--     "published" per insert instead of two that could drift apart.
--
-- EVERY OTHER CHECK IS KEPT VERBATIM, and each one is load-bearing:
--   * `student_id = auth.uid()` - no starting an attempt in somebody else's name;
--   * `status = 'ongoing'` - no pre-made 'submitted' row, which would skip
--     `submit_exam()` and its grading;
--   * `score is null` - no self-awarded mark;
--   * `answers = '{}'::jsonb` - no answers seeded before the paper opens, which is
--     how a client would otherwise read the questions offline and paste them in;
--   * `submitted_at is null` - no pre-dated finish;
--   * `started_at = now()` - the start time comes from the database, so a client
--     cannot choose a future start and buy itself extra time past the deadline.
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * No `role = 'student'` test: the cohort rule is the check, and a staff member
--     who is also enrolled passes it like anybody else. Staff never insert an
--     attempt for a student; `submit_exam` and `register_violation` write the
--     student's own rows under their own session.
--   * No deadline arithmetic. `started_at + duration_minutes` (capped by
--     `ends_at`) is applied by `attempt_deadline()` at answer-write and submit
--     time; an attempt that starts one second before `ends_at` is still bounded.
--   * No UPDATE twin. There is deliberately no student UPDATE policy on
--     `exam_submissions` - see schema.sql §4 - and this file does not add one.
--
-- SAFETY
--   * Safe to re-run: `drop policy if exists` + `create policy`.
--   * Narrowing only: every insert that was refused before is still refused, and
--     an insert on a paper the student was not offered is now refused too. The
--     only client that could notice is one that was starting papers it could not
--     see.
--   * PREREQUISITES: `public.student_can_access_exam(uuid)`
--     (20261103090100...), `exams.starts_at` / `ends_at`
--     (`optional_exam_scheduling.sql`).
--   * APPLY ORDER: after `20261103090100_student_can_access_exam.sql` /
--     `20261103090300_questions_public.sql`; before
--     `20261103090500_snapshot_read_policy.sql`.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090400_submissions_insert_own_ongoing.sql
--   * Verify (expect one row containing student_can_access_exam and both window
--     bounds):
--       select pg_get_expr(polwithcheck, polrelid)
--         from pg_policy
--        where polrelid = 'public.exam_submissions'::regclass
--          and polname = 'submissions_insert_own_ongoing';
-- =====================================================================

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
    and exists (
      select 1 from public.exams e
      where e.id = exam_id
        and (e.starts_at is null or now() >= e.starts_at)
        and (e.ends_at   is null or now() <= e.ends_at)
    )
  );
