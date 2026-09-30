import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { supabase } from "@/lib/supabase";
import type { ProfileRow, UserRole } from "@/types/database";

/**
 * The roles this console serves — `is_staff()` in `supabase/schema.sql`. A
 * student can sign in, but is blocked below rather than shown staff-scoped data.
 */
const STAFF_ROLES: readonly UserRole[] = ["admin", "lecturer", "supervisor"];

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

  async function loadProfile() {
    const { data: sessionData } = await supabase.auth.getSession();
    const userId = sessionData.session?.user.id;
    if (!userId) {
      setProfile(null);
      setLoading(false);
      return;
    }

    const { data, error: profileError } = await supabase
      .from("profiles")
      .select("*")
      .eq("id", userId)
      .single();

    if (profileError || !data) {
      setError("Could not load your profile.");
      setProfile(null);
    } else if (!STAFF_ROLES.includes(data.role)) {
      // Role guard: authenticated but a student -> block access rather than
      // silently showing staff-scoped data. RLS would already withhold the rows;
      // this is what turns that into a sentence instead of empty panels.
      setError("This console is restricted to staff accounts.");
      setProfile(null);
    } else {
      setProfile(data as ProfileRow);
      setError(null);
    }
    setLoading(false);
  }

  useEffect(() => {
    loadProfile();
    const { data: sub } = supabase.auth.onAuthStateChange(() => loadProfile());
    return () => sub.subscription.unsubscribe();
  }, []);

  async function signIn(email: string, password: string) {
    setError(null);
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
    if (signInError) {
      setError(signInError.message);
      throw signInError;
    }
  }

  async function signOut() {
    await supabase.auth.signOut();
    setProfile(null);
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
