import { useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { CheckCircle2, XCircle, AlertOctagon, RotateCcw } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useAccountNames } from "@/hooks/useAccountNames";
import { useResetSubmission } from "@/hooks/useResetSubmission";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge, statusTone } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { ConfirmDialog } from "@/components/ui/confirm-dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { Toast, type ToastTone } from "@/components/ui/toast";
import { formatTime } from "@/lib/utils";
import { incidentLabel } from "@/lib/incidents";
import type { SubmissionRow, ProctoringLogRow, QuestionRow } from "@/types/database";

/**
 * Mirrors the grading in `submit_exam()` for a fill-in-the-blank answer: the
 * server trims and lowercases both sides, so the audit view has to agree with it
 * or a correct answer would look wrong here.
 */
function normalise(value: string | null | undefined) {
  return (value ?? "").trim().toLowerCase();
}

export function SubmissionAudit() {
  const { id: submissionId } = useParams<{ id: string }>();
  const [submission, setSubmission] = useState<SubmissionRow | null>(null);
  const [logs, setLogs] = useState<ProctoringLogRow[]>([]);
  const [questions, setQuestions] = useState<QuestionRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  /** True once the attempt is gone: there is nothing left on this page to audit. */
  const [cleared, setCleared] = useState(false);
  const [confirmingReset, setConfirmingReset] = useState(false);
  const { names } = useAccountNames();
  const { resetSubmission, resetting } = useResetSubmission();
  /** One toast slot, the way the rest of the console does it (`ui/toast.tsx`). */
  const [toast, setToast] = useState<{ id: number; tone: ToastTone; message: string } | null>(null);
  const toastId = useRef(0);

  function showToast(tone: ToastTone, message: string) {
    toastId.current += 1;
    setToast({ id: toastId.current, tone, message });
  }

  useEffect(() => {
    if (!submissionId) {
      setLoading(false);
      return;
    }

    let active = true;

    (async () => {
      const { data: sub, error: submissionError } = await supabase
        .from("exam_submissions")
        .select("*")
        .eq("id", submissionId)
        .single();
      if (!active) return;

      if (submissionError || !sub) {
        // A network/RLS failure previously rendered as "Submission not found."
        // — saying what actually happened is worth the extra state.
        setError(submissionError?.message ?? "Submission not found.");
        setLoading(false);
        return;
      }

      setSubmission(sub as SubmissionRow);

      const [logRows, questionRows] = await Promise.all([
        supabase.from("proctoring_logs").select("*").eq("submission_id", submissionId).order("timestamp"),
        supabase.from("questions").select("*").eq("exam_id", sub.exam_id),
      ]);
      if (!active) return;

      setLogs((logRows.data as ProctoringLogRow[]) ?? []);
      setQuestions((questionRows.data as QuestionRow[]) ?? []);
      setLoading(false);
    })();

    return () => {
      active = false;
    };
  }, [submissionId]);

  /**
   * Clear the attempt: the submission, its answers and its proctoring evidence
   * all go, and the student can start the exam again from scratch.
   *
   * The confirmation is a real dialog rather than `window.confirm` because the
   * blast radius is worth spelling out — how many incidents are on file, that the
   * images go too — and because a *refused* delete has to be reported: otherwise
   * the page would simply look unchanged, with no reason given.
   */
  async function handleReset() {
    if (!submission || resetting) return;
    const label = names[submission.student_id] ?? "this student";

    // The dialog stays open while the write is in flight (buttons disable, the
    // confirm button shows a spinner): closing it first would leave the
    // supervisor looking at an unchanged page with no sign anything happened.
    const outcome = await resetSubmission(submission.id);
    setConfirmingReset(false);

    if (!outcome.ok) {
      showToast("alert", `Could not reset the attempt: ${outcome.error}.`);
      return;
    }

    setCleared(true);
    const snapshots =
      outcome.snapshots > 0 ? ` and ${outcome.snapshots} snapshot(s)` : "";
    showToast(
      outcome.storageWarning ? "alert" : "ok",
      outcome.storageWarning
        ? `Cleared ${label}'s attempt and ${outcome.incidents} incident(s), but ${outcome.storageWarning}.`
        : `Cleared ${label}'s attempt: ${outcome.incidents} incident(s)${snapshots} deleted. They can start the exam again.`
    );
  }

  if (loading) {
    return (
      <div className="p-6">
        <span role="status" className="sr-only">
          Loading the submission audit
        </span>

        <div className="mb-6 flex items-center justify-between">
          <div className="space-y-2">
            <Skeleton className="h-5 w-44" />
            <Skeleton className="h-3 w-32" />
            <Skeleton className="h-3 w-56" />
          </div>
          <Skeleton className="h-7 w-28 rounded-md" />
        </div>

        <div className="grid grid-cols-2 gap-4">
          {[0, 1].map((panel) => (
            <Card key={panel}>
              <CardHeader>
                <Skeleton className="h-4 w-40" />
              </CardHeader>
              <CardContent className="space-y-3">
                {[0, 1, 2].map((row) => (
                  <Skeleton key={row} className="h-16 w-full" />
                ))}
              </CardContent>
            </Card>
          ))}
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="p-6">
        <h1 className="mb-1 text-lg font-semibold text-slate-100">Submission audit</h1>
        <div className="mt-4 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
          {error}
        </div>
      </div>
    );
  }

  if (cleared && submission) {
    return (
      <div className="p-6">
        <h1 className="mb-1 text-lg font-semibold text-slate-100">Attempt cleared</h1>
        <p className="mb-4 max-w-xl text-sm text-slate-400">
          The submission, its stored answers and every proctoring incident recorded against it
          are deleted, and the student can start the exam again from a fresh attempt. Nothing
          from this attempt can be restored.
        </p>
        <Link to={`/exams/${submission.exam_id}/monitor`} className="text-sm text-accent hover:underline">
          Back to the exam monitor
        </Link>

        {toast && (
          <Toast
            id={toast.id}
            tone={toast.tone}
            message={toast.message}
            onDismiss={() => setToast(null)}
          />
        )}
      </div>
    );
  }

  if (!submission) return <div className="p-6 text-sm text-slate-500">Submission not found.</div>;

  return (
    <div className="p-6">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-slate-100">Submission audit</h1>
          <p className="text-xs text-slate-400">
            {names[submission.student_id] ?? "Unknown student"}
          </p>
          <p className="font-mono text-xs text-slate-500">{submission.id}</p>
        </div>
        <div className="flex items-center gap-3">
          <Badge tone={statusTone(submission.status)}>{submission.status}</Badge>
          <span className="text-lg font-semibold text-slate-100">
            {submission.score != null ? `${submission.score} pts` : "—"}
          </span>
          <Button
            variant="destructive"
            size="sm"
            disabled={resetting}
            onClick={() => setConfirmingReset(true)}
          >
            <RotateCcw size={13} />
            Reset attempt
          </Button>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <Card>
          <CardHeader><CardTitle>Incident timeline</CardTitle></CardHeader>
          <CardContent className="p-0">
            {logs.length === 0 ? (
              <p className="p-4 text-sm text-slate-500">No incidents recorded during this session.</p>
            ) : (
              <ol className="relative border-l border-border ml-4 py-2">
                {logs.map((log) => (
                  <li key={log.id} className="mb-4 ml-4 last:mb-0">
                    <span className="absolute -left-[5px] mt-1.5 h-2.5 w-2.5 rounded-full bg-alert" />
                    <div className="flex items-center gap-2">
                      <AlertOctagon size={13} className="text-alert" />
                      <span className="text-sm font-medium text-slate-200">
                        {incidentLabel(log.action_type)}
                      </span>
                      <span className="font-mono text-[11px] text-slate-500">{formatTime(log.timestamp)}</span>
                    </div>
                  </li>
                ))}
              </ol>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader><CardTitle>Question breakdown</CardTitle></CardHeader>
          <CardContent className="space-y-3 p-4">
            {questions.length === 0 && (
              <p className="text-sm text-slate-500">
                No questions are stored for this exam.
              </p>
            )}
            {questions.map((q, i) => {
              const answer = submission.answers?.[q.id];
              const isBlank = q.question_type === "fill_in_the_blank";
              // Stored answers are a number for a choice question and a string
              // for a typed one, so the two shapes are compared separately.
              const isCorrect = isBlank
                ? typeof answer === "string" && normalise(answer) === normalise(q.correct_text_answer)
                : answer === q.correct_option;
              const studentAnswer = isBlank
                ? typeof answer === "string" && answer.trim().length > 0
                  ? answer
                  : null
                : typeof answer === "number"
                  ? q.options[answer] ?? `Option ${answer + 1}`
                  : null;
              const expectedAnswer = isBlank
                ? q.correct_text_answer
                : typeof q.correct_option === "number"
                  ? q.options[q.correct_option]
                  : null;

              return (
                <div key={q.id} className="rounded-md border border-border bg-surface-inset p-3">
                  <div className="mb-1.5 flex items-center justify-between gap-2">
                    <span className="text-[11px] font-medium uppercase tracking-wide text-slate-500">
                      Question {i + 1} of {questions.length}
                    </span>
                    <span className="text-[11px] text-slate-500">
                      {isBlank ? "Fill in the blank" : "Multiple choice"} · {q.points} pt
                    </span>
                  </div>
                  <p className="mb-1.5 text-sm text-slate-200">{q.question_text}</p>
                  <div className="flex items-center gap-4 text-xs">
                    <span className="flex items-center gap-1 text-slate-400">
                      Student: {studentAnswer ?? "No answer"}
                      {studentAnswer != null &&
                        (isCorrect ? (
                          <CheckCircle2 size={13} className="text-ok" />
                        ) : (
                          <XCircle size={13} className="text-alert" />
                        ))}
                    </span>
                    {!isCorrect && expectedAnswer && (
                      <span className="text-slate-500">Correct: {expectedAnswer}</span>
                    )}
                  </div>
                </div>
              );
            })}
          </CardContent>
        </Card>
      </div>

      <ConfirmDialog
        open={confirmingReset}
        title={`Reset ${names[submission.student_id] ?? "this student"}'s attempt?`}
        confirmLabel="Reset attempt"
        busyLabel="Clearing…"
        busy={resetting}
        onConfirm={handleReset}
        onCancel={() => setConfirmingReset(false)}
      >
        <p>
          The submission, its stored answers and its {logs.length} proctoring incident
          {logs.length === 1 ? "" : "s"} are deleted for good, and the student can start the
          exam again from a fresh attempt.
        </p>
        <p>
          A student who is mid-exam is logged out of it, and any snapshot images of this attempt
          are removed from Storage too. This cannot be undone.
        </p>
      </ConfirmDialog>

      {toast && (
        <Toast
          id={toast.id}
          tone={toast.tone}
          message={toast.message}
          onDismiss={() => setToast(null)}
        />
      )}
    </div>
  );
}
