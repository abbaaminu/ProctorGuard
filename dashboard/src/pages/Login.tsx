import { useState, type FormEvent } from "react";
import { ShieldAlert, Loader2 } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { Button } from "@/components/ui/button";

export function LoginPage() {
  const { signIn, error } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSubmitting(true);
    setLocalError(null);
    try {
      await signIn(email, password);
    } catch {
      // error surfaced via useAuth().error
    } finally {
      setSubmitting(false);
    }
  }

  const displayError = localError ?? error;

  return (
    <div className="flex min-h-screen items-center justify-center bg-surface px-4">
      <div className="w-full max-w-sm">
        <div className="mb-8 flex items-center gap-2">
          <div className="h-2.5 w-2.5 rounded-full bg-accent shadow-glow" />
          <span className="text-base font-semibold text-slate-100">Proctor Console</span>
        </div>

        <div className="rounded-lg border border-border bg-surface-raised p-6">
          <h1 className="text-lg font-semibold text-slate-100">Supervisor sign in</h1>
          <p className="mt-1 text-sm text-slate-500">
            Access is restricted to supervisor accounts.
          </p>

          {displayError && (
            <div className="mt-4 flex items-start gap-2 rounded-md border border-alert/30 bg-alert/10 px-3 py-2 text-sm text-alert">
              <ShieldAlert size={16} className="mt-0.5 shrink-0" />
              <span>{displayError}</span>
            </div>
          )}

          <form onSubmit={handleSubmit} className="mt-5 space-y-3">
            <div>
              <label className="mb-1 block text-xs font-medium text-slate-400">Email</label>
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="w-full rounded-md border border-border bg-surface-inset px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50"
                placeholder="you@company.com"
              />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-slate-400">Password</label>
              <input
                type="password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full rounded-md border border-border bg-surface-inset px-3 py-2 text-sm text-slate-100 outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/50"
                placeholder="••••••••"
              />
            </div>
            <Button type="submit" disabled={submitting} className="w-full">
              {submitting && <Loader2 size={14} className="animate-spin" />}
              Sign in
            </Button>
          </form>
        </div>
      </div>
    </div>
  );
}
