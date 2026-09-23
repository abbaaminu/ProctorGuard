import { cn } from "@/lib/utils";
import type { HTMLAttributes } from "react";

type BadgeTone = "ongoing" | "submitted" | "disqualified" | "neutral";

const toneClasses: Record<BadgeTone, string> = {
  ongoing: "bg-accent/15 text-accent border-accent/30",
  submitted: "bg-sky-500/15 text-sky-400 border-sky-500/30",
  disqualified: "bg-alert/15 text-alert border-alert/30",
  neutral: "bg-slate-500/15 text-slate-300 border-slate-500/30",
};

export function Badge({
  tone = "neutral",
  className,
  children,
  ...props
}: HTMLAttributes<HTMLSpanElement> & { tone?: BadgeTone }) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1 rounded-md border px-2 py-0.5 text-xs font-medium capitalize",
        toneClasses[tone],
        className
      )}
      {...props}
    >
      {children}
    </span>
  );
}

export function statusTone(status: string): BadgeTone {
  if (status === "ongoing") return "ongoing";
  if (status === "submitted") return "submitted";
  if (status === "disqualified") return "disqualified";
  return "neutral";
}
