import { NavLink } from "react-router-dom";
import { LayoutDashboard, ClipboardList, BarChart3, Settings, Circle } from "lucide-react";
import { cn } from "@/lib/utils";
import { useRealtimeStatus } from "@/hooks/useRealtimeStatus";

const navItems = [
  { to: "/", label: "Dashboard", icon: LayoutDashboard, end: true },
  { to: "/exams", label: "Exams", icon: ClipboardList },
  { to: "/analytics", label: "Analytics", icon: BarChart3 },
  { to: "/settings", label: "Settings", icon: Settings },
];

export function Sidebar({ userName, userEmail }: { userName: string; userEmail: string }) {
  const status = useRealtimeStatus();

  return (
    <aside className="fixed inset-y-0 left-0 z-30 flex w-56 flex-col border-r border-border bg-surface-raised">
      <div className="flex h-14 items-center gap-2 border-b border-border px-4">
        <div className="h-2 w-2 rounded-full bg-accent shadow-glow" />
        <span className="text-sm font-semibold tracking-tight text-slate-100">Proctor</span>
      </div>

      <nav className="flex-1 space-y-0.5 px-2 py-3">
        {navItems.map(({ to, label, icon: Icon, end }) => (
          <NavLink
            key={to}
            to={to}
            end={end}
            className={({ isActive }) =>
              cn(
                "flex items-center gap-2.5 rounded-md px-3 py-2 text-sm transition-colors",
                isActive
                  ? "bg-white/5 text-slate-100"
                  : "text-slate-400 hover:bg-white/5 hover:text-slate-200"
              )
            }
          >
            <Icon size={16} strokeWidth={2} />
            {label}
          </NavLink>
        ))}
      </nav>

      <div className="border-t border-border px-3 py-2">
        <div className="flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs">
          <Circle
            size={7}
            className={cn(
              "fill-current",
              status === "connected" ? "text-ok animate-pulseDot" : "text-warn"
            )}
          />
          <span className="text-slate-500">
            {status === "connected" ? "Realtime connected" : "Reconnecting…"}
          </span>
        </div>
      </div>

      <div className="flex items-center gap-2 border-t border-border p-3">
        <div className="flex h-8 w-8 items-center justify-center rounded-full bg-accent/15 text-xs font-semibold text-accent">
          {userName.slice(0, 1).toUpperCase()}
        </div>
        <div className="min-w-0">
          <p className="truncate text-xs font-medium text-slate-200">{userName}</p>
          <p className="truncate text-[11px] text-slate-500">{userEmail}</p>
        </div>
      </div>
    </aside>
  );
}
