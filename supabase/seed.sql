-- =====================================================================
-- PROCTOR - SEED / MOCK TESTING DATA
-- ---------------------------------------------------------------------
-- Run this AFTER schema.sql. The Flutter app at ../mobile uses this data.
--
-- Creates: 1 admin + 1 supervisor + 1 lecturer + 2 student profiles
-- (public.profiles), 2 published exams (public.exams), 5 questions per exam
-- (public.questions), and 1 sample submission with 3 realistic violation logs
-- (public.exam_submissions + public.proctoring_logs).
--
-- HOW TO RUN (Supabase SQL editor)
--   1. Dashboard -> SQL Editor -> New query.
--   2. Paste this whole file.
--   3. Click Run (Ctrl/Cmd + Enter) and wait for "Success".
--      The editor runs as the `postgres` role, which bypasses RLS, so no
--      policies need relaxing for these inserts - including the
--      profiles_guard_role_change trigger, which allows a role change when
--      there is no JWT (see schema.sql).
--   4. The LAST statement prints a roster - check it shows one submission
--      with 3 flags, then reload the Flutter app.
--
-- SAFE TO RE-RUN: every insert ends with `on conflict ... do nothing`.
-- IDs are hard-coded and repeated inline so the FK graph stays readable:
--   1111... supervisor   2222... Aisha      3333... Chidi
--   4444... admin        5555... lecturer
--   aaaa..a1 CS101       aaaa..a2 MAT201
--   bbbb..b1-5 CS101 Qs  cccc..c1-5 MAT201 Qs
--   dddd..d1 submission  eeee..e1-3 its logs
--
-- DEMO LOGINS (created in step 0; the same password for all five):
--   admin@proctor.test         / Proctor123!  -> admin      - account management
--   supervisor@proctor.test    / Proctor123!  -> supervisor - staff console
--   lecturer@proctor.test      / Proctor123!  -> lecturer   - staff analytics
--   aisha.bello@proctor.test   / Proctor123!  -> student    - mobile app
--   chidi.okonkwo@proctor.test / Proctor123!  -> student    - mobile app
-- The emails use the reserved .test TLD so a demo seed can never mail a
-- real person. Change them before reusing this script anywhere real.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. AUTH USERS
-- public.profiles.id references auth.users(id) on delete cascade, so these
-- rows must exist before the profiles in step 1. Prefer creating them by
-- hand? Do that first (Dashboard -> Authentication -> Users -> Add user,
-- password Proctor123!) and re-run this script: the block below then
-- no-ops thanks to `on conflict do nothing`.
-- ---------------------------------------------------------------------
do $$
declare
  v_password text := 'Proctor123!';
  v_hash     text;
  r          record;
begin
  -- bcrypt hash of the demo password. Supabase ships pgcrypto in the
  -- `extensions` schema, so fall back to a schema-qualified call when the
  -- unqualified function is not on the search_path.
  begin
    select crypt(v_password, gen_salt('bf')) into v_hash;
  exception when others then
    begin
      execute 'select extensions.crypt($1, extensions.gen_salt(''bf''))'
        into v_hash using v_password;
    exception when others then
      raise exception using message =
        'pgcrypto (crypt/gen_salt) is unavailable, so the demo auth users cannot be created. Create them under Authentication -> Users with password Proctor123! and re-run this script; the auth step is then skipped.';
    end;
  end;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    confirmation_token, recovery_token, email_change, email_change_token_new,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at
  )
  select
    '00000000-0000-0000-0000-000000000000'::uuid,
    u.id, 'authenticated', 'authenticated', u.email, v_hash,
    now(),                 -- pre-confirmed: no verification email is sent
    '', '', '', '',
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', u.name, 'email_verified', true),
    now(), now()
  from (values
    ('44444444-4444-4444-8444-444444444444'::uuid, 'admin@proctor.test'::text,         'Prof. Grace Adeyemi'::text),
    ('11111111-1111-4111-8111-111111111111'::uuid, 'supervisor@proctor.test'::text,    'Dr. Ada Nwosu'::text),
    ('55555555-5555-4555-8555-555555555555'::uuid, 'lecturer@proctor.test'::text,      'Dr. Tunde Balogun'::text),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'aisha.bello@proctor.test'::text,   'Aisha Bello'::text),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'chidi.okonkwo@proctor.test'::text, 'Chidi Okonkwo'::text)
  ) as u(id, email, name)
  on conflict do nothing;

  -- Identity rows are best-effort: GoTrue changed this table across
  -- releases (`provider_id`, text vs uuid id), so try the modern layout and
  -- silently skip unknown shapes - password sign-in works from auth.users.
  for r in
    select id, email from (values
      ('44444444-4444-4444-8444-444444444444'::uuid, 'admin@proctor.test'::text),
      ('11111111-1111-4111-8111-111111111111'::uuid, 'supervisor@proctor.test'::text),
      ('55555555-5555-4555-8555-555555555555'::uuid, 'lecturer@proctor.test'::text),
      ('22222222-2222-4222-8222-222222222222'::uuid, 'aisha.bello@proctor.test'::text),
      ('33333333-3333-4333-8333-333333333333'::uuid, 'chidi.okonkwo@proctor.test'::text)
    ) as t(id, email)
  loop
    begin
      insert into auth.identities (
        id, provider_id, user_id, identity_data, provider,
        last_sign_in_at, created_at, updated_at
      )
      values (
        r.id::text, r.id::text, r.id,
        jsonb_build_object('sub', r.id::text, 'email', r.email),
        'email', now(), now(), now()
      )
      on conflict do nothing;
    exception when others then
      begin
        insert into auth.identities (
          id, user_id, identity_data, provider,
          last_sign_in_at, created_at, updated_at
        )
        values (
          r.id, r.id,
          jsonb_build_object('sub', r.id::text, 'email', r.email),
          'email', now(), now(), now()
        )
        on conflict do nothing;
      exception when others then
        null; -- unknown GoTrue layout: skip, sign-in still works
      end;
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 1. PROFILES  (public.profiles) - 1 admin + 1 supervisor + 1 lecturer +
--    2 students, 1:1 with the auth users created in step 0.
--    `role` is the public.user_role enum; the admin is the account that may
--    create further accounts from the admin console.
-- ---------------------------------------------------------------------
insert into public.profiles (id, role, full_name, email) values
  ('44444444-4444-4444-8444-444444444444', 'admin',      'Prof. Grace Adeyemi', 'admin@proctor.test'),
  ('11111111-1111-4111-8111-111111111111', 'supervisor', 'Dr. Ada Nwosu',       'supervisor@proctor.test'),
  ('55555555-5555-4555-8555-555555555555', 'lecturer',   'Dr. Tunde Balogun',   'lecturer@proctor.test'),
  ('22222222-2222-4222-8222-222222222222', 'student',    'Aisha Bello',         'aisha.bello@proctor.test'),
  ('33333333-3333-4333-8333-333333333333', 'student',    'Chidi Okonkwo',       'chidi.okonkwo@proctor.test')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. EXAMS  (public.exams) - all published, so the students' exam list
--    and the monitor's exam picker are populated. created_by is the
--    owner RLS scopes the paper to: the supervisor above owns the two
--    invigilated papers, and the lecturer owns GES301 - the paper the
--    lecturer console's authoring and grading views are built around
--    (the owner, not the wider staff tier, is who may edit a paper or
--    award the marks on it).
-- ---------------------------------------------------------------------
insert into public.exams (id, title, created_by, duration_minutes, is_published, created_at) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
   'CS101: Computer Science Fundamentals',
   '11111111-1111-4111-8111-111111111111',
   60, true, now() - interval '2 days'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
   'MAT201: Calculus Quiz',
   '11111111-1111-4111-8111-111111111111',
   45, true, now() - interval '5 hours'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
   'GES301: Software Engineering Midterm',
   '55555555-5555-4555-8555-555555555555',
   50, true, now() - interval '3 hours')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3. QUESTIONS  (public.questions) - 5 per exam, 10 points each paper.
--
-- Two shapes are seeded so both code paths are exercised end to end:
--   * 'multiple_choice'   - `options` is a jsonb array and `correct_option` is
--                           the 0-BASED index of the right answer inside it
--                           (both clients render `options` as tap targets).
--   * 'fill_in_the_blank' - `options` is empty and `correct_text_answer` holds
--                           the accepted wording; grading trims and ignores
--                           case, so "  http " scores for "HTTP" (CS101 Q4,
--                           inserted separately below).
-- ---------------------------------------------------------------------
insert into public.questions (id, exam_id, question_text, options, correct_option, points) values

  -- ---- CS101: Computer Science Fundamentals (2 + 2 + 1 + 2 + 3 = 10) ----
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
   'Which data structure processes elements in FIFO (first in, first out) order?',
   '["Stack","Queue","Binary search tree","Hash table"]'::jsonb, 1, 2),

  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
   'What is the worst-case time complexity of binary search on a sorted array of n elements?',
   '["O(1)","O(log n)","O(n)","O(n log n)"]'::jsonb, 1, 2),

  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
   'Which of the following is NOT a primitive type in Java?',
   '["int","boolean","String","char"]'::jsonb, 2, 1),

  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb5', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
   'In SQL, which clause filters rows before they are grouped by GROUP BY?',
   '["ORDER BY","WHERE","GROUP BY","HAVING"]'::jsonb, 1, 3),

  -- ---- MAT201: Calculus Quiz (2 + 3 + 2 + 2 + 1 = 10) ----
  ('cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
   'What is the derivative of f(x) = x^2 with respect to x?',
   '["x","2x","x^2 / 2","2"]'::jsonb, 1, 2),

  ('cccccccc-cccc-4ccc-8ccc-ccccccccccc2', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
   'Evaluate the definite integral of 3x^2 from x = 0 to x = 1.',
   '["1","2","3","1/3"]'::jsonb, 0, 3),

  ('cccccccc-cccc-4ccc-8ccc-ccccccccccc3', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
   'What is the limit of (sin x) / x as x approaches 0?',
   '["0","1","Infinity","The limit does not exist"]'::jsonb, 1, 2),

  ('cccccccc-cccc-4ccc-8ccc-ccccccccccc4', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
   'Short answer: Which statement describes the Chain Rule correctly?',
   '["Integrate the outer function, then add the inner function","Multiply the outer function by the inner function","Differentiate the outer function, then multiply by the derivative of the inner function","Differentiate the inner function only"]'::jsonb, 2, 2),

  ('cccccccc-cccc-4ccc-8ccc-ccccccccccc5', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2',
   'The derivative of ln(x) with respect to x is:',
   '["1 / x","x","e^x","ln(x) / x"]'::jsonb, 0, 1)
on conflict (id) do nothing;

-- CS101 Q4 is a real fill-in-the-blank item: no options, one accepted wording
-- (graded case-insensitively after trimming by submit_exam). It is inserted
-- separately so the block above stays a pure 'multiple_choice' insert.
insert into public.questions
  (id, exam_id, question_text, question_type, options, correct_option, correct_text_answer, points)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
   'What does the acronym HTTP stand for?',
   'fill_in_the_blank', '[]'::jsonb, null, 'HyperText Transfer Protocol', 2)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3b. THE LECTURER'S PAPER  (public.questions, one row per shape)
-- Four questions, one of each type the console can author, all four owned by
-- the lecturer (GES301 above) so the authoring view has something to edit:
--   * 'multiple_choice'   - options + the 0-based correct index (auto-graded)
--   * 'true_false'        - no options; `correct_text_answer` is the word 'true',
--                           which is also exactly what a true/false tap stores
--                           in `exam_submissions.answers` (auto-graded)
--   * 'fill_in_the_blank' - one accepted wording (auto-graded)
--   * 'subjective'        - no answer key at all: it has none to leak, and its
--                           marks arrive through `grade_submission()` when the
--                           lecturer reads the answer (5 points below)
-- ---------------------------------------------------------------------
insert into public.questions
  (id, exam_id, question_text, question_type, options, correct_option, correct_text_answer, points)
values
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
   'Which process model delivers a working increment at the end of every short iteration?',
   'multiple_choice', '["Waterfall","Scrum","Big design up front","V-Model"]'::jsonb, 1, null, 2),

  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb7', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
   'A pull request may be merged before its automated checks have passed.',
   'true_false', '[]'::jsonb, null, 'false', 1),

  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb8', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
   'What is the practice of running the test suite automatically on every change called?',
   'fill_in_the_blank', '[]'::jsonb, null, 'Continuous integration', 2),

  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',
   'Describe how you would review a change that touches authentication. Name the checks you would run and say what would make you reject the change.',
   'subjective', '[]'::jsonb, null, null, 5)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 4. SAMPLE SUBMISSION  (public.exam_submissions)
-- Aisha Bello sat CS101 and was auto-disqualified by the server-enforced
-- 3-strike rule. `answers` maps question UUID -> 0-based selected option,
-- exactly how merge_submission_answer() writes it (jsonb_set with the
-- question id as the key). She answered Q1 correctly and Q2 wrongly before
-- being stopped, so `score` stays NULL - disqualified sessions are never
-- graded. (Q1 expects 1 = "Queue"; Q2's 3 = "O(n log n)" is wrong.)
--
-- `on conflict do nothing` (no target) covers BOTH unique constraints here:
-- the primary key and unique(student_id, exam_id) - so this is a no-op if
-- the mobile app already created Aisha's CS101 submission.
-- ---------------------------------------------------------------------
insert into public.exam_submissions
  (id, student_id, exam_id, answers, status, score, started_at, submitted_at)
values
  ('dddddddd-dddd-4ddd-8ddd-ddddddddddd1',
   '22222222-2222-4222-8222-222222222222',   -- Aisha Bello (student)
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',   -- CS101
   '{
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1": 1,
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2": 3
    }'::jsonb,
   'disqualified',
   null,                                     -- never graded
   now() - interval '9 minutes',
   now() - interval '90 seconds')
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 4b. A HANDED-IN ATTEMPT WITH AN ESSAY STILL TO MARK
--     (public.exam_submissions + public.question_grades)
-- Chidi sat the lecturer's GES301 paper and handed it in. `answers` holds all
-- three shapes exactly as the merge RPCs write them - a bare number for the
-- multiple-choice index, a JSON *string* for the true/false tap ('false' is the
-- right answer and he said 'true') and for the typed fill-in-the-blank - plus
-- the essay text under the subjective question's id.
--
-- `score` is 4: what `submit_exam()` could grade on its own. The essay is worth
-- 5 more and has NO row in `question_grades`, which is what puts this attempt in
-- the lecturer console's "waiting for marks" list. Marking it through
-- `grade_submission()` stores one `question_grades` row and rewrites `score` as
-- 4 + awarded.
-- ---------------------------------------------------------------------
insert into public.exam_submissions
  (id, student_id, exam_id, answers, status, score, started_at, submitted_at)
values
  ('dddddddd-dddd-4ddd-8ddd-ddddddddddd2',
   '33333333-3333-4333-8333-333333333333',   -- Chidi Okonkwo (student)
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3',   -- GES301 (the lecturer's paper)
   '{
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6": 1,
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb7": "true",
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb8": "continuous integration",
      "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9": "I would start by reading the diff for anything that stores or compares a secret, then check that the password path still goes through the hashing helper rather than a new comparison."
    }'::jsonb,
   'submitted',
   4,                                        -- auto-graded part; 5 essay marks pending
   now() - interval '40 minutes',
   now() - interval '6 minutes')
on conflict do nothing;

-- No `question_grades` row is seeded on purpose: an unmarked essay is the state
-- the grading view has to be able to show. To seed one instead - a mark already
-- awarded, for a screenshot or a re-mark demo - the shape is:
--   insert into public.question_grades (submission_id, question_id, awarded, feedback)
--   values ('dddddddd-dddd-4ddd-8ddd-ddddddddddd2',
--           'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb9', 3.5, 'Good threat model.')

-- ---------------------------------------------------------------------
-- 5. PROCTORING LOGS  (public.proctoring_logs)
-- Three alerts leading to the disqualification above: gaze deviation,
-- face missing, then a second sustained gaze deviation. action_type values
-- must match the table's check constraint (they mirror ViolationType.dbValue
-- in the Flutter app).
--
-- The app never writes a 4th row - ProctoringNotifier returns early once
-- `disqualified` is set and register_violation() flips the status on the 3rd
-- strike - so 3 logs + status='disqualified' is the consistent shape.
-- snapshot_url holds the bucket-relative Storage *path*, the same value the app
-- stores after an upload (`<submission_id>/<action_type>_<epoch-ms>.jpg`). The
-- bucket is private, so this is an identifier rather than a link: this script
-- uploads no real files either way, so nothing resolves until a still exists at
-- that path.
-- ---------------------------------------------------------------------
insert into public.proctoring_logs (id, submission_id, action_type, timestamp, snapshot_url) values
  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee1',
   'dddddddd-dddd-4ddd-8ddd-ddddddddddd1',
   'looking_away',
   now() - interval '5 minutes',
   'dddddddd-dddd-4ddd-8ddd-ddddddddddd1/looking_away_1.jpg'),

  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee2',
   'dddddddd-dddd-4ddd-8ddd-ddddddddddd1',
   'no_face',
   now() - interval '3 minutes',
   'dddddddd-dddd-4ddd-8ddd-ddddddddddd1/no_face_1.jpg'),

  ('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeee3',
   'dddddddd-dddd-4ddd-8ddd-ddddddddddd1',
   'looking_away',
   now() - interval '90 seconds',
   null)                                    -- frame was unusable: no snapshot
on conflict (id) do nothing;

commit;

-- ---------------------------------------------------------------------
-- 6. VERIFY
-- The editor displays the result of the last statement, so this roster
-- should come back as one row (Aisha Bello / CS101) with 3 flags and
-- status = disqualified.
-- Other useful spot-checks:
--   select * from public.questions_public order by exam_id, question_text;
--   select * from public.proctoring_logs  order by timestamp;
--   select id, role, full_name, email from public.profiles order by role, full_name;
-- ---------------------------------------------------------------------
select
  e.title       as exam,
  u.full_name   as student,
  s.status,
  count(l.id)   as flags,
  s.started_at,
  s.submitted_at
from public.exam_submissions s
join public.exams e on e.id = s.exam_id
join public.profiles u on u.id = s.student_id
left join public.proctoring_logs l on l.submission_id = s.id
group by e.title, u.full_name, s.status, s.started_at, s.submitted_at
order by s.started_at;
