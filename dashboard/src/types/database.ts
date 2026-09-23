export type SubmissionStatus = "ongoing" | "submitted" | "disqualified";
export type UserRole = "student" | "supervisor";

export type UserRow = {
  id: string;
  role: UserRole;
  name: string;
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

export type QuestionRow = {
  id: string;
  exam_id: string;
  question_text: string;
  options: string[];
  correct_option: number;
  points: number;
};

export type SubmissionRow = {
  id: string;
  student_id: string;
  exam_id: string;
  answers: Record<string, number>;
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
      users: {
        Row: UserRow;
        Insert: Partial<UserRow>;
        Update: Partial<UserRow>;
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
