import { useEffect, useRef } from "react";
import { AlertTriangle, CheckCircle2, X } from "lucide-react";
import { cn } from "@/lib/utils";

export type ToastTone = "ok" | "alert";

const toneBorder: Record<ToastTone, string> = {
  ok: "border-ok/40",
  alert: "border-alert/40",
};

const toneText: Record<ToastTone, string> = {
  ok: "text-ok",
  alert: "text-alert",
};

interface ToastProps {
  /**
   * Identity of this toast. Only a *change* here restarts the countdown, so a
   * parent re-render (the optimistic row flipping, a rollback, a second click)
   * can never extend — or cancel — the timer of the message on screen.
   */
  id: number;
  tone?: ToastTone;
  message: string;
  onDismiss: () => void;
  /** How long the message stays up, in ms. */
  duration?: number;
  className?: string;
}

/**
 * Transient confirmation for a supervisor-initiated write.
 *
 * Deliberately *not* a toast stack: the caller owns one slot, so only one
 * message is ever on screen. The live incident feed keeps its visual ping
 * instead of toasting (`LiveMonitor`), because there a supervisor's eyes are
 * already on the panel and the events never stop arriving; a publish toggle is
 * a one-off action taken from a settings-like page, where a short-lived
 * confirmation is the honest feedback. A *refused* write still lands in the
 * page's inline error banner, which does not disappear while it is being read.
 *
 * The entrance reuses the `rowIn` keyframe from `tailwind.config.ts`;
 * `index.css` already collapses animations under `prefers-reduced-motion`.
 */
export function Toast({
  id,
  tone = "ok",
  message,
  onDismiss,
  duration = 4000,
  className,
}: ToastProps) {
  // Held in a ref: an inline `onDismiss` from the parent is a new function on
  // every render, and putting it in the dependency list below would reset the
  // timer each time the page re-rendered. Updated in an effect (not during
  // render) so the assignment stays out of the render phase; the timeout only
  // ever fires after this committed.
  const dismissRef = useRef(onDismiss);
  useEffect(() => {
    dismissRef.current = onDismiss;
  });

  useEffect(() => {
    const timer = setTimeout(() => dismissRef.current(), duration);
    return () => clearTimeout(timer);
  }, [id, duration]);

  const Icon = tone === "ok" ? CheckCircle2 : AlertTriangle;

  return (
    <div
      role={tone === "alert" ? "alert" : "status"}
      aria-live={tone === "alert" ? "assertive" : "polite"}
      className={cn(
        "animate-rowIn fixed bottom-4 right-4 z-50 flex w-full max-w-sm items-start gap-2.5 rounded-lg border bg-surface-raised px-3.5 py-3 shadow-lg shadow-black/40",
        toneBorder[tone],
        className
      )}
    >
      <Icon size={16} className={cn("mt-0.5 shrink-0", toneText[tone])} />
      <p className="flex-1 text-sm text-slate-200">{message}</p>
      <button
        type="button"
        onClick={onDismiss}
        title="Dismiss"
        className="shrink-0 text-slate-500 transition-colors hover:text-slate-300"
      >
        <X size={15} />
        <span className="sr-only">Dismiss</span>
      </button>
    </div>
  );
}
