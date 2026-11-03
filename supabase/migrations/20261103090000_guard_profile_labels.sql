-- =====================================================================
-- PROCTORGUARD - PROFILE LABELS BELONG TO THE INSTITUTION, NOT THE ACCOUNT
-- A BEFORE INSERT OR UPDATE trigger that keeps a signed-in account from
-- inventing the profile labels a policy compares or a human reads.
--
-- WHY
--   `profiles_update_self` / `profiles_insert_self_student` are row policies, and
--   RLS is per row, not per column, so an account could rewrite its own
--   `faculty` / `department` / `level` and retarget itself. `exams_select`
--   compares those columns against the *reader's own* row, `questions_public` and
--   `submissions_insert_own_ongoing` now call `student_can_access_exam()` which
--   does the same, so targeting a student can retarget is not targeting: set
--   `level = '400'` and every 400-level paper (and its questions) opens up.
--   `matric_number` / `staff_id` are the identity a human reads on the roster and
--   in every export taken from it, and `email` is the address the row was
--   provisioned with - the join key a roster import matches on, and the login
--   address in `auth.users`.
--   `guard_user_role_change()` already protects `role`, the column every policy
--   trusts; this is the same guard for the other columns they trust.
--
-- WHAT CHANGES
--   For any caller that arrived through PostgREST with a JWT whose `role` claim
--   is not `service_role` and who is not an administrator:
--     * INSERT - `faculty`, `department`, `level`, `matric_number`, `staff_id`
--       must be NULL, and `lower(email)` must equal the JWT's `email` claim. A
--       self-provisioned row is a name and an address; it is not an academic
--       identity. Labels arrive with an administrator's roster import.
--     * UPDATE - those five columns and `email` are immutable.
--   `full_name` is deliberately untouched: `profiles_update_self` says owners may
--   correct their name, and no policy compares it.
--
--   The escape hatches are the ones `guard_user_role_change()` already
--   recognises, for the same reason - a project could not be bootstrapped
--   without them: no JWT claims at all (SQL editor, `supabase db reset`,
--   `supabase/tests/*.sql` fixtures), or the `service_role` key (the
--   `admin-create-user` / `admin-delete-user` Edge Functions and roster imports).
--
-- WHAT IT DELIBERATELY DOES NOT DO
--   * No policy change: `profiles_update_self`, `profiles_insert_self_student`
--     and `profiles_admin_all` keep their meaning; this only narrows the columns
--     a non-admin may set on its own row.
--   * No `role` handling - that stays with `guard_user_role_change()`.
--   * No new column, no backfill, no data rewrite.
--
-- SAFETY
--   * Safe to re-run: `create or replace function` + `drop trigger if exists`.
--   * Fails closed only on a write that sets a frozen column; a name-only update
--     or a plain re-save is untouched. The app never updates a label: it INSERTs
--     its self-provisioned row (id, role, full_name, email - email equal to the
--     session's own) and the admin console only updates `role`.
--   * Unparseable JWT claims are treated as an ordinary caller, not as
--     `service_role`: the hatch is a claim the caller must *hold*, never the
--     absence of one, and the no-claims branch below is what covers the SQL
--     editor.
--   * PREREQUISITES: `schema.sql` §1, or `add_user_roles_and_profiles.sql` +
--     `academic_targeting.sql` + `profile_identity_numbers.sql` - `public.profiles`
--     carrying `faculty`, `department`, `level`, `matric_number`, `staff_id`, and
--     `public.is_admin()`.
--   * APPLY ORDER: after `strict_targeting_null_profiles.sql`, and before
--     `20261103090200_exams_select.sql` / `20261103090300_questions_public.sql` /
--     `20261103090400_submissions_insert_own_ongoing.sql` - those three encode a
--     targeting rule that assumes a student cannot retarget themselves.
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/20261103090000_guard_profile_labels.sql
--   * Verify (expect two triggers, `not tgisinternal`):
--       select tgname from pg_trigger
--        where tgrelid = 'public.profiles'::regclass and not tgisinternal;
-- =====================================================================

create or replace function public.guard_profile_labels()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Null for anything that did not arrive through PostgREST: a migration, the SQL
  -- editor, `supabase db reset`, a fixture in `supabase/tests/`.
  v_claims      text := nullif(current_setting('request.jwt.claims', true), '');
  v_claim_role  text := '';
  v_claim_email text;
begin
  if v_claims is null then
    return new;
  end if;

  begin
    v_claim_role  := coalesce(v_claims::jsonb ->> 'role', '');
    v_claim_email :=
      nullif(lower(btrim(coalesce(v_claims::jsonb ->> 'email', ''))), '');
  exception
    when others then
      -- A malformed claim is not a privilege: fall through as an ordinary caller.
      v_claim_role  := '';
      v_claim_email := null;
  end;

  if v_claim_role = 'service_role' or public.is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.faculty          is not null
       or new.department    is not null
       or new.level         is not null
       or new.matric_number is not null
       or new.staff_id      is not null then
      raise exception 'academic labels and identity numbers are set by the institution, not at sign-up'
        using errcode = '42501',
              hint = 'leave faculty, department, level, matric_number and staff_id null; an administrator records them from the roster';
    end if;

    if v_claim_email is null
       or lower(btrim(new.email)) <> v_claim_email then
      raise exception 'profiles.email must be the address of the authenticated account'
        using errcode = '42501',
              hint = 'insert the row for the address you signed in with; an administrator can correct it later';
    end if;

    return new;
  end if;

  if new.faculty          is distinct from old.faculty
     or new.department    is distinct from old.department
     or new.level         is distinct from old.level
     or new.matric_number is distinct from old.matric_number
     or new.staff_id      is distinct from old.staff_id
     or new.email         is distinct from old.email then
    raise exception 'profile labels are set by the institution, not by the account'
      using errcode = '42501',
            hint = 'ask an administrator to correct faculty, department, level, matric_number, staff_id or email';
  end if;

  return new;
end;
$$;

comment on function public.guard_profile_labels() is
  'Refuses a self-service write to the profile labels a policy compares or a human reads: on INSERT the academic labels and identity numbers must be null and the email must be the session''s own; on UPDATE those five columns and email are immutable. Administrators, service_role and claims-less sessions (SQL editor, migrations) may write them.';

drop trigger if exists users_guard_labels on public.profiles;
drop trigger if exists profiles_guard_labels on public.profiles;
create trigger profiles_guard_labels
  before insert or update on public.profiles
  for each row execute function public.guard_profile_labels();
