export type SubmissionStatus = "ongoing" | "submitted" | "disqualified";

/** Mirrors the `public.user_role` enum in `supabase/schema.sql`. */
export type UserRole = "admin" | "lecturer" | "supervisor" | "student";

/**
 * Row of `public.profiles` — the table used to be `users`, and its display-name
 * column used to be `name`.
 */
export type ProfileRow = {
  id: string;
  role: UserRole;
  full_name: string;
  email: string;
};

export type ExamRow = {
  id: string;
  title: string;
  created_by: string;
  duration_minutes: number;
  is_published: boolean;
  created_at: string;
};

export type QuestionType = "multiple_choice" | "fill_in_the_blank";

export type QuestionRow = {
  id: string;
  exam_id: string;
  question_text: string;
  question_type: QuestionType;
  /** Tap targets for `multiple_choice`; empty for `fill_in_the_blank`. */
  options: string[];
  /** Index into `options`. Null for a fill-in-the-blank row. */
  correct_option: number | null;
  /** Accepted wording for `fill_in_the_blank`. Null for a choice row. */
  correct_text_answer: string | null;
  points: number;
};

/** Row shape of the student-facing `questions_public` view (no answer keys). */
export type PublicQuestionRow = Omit<
  QuestionRow,
  "correct_option" | "correct_text_answer"
>;

export type SubmissionRow = {
  id: string;
  student_id: string;
  exam_id: string;
  /**
   * `questions.id` -> answer. A number is a 0-based choice index
   * (`merge_submission_answer`), a string is a typed answer
   * (`merge_submission_text_answer`).
   */
  answers: Record<string, number | string>;
  status: SubmissionStatus;
  score: number | null;
  started_at: string;
  submitted_at: string | null;
};

export type ProctoringLogRow = {
  id: string;
  submission_id: string;
  action_type: string;
  snapshot_url: string | null;
  timestamp: string;
  /**
   * When the violation happened *on the student's device* (`register_violation`'s
   * `p_client_timestamp`). It differs from `timestamp` when the app logged the
   * violation offline and the queue delivered it later; null for rows written by a
   * client that predates the offline queue.
   */
  client_timestamp?: string | null;
  /**
   * Idempotency key of that one violation. The offline retry replays it, and the
   * RPC's `on conflict` turns a replayed call into no-op instead of a second
   * strike, so this is what makes a late-delivered row trustworthy.
   */
  client_event_id?: string | null;
};

// Minimal typed shape for @supabase/supabase-js generics. In a real project
// generate this with `supabase gen types typescript`.
//
// Two things matter for the generic contract (both learned the hard way):
//  1. Every table needs all four keys (Row, Insert, Update, Relationships)
//     and the schema needs Views / Functions / Enums / CompositeTypes.
//  2. It MUST be a `type` alias, not an `interface`: only object *type
//     aliases* get TypeScript's implicit index signature, so an interface
//     never satisfies postgrest-js' `Record<string, GenericTable>` bounds —
//     the lookup fails and every row silently degrades to `never`.
export type Database = {
  public: {
    Tables: {
      profiles: {
        Row: ProfileRow;
        Insert: Partial<ProfileRow>;
        Update: Partial<ProfileRow>;
        Relationships: [];
      };
      exams: {
        Row: ExamRow;
        Insert: Partial<ExamRow>;
        Update: Partial<ExamRow>;
        Relationships: [];
      };
      questions: {
        Row: QuestionRow;
        Insert: Partial<QuestionRow>;
        Update: Partial<QuestionRow>;
        Relationships: [];
      };
      exam_submissions: {
        Row: SubmissionRow;
        Insert: Partial<SubmissionRow>;
        Update: Partial<SubmissionRow>;
        Relationships: [];
      };
      proctoring_logs: {
        Row: ProctoringLogRow;
        Insert: Partial<ProctoringLogRow>;
        Update: Partial<ProctoringLogRow>;
        Relationships: [];
      };
    };
    Views: {
      questions_public: {
        Row: Omit<QuestionRow, "correct_option">;
        Relationships: [];
      };
    };
    // `Record<...>` rather than `{ [_ in never]: never }`: a mapped type with
    // a `never` key produces an empty object type with no index signature,
    // which would fail the `Record<string, …>` bounds above.
    Functions: Record<string, { Args: Record<string, unknown>; Returns: unknown }>;
    Enums: Record<string, string>;
    CompositeTypes: Record<string, Record<string, unknown>>;
  };
};
