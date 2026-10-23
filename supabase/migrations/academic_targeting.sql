-- =====================================================================
-- PROCTORGUARD - ACADEMIC METADATA AND SCOPED EXPOSURE
-- Gives accounts and papers the three labels the institution already uses -
-- faculty, department, level - and makes those labels decide which published
-- papers a student is offered. A paper is *targeted* at a cohort; a student in
-- another department who is sitting the course anyway is added to a per-paper
-- allow list (`exam_allowed_students`) - the "borrowed course" case.
--
-- WHY THIS FILE EXISTS
--   `create table if not exists public.profiles (...)` / `public.exams (...)`
--   in `schema.sql` cannot add a column to a table that already exists, so a
--   live project would keep six-column tables while the apps sent `faculty`,
--   `department` and `level`. The statements below are the upgrade path;
--   `schema.sql` sections 1, 2 and 2b carry the same DDL (plus the guarded
--   `add column if not exists` statements) for fresh installs, and the two files
--   must be kept in step - `mobile/test/schema_contract_test.dart` reads both.
--
-- WHAT IT DOES
--   1. `public.profiles.faculty / department / level` - who an account belongs
--      to. Free text, nullable.
--   2. `public.exams.faculty / department / level` - who a paper is for.
--      Free text, nullable.
--   3. `public.exam_allowed_students` - the borrow list, one row per
--      (paper, student), readable by that student and by staff, writable by the
--      paper's author.
--   4. `exams_select` is replaced: staff and authors are unchanged (they see
--      everything), students see a published paper only when its labels match
--      their own profile or when they are on its borrow list.
--
-- SAFETY
--   * Safe to re-run: every column is `add column if not exists`, the table is
--     `create table if not exists`, and every policy is dropped by name before
--     it is re-created.
--   * Additive for data and for access: no row is rewritten, and every existing
--     paper has all three new columns NULL. NULL means "not narrowed", so a
--     paper from before this file ran is still offered exactly as it was. The
--     same reading applies to a *profile* whose labels are NULL: it is not
--     excluded by a targeted paper, so running this file can never lock a
--     student out of a paper they could see before.
--   * The one thing that does narrow is a paper that names a cohort: that is
--     the feature, and it applies to students only. `is_staff()` remains
--     unscoped on exams, because an invigilator opens sittings in every
--     department and the supervisor console's paper picker depends on it.
--   * Order: after `optional_exam_scheduling.sql` (both replace `exams_select`,
--     and neither depends on the other's columns), and after
--     `grant_api_roles_public_schema.sql` on a project that needed it.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/academic_targeting.sql
--   * Verify:
--       select column_name, is_nullable, data_type
--         from information_schema.columns
--        where table_schema = 'public'
--          and table_name in ('profiles', 'exams')
--          and column_name in ('faculty', 'department', 'level');
--       select exam_id, student_id, created_by
--         from public.exam_allowed_students limit 5;
--       select polname, pg_get_expr(polqual, polrelid)
--         from pg_policy
--        where polrelid = 'public.exams'::regclass
--          and polname = 'exams_select';
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. WHO AN ACCOUNT BELONGS TO
-- ---------------------------------------------------------------------
-- NULL is "not stated", not "unknown cohort": every policy reads NULL on
-- either side as *no narrowing*, so an account whose labels were never recorded
-- keeps the access it had before these columns existed.
alter table public.profiles add column if not exists faculty    text;
alter table public.profiles add column if not exists department text;
alter table public.profiles add column if not exists level      text;

comment on column public.profiles.faculty is
  'The faculty this account belongs to. Compared with exams.faculty by exams_select; NULL = not stated, and never narrows what the account may see.';
comment on column public.profiles.department is
  'The department this account belongs to. Compared with exams.department by exams_select; NULL = not stated.';
comment on column public.profiles.level is
  'The level (100 .. 600) this account belongs to, in the app catalogue''s spelling. Compared with exams.level by exams_select; NULL = not stated.';

-- The console's roster filter asks "who is in this department and level?"; a
-- student's own row is a primary-key lookup and needs nothing.
create index if not exists idx_profiles_department_level
  on public.profiles(department, level);

-- ---------------------------------------------------------------------
-- 2. WHO A PAPER IS FOR
-- ---------------------------------------------------------------------
alter table public.exams add column if not exists faculty    text;
alter table public.exams add column if not exists department text;
alter table public.exams add column if not exists level      text;

comment on column public.exams.faculty is
  'Faculty this paper is aimed at. NULL = any faculty (the pre-targeting paper).';
comment on column public.exams.department is
  'Department this paper is aimed at. NULL = any department.';
comment on column public.exams.level is
  'Level this paper is aimed at (100 .. 600). NULL = any level.';

-- ---------------------------------------------------------------------
-- 3. THE BORROW LIST
-- ---------------------------------------------------------------------
-- A student from another department may be taking the course - a service
-- course, a minor, a carry-over - and the lecturer knows who before the sitting
-- does. This table is that exception list.
--
-- A table rather than an `exams.extra_student_ids uuid[]` column: each row is a
-- foreign key, so deleting the student's profile or the paper removes the
-- exception with it (an array would leave a dangling id behind), and adding or
-- removing one is a plain PostgREST write scoped by the policies below.
create table if not exists public.exam_allowed_students (
  exam_id    uuid not null references public.exams(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  -- Who granted the exception. Audit only: no policy reads it, and deleting that
  -- account must not delete the exception, hence `on delete set null`.
  created_by uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (exam_id, student_id)
);

alter table public.exam_allowed_students enable row level security;

-- Explicit, because a project whose default privileges predate this table would
-- otherwise answer 42501 "permission denied" before RLS is consulted. These are
-- ordinary Postgres privileges; the policies below remain what decides rows.
grant all privileges on public.exam_allowed_students
  to postgres, anon, authenticated, service_role;

drop policy if exists "exam_allowed_students_select" on public.exam_allowed_students;
drop policy if exists "exam_allowed_students_insert_owner" on public.exam_allowed_students;
drop policy if exists "exam_allowed_students_delete_owner" on public.exam_allowed_students;

-- Read: the student the row names, or any member of staff (the console lists a
-- paper's exceptions beside the paper). A student must not be able to see who
-- *else* was granted one - that is somebody else's business.
create policy "exam_allowed_students_select"
  on public.exam_allowed_students for select
  to authenticated
  using (student_id = auth.uid() or public.is_staff());

-- Write: only the paper's author. `owns_exam()` is SECURITY DEFINER, so this
-- check does not re-enter `exams_select` - which is the policy that reads this
-- very table, and would otherwise recurse.
create policy "exam_allowed_students_insert_owner"
  on public.exam_allowed_students for insert
  to authenticated
  with check (public.owns_exam(exam_id));

create policy "exam_allowed_students_delete_owner"
  on public.exam_allowed_students for delete
  to authenticated
  using (public.owns_exam(exam_id));

-- The primary key serves "this paper's list"; this walks the other way, for the
-- student's side of `exams_select` ("is this paper on my list?") and for the
-- cascade when a profile is deleted.
create index if not exists idx_exam_allowed_students_student
  on public.exam_allowed_students(student_id);

-- ---------------------------------------------------------------------
-- 4. THE READ THAT CONSUMES THEM
-- ---------------------------------------------------------------------
-- Staff and authors: unchanged. `is_staff()` is deliberately unscoped - an
-- invigilator opens sittings in any department, and the supervisor console's
-- paper picker lists them all.
--
-- Students: a *published* paper whose named labels match their own profile row,
-- or a published paper they were explicitly allowed to borrow. Every comparison
-- reads NULL on either side as "not narrowed", which is what keeps an
-- untargeted paper (and a profile with no labels) visible exactly as before.
--
-- The borrow list is read through its own policies above, which show a student
-- precisely the rows that name them, so this EXISTS needs no definer helper and
-- cannot recurse. `exams.` qualifies the outer columns because the inner query
-- selects from `profiles`, which has columns of the same names.
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
            and (exams.faculty    is null or p.faculty is null
                 or lower(p.faculty)    = lower(exams.faculty))
            and (exams.department is null or p.department is null
                 or lower(p.department) = lower(exams.department))
            and (exams.level      is null or p.level is null
                 or p.level = exams.level)
        )
        or exists (
          select 1
          from public.exam_allowed_students a
          where a.exam_id = exams.id and a.student_id = auth.uid()
        )
      )
    )
  );

