import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { supabase } from "@/lib/supabase";
import type { ProfileRow, UserRole } from "@/types/database";

/**
 * The roles this console serves — `is_staff()` in `supabase/schema.sql`. A
 * student can sign in, but is blocked below rather than shown staff-scoped data.
 */
const STAFF_ROLES: readonly UserRole[] = ["admin", "lecturer", "supervisor"];

/**
 * PostgREST / GoTrue codes that mean "this session is not allowed to do that".
 *
 * `42501` is `insufficient_privilege` — an RLS policy (or the
 * `profiles_guard_role_change` trigger) refusing the statement. `PGRST301` /
 * `PGRST302` are PostgREST's own "the JWT expired" / "no JWT was sent" answers.
 * All three are terminal: retrying with the same session cannot succeed.
 */
const PERMISSION_CODES = new Set(["42501", "PGRST301", "PGRST302"]);

/** The two error shapes these calls can answer with (`AuthError`, `PostgrestError`). */
interface QueryError {
  message?: string;
  code?: string | null;
}

interface ProfileResult {
  profile: ProfileRow | null;
  /** A sentence for the user, or null when the profile loaded. */
  message: string | null;
  /**
   * The account itself is the problem — no profile row, a refused read, or a
   * non-staff role — so re-reading with the same session cannot help, and the
   * session should be ended rather than left dangling behind the login form.
   */
  fatal: boolean;
}

function isPermissionError(code: string | null | undefined): boolean {
  return code != null && PERMISSION_CODES.has(code);
}

/**
 * Turns an `auth.signInWithPassword` failure into a sentence a staff member can
 * act on, so a raw GoTrue string ("Invalid login credentials", the body of a 400
 * Bad Request) never reaches the form.
 *
 * The credential failure is deliberately *one* sentence for a wrong password, a
 * non-existent email and a stale account: the server refuses to say which emails
 * exist, and the form must not become an oracle for that either.
 */
function authErrorMessage(error: QueryError): string {
  const code = (error.code ?? "").toLowerCase();
  const message = (error.message ?? "").trim();
  const lower = message.toLowerCase();
  const matches = (...needles: string[]) =>
    needles.some((needle) => code.includes(needle) || lower.includes(needle));

  if (matches("invalid_credentials", "invalid login credentials", "user_not_found")) {
    return "Incorrect email or password.";
  }
  if (matches("email_not_confirmed", "email not confirmed")) {
    return "Confirm your email address first — check your inbox for the link.";
  }
  if (matches("over_email_send_rate_limit", "rate limit", "too many")) {
    return "Too many attempts. Wait a minute and try again.";
  }
  return message || "Sign-in failed. Check your email and password and try again.";
}

interface AuthState {
  loading: boolean;
  profile: ProfileRow | null;
  error: string | null;
  signIn: (email: string, password: string) => Promise<void>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [profile, setProfile] = useState<ProfileRow | null>(null);
  const [error, setError] = useState<string | null>(null);

  /** Guards every async setState against landing after unmount. */
  const mountedRef = useRef(true);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  /**
   * Read `public.profiles` for one authenticated user and decide whether this
   * console can serve them.
   *
   * `maybeSingle()` where a `single()` used to be: an account with no profile row
   * is an ordinary zero-row answer, not the `PGRST116` error `single()` raises
   * for it — which is what keeps "there is no row" distinguishable from "the read
   * was refused", the two cases this console has to say different things about.
   */
  const readProfile = useCallback(
    async (userId: string): Promise<ProfileResult> => {
      let data: ProfileRow | null = null;
      let readError: QueryError | null = null;
      try {
        const response = await supabase
          .from("profiles")
          .select("*")
          .eq("id", userId)
          .maybeSingle();
        readError = response.error;
        data = (response.data as ProfileRow | null) ?? null;
      } catch {
        // postgrest-js answers HTTP failures with `{ error }`, so reaching here
        // means the request never got an answer at all (offline, DNS, a blocked
        // origin). Nothing raw is worth showing a user — say what to do instead.
        return {
          profile: null,
          fatal: false,
          message: "Could not reach the server. Check your connection and try again.",
        };
      }

      if (readError) {
        if (isPermissionError(readError.code)) {
          return {
            profile: null,
            fatal: true,
            message:
              "This account is not allowed to read its profile. Ask an administrator to check your access.",
          };
        }
        return {
          profile: null,
          fatal: false,
          message: "Could not load your profile. Check your connection and try again.",
        };
      }

      if (!data) {
        return {
          profile: null,
          fatal: true,
          message:
            "This account has no profile yet. Ask an administrator to finish setting it up.",
        };
      }

      if (!STAFF_ROLES.includes(data.role)) {
        // Role guard: authenticated but a student -> block access rather than
        // silently showing staff-scoped data. RLS would already withhold the rows;
        // this is what turns that into a sentence instead of empty panels.
        return {
          profile: null,
          fatal: true,
          message:
            "This console is restricted to staff accounts — supervisor, lecturer or admin.",
        };
      }

      return { profile: data, fatal: false, message: null };
    },
    []
  );

  /**
   * Keyed by auth user id so the two things that trigger a read for one sign-in
   * — the submit handler and the SDK's `SIGNED_IN` event — share a single query
   * instead of racing each other.
   */
  const pendingRef = useRef<{ userId: string; promise: Promise<void> } | null>(null);

  const loadProfileForUser = useCallback(
    (userId: string): Promise<void> => {
      const pending = pendingRef.current;
      if (pending && pending.userId === userId) return pending.promise;

      const promise = (async () => {
        const result = await readProfile(userId);

        // An account this console cannot serve (no row, a refused read, a
        // student) would otherwise keep its session, and a login form drawn over
        // a live session is one that can never succeed: every retry re-fails and
        // every refresh loops the same message. Ending the session is the
        // signing-out half of RoleGate's *Sign out* escape hatch
        // (mobile/lib/features/auth/.../role_gate.dart), done here because this
        // console shows a login screen rather than a dedicated error page.
        if (result.fatal) {
          await supabase.auth.signOut().catch(() => {
            // A failed sign-out is not fatal in itself — the next read retries
            // it — and the message below is shown either way.
          });
        }

        if (!mountedRef.current) return;
        setProfile(result.profile);
        setError(result.message);
        setLoading(false);
      })();

      pendingRef.current = { userId, promise };
      void promise
        .finally(() => {
          if (pendingRef.current?.promise === promise) pendingRef.current = null;
        })
        .catch(() => {});

      return promise;
    },
    [readProfile]
  );

  /**
   * Resolve the current session and hand it to `loadProfileForUser`. The session
   * read and the profile read are the two places a *raw* Supabase error used to
   * reach the screen, so both are answered with a sentence here.
   */
  const loadProfile = useCallback(async () => {
    let userId: string | null = null;
    let sessionError: QueryError | null = null;
    try {
      const { data, error: getSessionError } = await supabase.auth.getSession();
      sessionError = getSessionError;
      userId = data.session?.user.id ?? null;
    } catch {
      sessionError = { message: "session lookup failed" };
    }

    if (sessionError) {
      if (!mountedRef.current) return;
      setProfile(null);
      setError("Could not verify your session. Sign in again.");
      setLoading(false);
      return;
    }

    if (!userId) {
      // Signed out. Any message already on screen is left alone on purpose: a
      // sign-out performed by `loadProfileForUser` is explained by the message
      // that accompanies it, and clearing it here would erase the reason.
      if (!mountedRef.current) return;
      setProfile(null);
      setLoading(false);
      return;
    }

    await loadProfileForUser(userId);
  }, [loadProfileForUser]);

  useEffect(() => {
    void loadProfile();

    const { data: sub } = supabase.auth.onAuthStateChange(() => {
      // Deferred onto a fresh task on purpose. The callback runs while the SDK
      // holds its auth lock, and calling `getSession()` — which `loadProfile`
      // does — from inside it is the documented deadlock (and unhandled-rejection
      // source) in supabase-js; by the time the timer fires, the session the read
      // needs is already in storage.
      window.setTimeout(() => void loadProfile(), 0);
    });

    return () => sub.subscription.unsubscribe();
  }, [loadProfile]);

  /**
   * Signs in, then resolves the profile *before* reporting success, so an
   * account the console cannot serve is explained to the form instead of briefly
   * landing in the console (or looping through the auth event).
   */
  async function signIn(email: string, password: string) {
    setError(null);
    const { data, error: signInError } = await supabase.auth.signInWithPassword({
      // Trimmed here as well as in the form: mobile keyboards append a trailing
      // space, and the server compares the address verbatim.
      email: email.trim(),
      password,
    });
    if (signInError) {
      const message = authErrorMessage(signInError);
      if (mountedRef.current) setError(message);
      throw new Error(message);
    }
    if (data.user) {
      await loadProfileForUser(data.user.id);
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    if (!mountedRef.current) return;
    setProfile(null);
    // The message belongs to the account that just left — a fresh login page must
    // not keep saying "restricted to staff accounts" about nobody.
    setError(null);
  }

  return (
    <AuthContext.Provider value={{ loading, profile, error, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used within AuthProvider");
  return ctx;
}
