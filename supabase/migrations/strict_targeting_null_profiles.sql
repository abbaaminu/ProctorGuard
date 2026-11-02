-- =====================================================================
-- PROCTORGUARD - STRICT TARGETING FOR INCOMPLETE PROFILE FIELDS
-- Closes a loophole: when a paper names a faculty/department/level, a
-- student whose matching field is NULL or blank formerly matched anyway
-- (`p.faculty is null` was always true).  After this migration a paper
-- that *names* a field only matches a student whose profile carries a
-- non-null, non-empty value for that field, and it must match.
--
-- Papers with no targeting (all three columns NULL) stay visible to
-- everyone, and the exam_allowed_students borrow list is unchanged.
--
-- WHY THIS FILE EXISTS
--   It is the upgrade path for a project already running academic
--   targeting; `schema.sql` and `academic_targeting.sql` carry the same
--   rule for fresh installs.  All three copies must be kept in step -
--   `mobile/test/schema_contract_test.dart` reads the policy out of
--   schema.sql.
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
--       (e.faculty    is not null and (p.faculty is null or p.faculty = ''))
--       or (e.department is not null and (p.department is null or p.department = ''))
--       or (e.level      is not null and (p.level is null or p.level = ''))
--     )
--   order by p.full_name, e.title;
--
--   -- Broader view: every student with NULL labels who would lose access
--   -- to *any* targeted paper, regardless of whether they started one:
--   select id, email, full_name, faculty, department, level
--   from public.profiles
--   where role = 'student'
--     and (faculty is null or department is null or level is null)
--   order by full_name;
--
-- SAFETY
--   * Safe to re-run: drop policy if exists + create.
--   * Only the student visibility rule changes. Staff and authors see
--     everything as before, and the borrow list (`exam_allowed_students`)
--     is not consulted by the changed clause - it is its own OR branch.
--   * Order: after `academic_targeting.sql` (replaces the same policy).
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/strict_targeting_null_profiles.sql
-- =====================================================================

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
            and (exams.faculty is null
                 or (p.faculty is not null and p.faculty != ''
                     and lower(p.faculty) = lower(exams.faculty)))
            and (exams.department is null
                 or (p.department is not null and p.department != ''
                     and lower(p.department) = lower(exams.department)))
            and (exams.level is null
                 or (p.level is not null and p.level != ''
                     and p.level = exams.level))
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
