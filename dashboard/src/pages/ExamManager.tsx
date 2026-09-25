import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Plus, Radio, Trash2, Monitor, Pencil, X } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/hooks/useAuth";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Skeleton, TableSkeleton } from "@/components/ui/skeleton";
import type { ExamRow, QuestionRow, QuestionType } from "@/types/database";

interface DraftQuestion {
  /** Set when the row already exists: edit mode updates it **in place** by id. */
  id?: string;
  question_type: QuestionType;
  question_text: string;
  options: string[];
  correct_option: number;
  correct_text_answer: string;
  points: number;
}

function emptyQuestion(): DraftQuestion {
  return {
    question_type: "multiple_choice",
    question_text: "",
    options: ["", "", "", ""],
    correct_option: 0,
    correct_text_answer: "",
    points: 1,
  };
}

/** Maps a stored `questions` row onto the editable draft (edit mode). */
function draftFromQuestion(question: QuestionRow): DraftQuestion {
  return {
    id: question.id,
    question_type: question.question_type,
    question_text: question.question_text,
    options: question.options?.length
      ? question.options
      : ["", "", "", ""],
    correct_option: question.correct_option ?? 0,
    correct_text_answer: question.correct_text_answer ?? "",
    points: question.points,
  };
}

/**
 * The `questions` row a draft describes.
 *
 * The shape check in `../supabase/schema.sql` requires exactly one answer key per
 * row (`questions_answer_key_shape`), so a fill-in-the-blank row is sent with an
 * empty `options` and a null `correct_option`, and a choice row with a null
 * `correct_text_answer`.
 */
function questionPayload(question: DraftQuestion, examId: string) {
  const isBlank = question.question_type === "fill_in_the_blank";
  return {
    exam_id: examId,
    question_text: question.question_text.trim(),
    question_type: question.question_type,
    options: isBlank ? [] : question.options.map((option) => option.trim()),
    correct_option: isBlank ? null : question.correct_option,
    correct_text_answer: isBlank ? question.correct_text_answer.trim() : null,
    points: question.points,
  };
}

/** First problem with a draft question, worded for the modal's error banner. */
function questionDraftError(index: number, question: DraftQuestion): string | null {
  if (!question.question_text.trim()) return null; // blank drafts are ignored

  const label = `Question ${index + 1}`;
  if (!Number.isFinite(question.points) || question.points <= 0) {
    return `${label} needs a positive point value.`;
  }

  if (question.question_type === "fill_in_the_blank") {
    if (!question.correct_text_answer.trim()) {
      return `${label} "fill in the blank" needs the accepted answer.`;
    }
    return null;
  }

  const filledOptions = question.options.filter((option) => option.trim());
  if (filledOptions.length < 2) {
    return `${label} needs at least two non-empty options.`;
  }
  if (!question.options[question.correct_option]?.trim()) {
    return `${label} needs the option marked correct to have text.`;
  }
  return null;
}

/**
 * Create *or* edit an exam.
 *
 * Edit mode only touches the metadata (title + duration). Question rows are
 * referenced by id inside `exam_submissions.answers` (the grading RPC joins on
 * them), so replacing the set would orphan every answer already recorded and
 * break the audit trail — question authoring therefore stays on the create path.
 */
function ExamFormModal({
  exam,
  onClose,
  onSaved,
}: {
  exam?: ExamRow;
  onClose: () => void;
  onSaved: () => void;
}) {
  const { profile } = useAuth();
  const [title, setTitle] = useState(exam?.title ?? "");
  const [duration, setDuration] = useState(exam?.duration_minutes ?? 30);
  const [questions, setQuestions] = useState<DraftQuestion[]>([emptyQuestion()]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const isEdit = exam !== undefined;
  const [loadingQuestions, setLoadingQuestions] = useState(isEdit);

  // Edit mode loads the exam's questions so they can be corrected in place. New
  // rows are added draft-by-draft below; existing rows keep their id, because
  // recorded answers reference it (`submit_exam` joins on `questions.id`).
  useEffect(() => {
    if (!exam) return;
    let active = true;
    setLoadingQuestions(true);

    (async () => {
      const { data, error: loadError } = await supabase
        .from("questions")
        .select("*")
        .eq("exam_id", exam.id)
        .order("created_at");
      if (!active) return;

      if (loadError) {
        setError(loadError.message);
        setLoadingQuestions(false);
        return;
      }

      const rows = (data as QuestionRow[]) ?? [];
      setQuestions(
        rows.length > 0
          ? [...rows.map(draftFromQuestion), emptyQuestion()]
          : [emptyQuestion()]
      );
      setLoadingQuestions(false);
    })();

    return () => {
      active = false;
    };
  }, [exam]);

  function updateQuestion(i: number, patch: Partial<DraftQuestion>) {
    setQuestions((qs) => qs.map((q, idx) => (idx === i ? { ...q, ...patch } : q)));
  }

  function updateOption(qi: number, oi: number, value: string) {
    setQuestions((qs) =>
      qs.map((q, idx) =>
        idx === qi ? { ...q, options: q.options.map((o, j) => (j === oi ? value : o)) } : q
      )
    );
  }

  async function handleSave() {
    if (saving) return;

    if (!profile) {
      setError("Your profile is still loading — try again in a moment.");
      return;
    }
    if (!title.trim()) {
      setError("Give the exam a title.");
      return;
    }
    if (!Number.isFinite(duration) || duration <= 0) {
      setError("The duration must be at least one minute.");
      return;
    }

    // Validate every draft before touching the database: a failure halfway
    // through the writes used to leave a half-authored exam behind.
    const problem = questions
      .map((question, index) => questionDraftError(index, question))
      .find((message) => message !== null);
    if (problem) {
      setError(problem);
      return;
    }

    setSaving(true);
    setError(null);

    try {
      if (exam) {
        const { error: updateError } = await supabase
          .from("exams")
          .update({ title: title.trim(), duration_minutes: duration })
          .eq("id", exam.id);
        if (updateError) throw updateError;

        // Existing questions are updated **in place** (their ids survive, so no
        // recorded answer is orphaned); only genuinely new drafts are inserted.
        for (const question of questions) {
          if (!question.question_text.trim()) continue;

          const payload = questionPayload(question, exam.id);
          const { error: questionError } = question.id
            ? await supabase.from("questions").update(payload).eq("id", question.id)
            : await supabase.from("questions").insert(payload);
          if (questionError) throw questionError;
        }
      } else {
        const { data: created, error: examError } = await supabase
          .from("exams")
          .insert({
            title: title.trim(),
            duration_minutes: duration,
            created_by: profile.id,
            is_published: false,
          })
          .select()
          .single();
        if (examError || !created) {
          throw examError ?? new Error("The exam was not created.");
        }

        const drafts = questions.filter((q) => q.question_text.trim());
        if (drafts.length > 0) {
          const { error: qError } = await supabase
            .from("questions")
            .insert(drafts.map((q) => questionPayload(q, created.id)));
          if (qError) throw qError;
        }
      }

      onSaved();
      onClose();
    } catch (err) {
      // This used to be unhandled: the promise rejected with nothing on screen,
      // so a refused insert looked like the Save button doing nothing.
      setError(err instanceof Error ? err.message : "Could not save the exam.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
      <div className="flex max-h-[85vh] w-full max-w-2xl flex-col rounded-lg border border-border bg-surface-raised">
        <div className="flex items-center justify-between border-b border-border px-5 py-3">
          <h2 className="text-sm font-semibold text-slate-100">
            {isEdit ? "Edit exam" : "Create exam"}
          </h2>
          <button onClick={onClose} className="text-slate-500 hover:text-slate-300">
            <X size={18} />
          </button>
        </div>

        <div className="flex-1 space-y-5 overflow-y-auto px-5 py-4">
          {error && (
            <div className="rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
              {error}
            </div>
          )}

          <div className="grid grid-cols-3 gap-3">
            <div className="col-span-2">
              <label className="mb-1 block text-xs font-medium text-slate-400">Exam title</label>
              <input
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                className="w-full rounded-md border border-border bg-surface-inset px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent/50"
                placeholder="Midterm — Data Structures"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-slate-400">Duration (min)</label>
              <input
                type="number"
                min={1}
                value={duration}
                onChange={(e) => setDuration(Number(e.target.value))}
                className="w-full rounded-md border border-border bg-surface-inset px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent/50"
              />
            </div>
          </div>

          <div>
            <div className="mb-2 flex items-center justify-between">
              <span className="text-xs font-medium text-slate-400">Questions</span>
              <Button variant="outline" size="sm" onClick={() => setQuestions((q) => [...q, emptyQuestion()])}>
                <Plus size={14} /> Add question
              </Button>
            </div>

            {loadingQuestions && (
              <div
                role="status"
                aria-label="Loading the exam's questions"
                className="mb-3 space-y-2"
              >
                <Skeleton className="h-14 w-full" />
                <Skeleton className="h-14 w-full" />
              </div>
            )}

            <div className="space-y-3">
              {questions.map((q, qi) => {
                const isBlank = q.question_type === "fill_in_the_blank";
                return (
                <div key={qi} className="rounded-md border border-border bg-surface-inset p-3">
                  <div className="mb-2 flex items-center justify-between gap-2">
                    <span className="text-xs font-medium text-slate-300">
                      Question {qi + 1} of {questions.length}
                    </span>
                    <div className="flex items-center gap-2">
                      <select
                        value={q.question_type}
                        onChange={(e) =>
                          updateQuestion(qi, {
                            question_type: e.target.value as QuestionType,
                          })
                        }
                        title="Question type"
                        className="rounded-md border border-border bg-surface px-2 py-1 text-xs text-slate-200 outline-none focus:border-accent/50"
                      >
                        <option value="multiple_choice">Multiple choice</option>
                        <option value="fill_in_the_blank">Fill in the blank</option>
                      </select>
                      <input
                        type="number"
                        min={1}
                        value={q.points}
                        onChange={(e) => updateQuestion(qi, { points: Number(e.target.value) })}
                        title="Points"
                        className="w-16 rounded-md border border-border bg-surface px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-accent/50"
                      />
                      {q.id ? (
                        // Rows that already exist keep their id: recorded answers
                        // reference it, so deleting one would orphan them.
                        <button
                          type="button"
                          disabled
                          title="A question that submissions already answer cannot be removed: recorded answers reference it by id. Create a new exam to change the bank."
                          className="cursor-not-allowed text-slate-600"
                        >
                          <Trash2 size={15} />
                        </button>
                      ) : (
                        <button
                          type="button"
                          onClick={() => setQuestions((qs) => qs.filter((_, i) => i !== qi))}
                          className="text-slate-500 hover:text-alert"
                        >
                          <Trash2 size={15} />
                        </button>
                      )}
                    </div>
                  </div>

                  <input
                    value={q.question_text}
                    onChange={(e) => updateQuestion(qi, { question_text: e.target.value })}
                    placeholder={`Question ${qi + 1}`}
                    className="w-full rounded-md border border-border bg-surface px-2.5 py-1.5 text-sm text-slate-100 outline-none focus:border-accent/50"
                  />

                  {isBlank ? (
                    <div className="mt-2">
                      <label className="mb-1 block text-[11px] text-slate-500">
                        Accepted answer — graded case-insensitively, ignoring surrounding spaces
                      </label>
                      <input
                        value={q.correct_text_answer}
                        onChange={(e) =>
                          updateQuestion(qi, { correct_text_answer: e.target.value })
                        }
                        placeholder="HyperText Transfer Protocol"
                        className="w-full rounded-md border border-border bg-surface px-2.5 py-1.5 text-sm text-slate-100 outline-none focus:border-accent/50"
                      />
                    </div>
                  ) : (
                    <>
                      <div className="mt-2 grid grid-cols-2 gap-2">
                        {q.options.map((opt, oi) => (
                          <label key={oi} className="flex items-center gap-2 rounded-md border border-border bg-surface px-2.5 py-1.5">
                            <input
                              type="radio"
                              name={`correct-${qi}`}
                              checked={q.correct_option === oi}
                              onChange={() => updateQuestion(qi, { correct_option: oi })}
                              className="accent-accent"
                            />
                            <input
                              value={opt}
                              onChange={(e) => updateOption(qi, oi, e.target.value)}
                              placeholder={`Option ${oi + 1}`}
                              className="w-full bg-transparent text-sm text-slate-200 outline-none"
                            />
                          </label>
                        ))}
                      </div>
                      <p className="mt-1.5 flex items-center gap-1 text-[11px] text-slate-500">
                        <Radio size={11} /> Select the radio button next to the correct option
                      </p>
                    </>
                  )}
                </div>
                );
              })}
            </div>
          </div>
        </div>

        <div className="flex justify-end gap-2 border-t border-border px-5 py-3">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button onClick={handleSave} disabled={saving || !title.trim()}>
            {saving ? "Saving…" : isEdit ? "Save changes" : "Save exam"}
          </Button>
        </div>
      </div>
    </div>
  );
}

export function ExamManager() {
  const [exams, setExams] = useState<(ExamRow & { question_count: number })[]>([]);
  const [createOpen, setCreateOpen] = useState(false);
  const [editing, setEditing] = useState<ExamRow | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  async function loadExams() {
    setLoading(true);

    const [examsRes, questionsRes] = await Promise.all([
      supabase.from("exams").select("*").order("created_at", { ascending: false }),
      supabase.from("questions").select("exam_id"),
    ]);

    const failure = examsRes.error ?? questionsRes.error;
    if (failure) {
      setError(failure.message);
      setLoading(false);
      return;
    }

    const counts: Record<string, number> = {};
    (questionsRes.data ?? []).forEach((q) => {
      counts[q.exam_id] = (counts[q.exam_id] ?? 0) + 1;
    });

    setError(null);
    setExams(
      ((examsRes.data as ExamRow[]) ?? []).map((e) => ({
        ...e,
        question_count: counts[e.id] ?? 0,
      }))
    );
    setLoading(false);
  }

  useEffect(() => { loadExams(); }, []);

  async function togglePublish(exam: ExamRow) {
    setError(null);
    const { error: updateError } = await supabase
      .from("exams")
      .update({ is_published: !exam.is_published })
      .eq("id", exam.id);

    if (updateError) {
      // A refused write used to be silent: the badge simply did not change.
      setError(`Could not update "${exam.title}": ${updateError.message}`);
      return;
    }
    await loadExams();
  }

  async function deleteExam(exam: ExamRow) {
    if (
      !confirm(
        `Delete "${exam.title}" and all of its questions? Any recorded attempts and their proctoring evidence go with it.`
      )
    ) {
      return;
    }

    setError(null);
    const { error: deleteError } = await supabase.from("exams").delete().eq("id", exam.id);
    if (deleteError) {
      setError(`Could not delete "${exam.title}": ${deleteError.message}`);
      return;
    }
    await loadExams();
  }

  return (
    <div className="p-6">
      <div className="mb-6 flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-slate-100">Exams</h1>
          <p className="text-sm text-slate-500">Create and manage exams and question banks</p>
        </div>
        <Button onClick={() => setCreateOpen(true)}><Plus size={15} /> Create exam</Button>
      </div>

      {error && (
        <div className="mb-4 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
          {error}
        </div>
      )}

      <Card>
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs text-slate-500">
              <th className="px-4 py-2.5 font-medium">Title</th>
              <th className="px-4 py-2.5 font-medium">Duration</th>
              <th className="px-4 py-2.5 font-medium">Questions</th>
              <th className="px-4 py-2.5 font-medium">Status</th>
              <th className="px-4 py-2.5 font-medium text-right">Actions</th>
            </tr>
          </thead>
          <tbody>
            {loading && <TableSkeleton rows={3} columns={5} />}
            {!loading && exams.length === 0 && (
              <tr><td colSpan={5} className="px-4 py-6 text-center text-slate-500">No exams yet — create one to get started.</td></tr>
            )}
            {exams.map((exam) => (
              <tr key={exam.id} className="border-b border-border last:border-0 hover:bg-white/[0.02]">
                <td className="px-4 py-2.5 font-medium text-slate-200">{exam.title}</td>
                <td className="px-4 py-2.5 text-slate-400">{exam.duration_minutes} min</td>
                <td className="px-4 py-2.5 text-slate-400">{exam.question_count}</td>
                <td className="px-4 py-2.5">
                  <button onClick={() => togglePublish(exam)}>
                    <Badge tone={exam.is_published ? "ongoing" : "neutral"}>
                      {exam.is_published ? "Published" : "Draft"}
                    </Badge>
                  </button>
                </td>
                <td className="px-4 py-2.5">
                  <div className="flex justify-end gap-1">
                    <Link to={`/exams/${exam.id}/monitor`}>
                      <Button variant="ghost" size="icon" title="Live monitor"><Monitor size={15} /></Button>
                    </Link>
                    <Button
                      variant="ghost"
                      size="icon"
                      title="Edit exam and its questions"
                      onClick={() => setEditing(exam)}
                    >
                      <Pencil size={15} />
                    </Button>
                    <Button variant="ghost" size="icon" title="Delete" onClick={() => deleteExam(exam)}>
                      <Trash2 size={15} className="text-alert" />
                    </Button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>

      {createOpen && (
        <ExamFormModal onClose={() => setCreateOpen(false)} onSaved={loadExams} />
      )}
      {editing && (
        <ExamFormModal
          exam={editing}
          onClose={() => setEditing(null)}
          onSaved={loadExams}
        />
      )}
    </div>
  );
}
