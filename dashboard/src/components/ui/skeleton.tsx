import type { HTMLAttributes, ReactNode } from "react";
import { cn } from "@/lib/utils";
import { Card, CardContent, CardHeader } from "@/components/ui/card";

/**
 * Pulsing placeholder for a panel that is fetching its own data.
 *
 * Skeletons are `aria-hidden`; the group that wraps them carries
 * `role="status"`, so a screen reader announces "Loading <thing>" once instead
 * of a dozen meaningless boxes.
 *
 * Nothing in here blocks: every page renders its real layout — headers, grids,
 * panels — and only the *values* inside it pulse, so switching pages or waiting
 * on a slow query never covers the console.
 */
export function Skeleton({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      aria-hidden
      className={cn("animate-pulse rounded-md bg-slate-800/50", className)}
      {...props}
    />
  );
}

/** Wraps a group of skeletons with the status semantics for screen readers. */
export function SkeletonGroup({
  label,
  className,
  children,
}: {
  label: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      role="status"
      aria-busy="true"
      aria-label={label}
      className={className}
    >
      <span className="sr-only">{label}</span>
      {children}
    </div>
  );
}

/** Two or three pulsing text lines. */
export function SkeletonText({
  lines = 2,
  className,
}: {
  lines?: number;
  className?: string;
}) {
  return (
    <div className={cn("space-y-2", className)}>
      {Array.from({ length: lines }).map((_, index) => (
        <Skeleton
          key={index}
          className={cn("h-3", index === lines - 1 ? "w-2/3" : "w-full")}
        />
      ))}
    </div>
  );
}

/** Mirrors `MetricCard` in DashboardOverview so the layout never shifts. */
export function MetricCardSkeleton() {
  return (
    <Card>
      <CardContent className="flex items-center justify-between p-4">
        <div className="space-y-2">
          <Skeleton className="h-3 w-24" />
          <Skeleton className="h-7 w-12" />
        </div>
        <Skeleton className="h-9 w-9" />
      </CardContent>
    </Card>
  );
}

/** Mirrors a chart panel (header + plot area). */
export function ChartSkeleton({ bars = 7 }: { bars?: number }) {
  const heights = [40, 65, 30, 80, 55, 70, 45, 60, 35];

  return (
    <Card>
      <CardHeader>
        <Skeleton className="h-4 w-44" />
      </CardHeader>
      <CardContent className="flex h-64 items-end gap-3">
        {Array.from({ length: bars }).map((_, index) => (
          <Skeleton
            key={index}
            className="flex-1"
            style={{ height: `${heights[index % heights.length]}%` }}
          />
        ))}
      </CardContent>
    </Card>
  );
}

/** Mirrors a candidate card in the live monitor's roster. */
export function CandidateCardSkeleton() {
  return (
    <Card>
      <CardContent className="p-3.5">
        <div className="mb-2 flex items-center justify-between gap-2">
          <Skeleton className="h-4 w-32" />
          <Skeleton className="h-5 w-20 rounded-md" />
        </div>
        <div className="flex items-center justify-between">
          <Skeleton className="h-3 w-16" />
          <Skeleton className="h-3 w-14" />
        </div>
        <div className="mt-3 flex items-center gap-2">
          <Skeleton className="h-3 w-12" />
          <Skeleton className="ml-auto h-8 w-28 rounded-md" />
        </div>
      </CardContent>
    </Card>
  );
}

/** Mirrors one row of the live incident feed. */
export function FeedRowSkeleton() {
  return (
    <div className="flex items-start gap-2.5 border-b border-border px-4 py-3">
      <Skeleton className="mt-0.5 h-4 w-4 shrink-0" />
      <div className="min-w-0 flex-1 space-y-2">
        <div className="flex items-center justify-between">
          <Skeleton className="h-3.5 w-28" />
          <Skeleton className="h-3 w-14" />
        </div>
        <Skeleton className="h-3 w-40" />
      </div>
    </div>
  );
}

/** Mirrors the exam table in ExamManager (header row stays real). */
export function TableSkeleton({
  rows = 3,
  columns = 5,
}: {
  rows?: number;
  columns?: number;
}) {
  return (
    <>
      {Array.from({ length: rows }).map((_, rowIndex) => (
        <tr key={rowIndex} className="border-b border-border last:border-0">
          {Array.from({ length: columns }).map((__, columnIndex) => (
            <td key={columnIndex} className="px-4 py-3">
              <Skeleton
                className={cn(
                  "h-3.5",
                  columnIndex === 0 ? "w-40" : columnIndex === columns - 1 ? "ml-auto w-24" : "w-16"
                )}
              />
            </td>
          ))}
        </tr>
      ))}
    </>
  );
}

/**
 * The console's own placeholder, shown only while the *session* is being
 * resolved (the first render after a refresh). It reproduces the real page
 * chrome — title, metric row, two panels — so nothing jumps when the data
 * lands, and it never covers the sidebar or the header.
 */
export function PageSkeleton() {
  return (
    <div className="p-6">
      <Skeleton className="h-5 w-32" />
      <Skeleton className="mt-2 h-4 w-72" />

      <SkeletonGroup label="Loading dashboard metrics" className="mt-6 grid grid-cols-4 gap-4">
        <MetricCardSkeleton />
        <MetricCardSkeleton />
        <MetricCardSkeleton />
        <MetricCardSkeleton />
      </SkeletonGroup>

      <div className="mt-6 grid grid-cols-2 gap-4">
        <ChartSkeleton />
        <ChartSkeleton bars={4} />
      </div>
    </div>
  );
}