import type { ReactNode } from "react";
import { Sidebar } from "./Sidebar";
import { useAuth } from "@/hooks/useAuth";

/**
 * The console chrome: fixed sidebar plus the page area.
 *
 * `profilePending` only affects the sidebar's profile tile (skeleton instead of a
 * name) — the layout itself is static and always renders, so a slow session
 * check never blanks the screen.
 */
export function AppShell({
  children,
  profilePending = false,
}: {
  children: ReactNode;
  profilePending?: boolean;
}) {
  const { profile } = useAuth();

  return (
    <div className="min-h-screen bg-surface">
      <Sidebar
        userName={profile?.name ?? "Supervisor"}
        userEmail={profile?.email ?? ""}
        pending={profilePending}
      />
      <main className="ml-56 min-h-screen">{children}</main>
    </div>
  );
}
