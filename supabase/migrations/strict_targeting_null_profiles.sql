-- =====================================================================
-- PROCTORGUARD - STRICT TARGETING FOR INCOMPLETE PROFILE FIELDS
-- Closes a loophole: when a paper names a faculty/department/level, a
-- student whose matching field is NULL or blank formerly matched anyway
-- (`p.faculty is null` was always true).  After this migration a paper
-- that *names* a field only matches a student whose profile carries a
-- non-blank value (nullif(btrim(p.<col>), '') is not null) for that
-- field, and the trimmed lowercase values must match.
--
-- A paper whose label is effectively empty (nullif(btrim(exams.<col>),
-- '') is null) is untargeted and stays visible to everyone.
-- exam_allowed_students borrow list is unchanged.
--
-- WHY THIS FILE EXISTS
--   It is the upgrade path for a project already running academic
--   targeting; `schema.sql` carries the same rule for fresh installs.
--
-- AUDIT (run *before* applying this migration to find accounts that
-- would lose access):
--
--   select p.id, p.email, p.full_name, p.faculty, p.department, p.level,
--          e.id as lost_exam_id, e.title as lost_exam_title
--   from public.profiles p
--   join public.exam_submissions s on s.student_id = p.id
--   join public.exams e on e.id = s.exam_id
--   where p.role = 'student'
--     and s.status in ('ongoing', 'submitted')
--     and (
--       (nullif(btrim(e.faculty), '') is not null
--        and nullif(btrim(p.faculty), '') is null)
--       or (nullif(btrim(e.department), '') is not null
--           and nullif(btrim(p.department), '') is null)
--       or (nullif(btrim(e.level), '') is not null
--           and nullif(btrim(p.level), '') is null)
--     )
--   order by p.full_name, e.title;
--
--   -- Broader view: every student with blank labels who would lose access
--   -- to *any* targeted paper, regardless of whether they started one:
--   select id, email, full_name, faculty, department, level
--   from public.profiles
--   where role = 'student'
--     and (nullif(btrim(faculty), '') is null
--          or nullif(btrim(department), '') is null
--          or nullif(btrim(level), '') is null)
--   order by full_name;
--
-- SAFETY
--   * Safe to re-run: drop policy if exists + create.
--   * Only the student visibility rule changes. Staff and authors see
--     everything as before, and the borrow list (exam_allowed_students)
--     is not consulted by the changed clause - it is its own OR branch.
--   * Order: after academic_targeting.sql (replaces the same policy).
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/strict_targeting_null_profiles.sql
-- =====================================================================
-- DO NOT RE-RUN AFTER APPLYING
--   This file is the historical upgrade path: it installs the definition it was
--   written against, and the hardened replacements live in
--   `supabase/migrations/2026110309*.sql` (each lists its own APPLY ORDER). Running
--   this file again after those would put the older policy or function back - the
--   `DROP POLICY`/`CREATE POLICY` pair below is idempotent, which is the problem:
--   it reinstates, silently, exactly what was replaced.

drop policy if exists "exams_select" on public.exams;

create policy "exams_select"
  on public.exams for select
  to authenticated
  using (
    public.is_staff()
    or created_by = auth.uid()
    or (
      is_published = true
      and (
        exists (
          select 1
          from public.profiles p
          where p.id = auth.uid()
            and (nullif(btrim(exams.faculty), '') is null
                 or (nullif(btrim(p.faculty), '') is not null
                     and lower(btrim(p.faculty)) = lower(btrim(exams.faculty))))
            and (nullif(btrim(exams.department), '') is null
                 or (nullif(btrim(p.department), '') is not null
                     and lower(btrim(p.department)) = lower(btrim(exams.department))))
            and (nullif(btrim(exams.level), '') is null
                 or (nullif(btrim(p.level), '') is not null
                     and lower(btrim(p.level)) = lower(btrim(exams.level))))
        )
        or exists (
          select 1
          from public.exam_allowed_students a
          where a.exam_id = exams.id and a.student_id = auth.uid()
        )
      )
    )
  );

-- Verify: the new policy is in place.
--   select polname, pg_get_expr(polqual, polrelid)
--     from pg_policy
--    where polrelid = 'public.exams'::regclass
--      and polname = 'exams_select';
