import type { LucideIcon } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";

/**
 * One headline number with its icon.
 *
 * Extracted from `DashboardOverview` so the dashboard and the analytics page
 * render the same card (the value is `tabular-nums` so digits do not jitter as
 * a live count changes). The icon is decorative — the label already names the
 * metric — so it is hidden from assistive tech.
 */
export function MetricCard({
  label,
  value,
  icon: Icon,
  tone = "default",
}: {
  label: string;
  value: string;
  icon: LucideIcon;
  tone?: "default" | "alert";
}) {
  return (
    <Card>
      <CardContent className="flex items-center justify-between p-4">
        <div className="min-w-0">
          <p className="text-xs font-medium text-slate-500">{label}</p>
          <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-100">{value}</p>
        </div>
        <div
          aria-hidden
          className={cn(
            "flex h-9 w-9 shrink-0 items-center justify-center rounded-md",
            tone === "alert" ? "bg-alert/15 text-alert" : "bg-accent/15 text-accent"
          )}
        >
          <Icon size={18} />
        </div>
      </CardContent>
    </Card>
  );
}
