import { useState } from "react";
import { Loader2, LogOut } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useAuth } from "@/hooks/useAuth";
import { signOutErrorMessage } from "@/lib/api-errors";

/**
 * The session's own control: ends it and returns the console to the login form.
 *
 * WHY IT IS ITS OWN COMPONENT rather than three more lines in `Sidebar`: signing
 * out is a request with three states (idle, in flight, refused), and the sidebar
 * is otherwise markup that only draws the account it is handed. Keeping the
 * state here keeps the refusal sentence next to the button that caused it, and
 * leaves `Sidebar`'s `pending` contract alone — `signOut` needs no profile, so a
 * session still being resolved is still a session you may leave.
 *
 * NO `navigate()` CALL, deliberately. Ending the session *is* the navigation:
 * `useAuth` clears `profile` and `AppRoutes` renders `LoginPage` whenever there
 * is none, so this component unmounts in that same render — which is why
 * `pending` is reset only on the failure path below.
 *
 * A REFUSAL IS SHOWN INLINE rather than in a toast: it is the one message on
 * this screen that has to wait for its reader, and the likeliest reason for it
 * is a connection that would make a toast unreliable too — while a session that
 * is still live must never be left on screen unexplained. Retrying the button is
 * the dismissal path: the message clears at the start of the next attempt. In
 * the same spirit the label changes to *Signing out…* and the button disables
 * itself, so a second click cannot race the first.
 */
export function SignOutButton({ className }: { className?: string }) {
  const { signOut } = useAuth();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSignOut() {
    setPending(true);
    setError(null);
    try {
      await signOut();
    } catch (failure) {
      setError(signOutErrorMessage(failure));
      setPending(false);
    }
  }

  return (
    <div className={className}>
      <Button
        type="button"
        variant="ghost"
        size="sm"
        disabled={pending}
        aria-busy={pending}
        onClick={handleSignOut}
        /* Laid out like the nav rows above it (`gap-2.5`, `px-3`, the muted
           slate the inactive links use) so the footer reads as one more console
           action rather than a widget dropped into the sidebar. */
        className="w-full justify-start gap-2.5 px-3 text-slate-400 hover:text-slate-200"
      >
        {pending ? (
          <Loader2 size={15} className="animate-spin" />
        ) : (
          <LogOut size={15} strokeWidth={2} />
        )}
        {pending ? "Signing out…" : "Sign out"}
      </Button>

      {error && (
        <p
          role="alert"
          className="mt-1.5 rounded-md border border-alert/30 bg-alert/10 px-2 py-1.5 text-[11px] leading-snug text-alert"
        >
          {error}
        </p>
      )}
    </div>
  );
}
