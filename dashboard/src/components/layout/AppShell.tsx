import type { ReactNode } from "react";
import { Sidebar } from "./Sidebar";
import { useAuth } from "@/hooks/useAuth";

export function AppShell({ children }: { children: ReactNode }) {
  const { profile } = useAuth();

  return (
    <div className="min-h-screen bg-surface">
      <Sidebar userName={profile?.name ?? "Supervisor"} userEmail={profile?.email ?? ""} />
      <main className="ml-56 min-h-screen">{children}</main>
    </div>
  );
}
