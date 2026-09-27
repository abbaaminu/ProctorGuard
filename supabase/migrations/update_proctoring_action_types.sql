-- =====================================================================
-- PROCTORGUARD - PROCTORING LOG ACTION TYPES (ENTERPRISE TELEMETRY)
-- Widens the `proctoring_logs.action_type` CHECK constraint with the
-- integrity signals the clients can detect today:
--
--   copy_paste_attempt        browser/web shell: a copy, cut or paste event was
--                             caught and blocked during an attempt
--                             (mobile/lib/core/services/web_guards.dart)
--   right_click_blocked       browser: the context menu was suppressed - the
--                             "view source / inspect" affordance
--   devtools_detected         browser: the viewport geometry says a docked
--                             developer-tools panel is open while the exam runs
--   secondary_display_detected Android: a second display is attached (HDMI/DP
--                             monitor, casting, screen mirroring) - the exam can
--                             be watched/copied on a surface the proctoring
--                             camera cannot see
--   virtual_camera_detected   Android: the camera in use is not a physical lens
--                             (external/USB device, or an emulator's virtual
--                             camera, which is how a recorded feed is injected)
--   idle_afk                  no keyboard/pointer activity for the AFK window
--                             (mobile/lib/core/services/afk_watcher.dart)
--
-- WHY THIS FILE EXISTS SEPARATELY
--   `schema.sql` creates the table with `create table if not exists`, so a
--   re-run of that file does NOT touch the constraint on a database that already
--   has the table: those installations would keep rejecting every new signal at
--   the API. This file is the upgrade path for them. `schema.sql` section 5
--   carries the same list for fresh installs, and repeats this refresh so
--   re-running that one file is still enough.
--
--   Keep the two lists in step: `mobile/test/schema_contract_test.dart` fails if
--   either one drifts from `ViolationType` in the mobile app.
--
-- SAFETY
--   * Safe to re-run: the old constraint is found by *definition* (any CHECK on
--     action_type, whatever it is named) and dropped before the new one is
--     added, so running this twice leaves exactly one constraint behind.
--   * Safe on a live table: the CHECK is added NOT VALID (a catalog-only
--     ACCESS EXCLUSIVE lock, no table rewrite and no long scan) and then
--     validated, which only needs SHARE UPDATE EXCLUSIVE.
--   * If a pre-existing row already holds an unknown action_type, VALIDATE fails
--     and names the row: the constraint stays enforced for new rows, and no
--     evidence is deleted or rewritten. Re-classify that row, then re-run.
--   * On a database where `proctoring_logs` does not exist yet (schema.sql not
--     applied) this is a no-op with a notice instead of an error.
-- =====================================================================

do $$
declare
  v_constraint text;
begin
  if to_regclass('public.proctoring_logs') is null then
    raise notice 'public.proctoring_logs is missing: run schema.sql first, then re-run this file.';
    return;
  end if;

  for v_constraint in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'proctoring_logs'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) like '%action_type%'
  loop
    raise notice 'proctoring_logs: dropping the previous action_type constraint (%)', v_constraint;
    execute format('alter table public.proctoring_logs drop constraint %I', v_constraint);
  end loop;
end $$;

alter table public.proctoring_logs
  add constraint proctoring_logs_action_type_check
  check (
    action_type in (
      -- Camera / session signals (schema.sql, original set)
      'looking_away',
      'multiple_faces',
      'no_face',
      'app_minimized',
      'audio_noise',
      -- Browser exam lockdown (WebGuards / WebExamGuard)
      'copy_paste_attempt',
      'right_click_blocked',
      'devtools_detected',
      -- Device integrity (HardwareIntegrityService)
      'secondary_display_detected',
      'virtual_camera_detected',
      -- Inactivity (AfkWatcher)
      'idle_afk'
    )
  ) not valid;

alter table public.proctoring_logs
  validate constraint proctoring_logs_action_type_check;

-- Verification: the SQL editor prints this. Exactly ONE row is expected, and its
-- definition has to list all eleven types above.
select con.conname as constraint_name,
       pg_get_constraintdef(con.oid) as definition,
       con.convalidated as validated
  from pg_constraint con
  join pg_class rel on rel.oid = con.conrelid
  join pg_namespace nsp on nsp.oid = rel.relnamespace
 where nsp.nspname = 'public'
   and rel.relname = 'proctoring_logs'
   and con.contype = 'c'
   and pg_get_constraintdef(con.oid) like '%action_type%';
