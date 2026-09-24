import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { Plus, Radio, Trash2, Monitor, Pencil, X } from "lucide-react";
import { supabase } from "@/lib/supabase";
import { useAuth } from "@/hooks/useAuth";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import type { ExamRow } from "@/types/database";

interface DraftQuestion {
  question_text: string;
  options: string[];
  correct_option: number;
  points: number;
}

function emptyQuestion(): DraftQuestion {
  return { question_text: "", options: ["", "", "", ""], correct_option: 0, points: 1 };
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

    setSaving(true);
    setError(null);

    try {
      if (exam) {
        const { error: updateError } = await supabase
          .from("exams")
          .update({ title: title.trim(), duration_minutes: duration })
          .eq("id", exam.id);
        if (updateError) throw updateError;
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

        const rows = questions
          .filter((q) => q.question_text.trim())
          .map((q) => ({
            exam_id: created.id,
            question_text: q.question_text.trim(),
            options: q.options,
            correct_option: q.correct_option,
            points: q.points,
          }));
        if (rows.length > 0) {
          const { error: qError } = await supabase.from("questions").insert(rows);
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
            {isEdit ? "Edit exam details" : "Create exam"}
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

          {isEdit ? (
            <p className="text-xs leading-relaxed text-slate-500">
              Question editing is not available for an exam that already exists:
              recorded answers reference these rows by id, so replacing them would
              break every submission audit. Create a new exam to change the bank.
            </p>
          ) : (
          <div>
            <div className="mb-2 flex items-center justify-between">
              <span className="text-xs font-medium text-slate-400">Questions</span>
              <Button variant="outline" size="sm" onClick={() => setQuestions((q) => [...q, emptyQuestion()])}>
                <Plus size={14} /> Add question
              </Button>
            </div>

            <div className="space-y-3">
              {questions.map((q, qi) => (
                <div key={qi} className="rounded-md border border-border bg-surface-inset p-3">
                  <div className="mb-2 flex items-center justify-between gap-2">
                    <input
                      value={q.question_text}
                      onChange={(e) => updateQuestion(qi, { question_text: e.target.value })}
                      placeholder={`Question ${qi + 1}`}
                      className="flex-1 rounded-md border border-border bg-surface px-2.5 py-1.5 text-sm text-slate-100 outline-none focus:border-accent/50"
                    />
                    <input
                      type="number"
                      min={1}
                      value={q.points}
                      onChange={(e) => updateQuestion(qi, { points: Number(e.target.value) })}
                      title="Points"
                      className="w-16 rounded-md border border-border bg-surface px-2 py-1.5 text-sm text-slate-100 outline-none focus:border-accent/50"
                    />
                    <button
                      onClick={() => setQuestions((qs) => qs.filter((_, i) => i !== qi))}
                      className="text-slate-500 hover:text-alert"
                    >
                      <Trash2 size={15} />
                    </button>
                  </div>
                  <div className="grid grid-cols-2 gap-2">
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
                </div>
              ))}
            </div>
          </div>
          )}
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
            {loading && (
              <tr><td colSpan={5} className="px-4 py-6 text-center text-slate-500">Loading…</td></tr>
            )}
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
                      title="Edit exam details"
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
