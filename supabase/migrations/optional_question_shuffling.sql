-- =====================================================================
-- PROCTORGUARD - OPTIONAL QUESTION-ORDER SHUFFLING (behind a flag)
-- Adds `exams.shuffle_questions` (boolean, default false).  When enabled,
-- the exam session reorders questions with a deterministic seed derived
-- from the submission id, so the order is stable on resume and offline.
-- Only the display order changes; grading and stored answers stay keyed
-- by question id.  Options are *not* shuffled in this migration (noted
-- as a follow-up; see the docs/proposals/weighted-strikes.md).
--
-- WHY THIS FILE EXISTS
--   `create table if not exists public.exams (...)` in `schema.sql`
--   cannot add a column to a table that already exists, so a live project
--   needs this upgrade path.  `schema.sql` section 2 carries the same DDL
--   (plus the guarded `add column if not exists` statement) for fresh
--   installs, and the two files must be kept in step —
--   `mobile/test/schema_contract_test.dart` reads both.
--
-- WHAT IT DOES
--   1. Adds `exams.shuffle_questions boolean not null default false`.
--   2. The client reads the flag at session start and, when true, applies
--      a Fisher-Yates shuffle keyed by `hash(submission_id)`.
--
-- SAFETY
--   * Safe to re-run: `add column if not exists`.
--   * Additive: existing papers get `shuffle_questions = false` and behave
--     exactly as before.
--   * Order: independent of other migrations (it adds a column and touches
--     no policy, RPC or existing data).
--   * Applied through the Supabase CLI:
--       supabase db query --linked -f supabase/migrations/optional_question_shuffling.sql
--   * Verify:
--       select shuffle_questions, count(*)
--         from public.exams
--        group by shuffle_questions;
-- =====================================================================

alter table public.exams
  add column if not exists shuffle_questions boolean not null default false;

comment on column public.exams.shuffle_questions is
  'When true, the exam session reorders questions with a deterministic seed derived from the submission id. Default false — existing papers are unchanged.';
