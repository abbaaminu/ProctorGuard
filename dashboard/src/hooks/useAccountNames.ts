import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import type { ProfileRow } from "@/types/database";

/**
 * `id -> display label` for the accounts this console may read.
 *
 * RLS scopes the rows (`profiles_select_own_or_staff`: staff — admin, lecturer
 * and supervisor — see every profile row, a student only their own), and the
 * roster/incident feed use this to render "Aisha Bello" instead of a raw uuid.
 * It refetches on any `profiles` change rather than patching rows in place,
 * because a profile edit is rare and a handful of rows is cheap.
 */
export function useAccountNames() {
  const [names, setNames] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error: loadError } = await supabase
      .from("profiles")
      .select("id, full_name, email");
    if (loadError) {
      // A display name is a nicety, not the data a panel exists to show — but the
      // fallback ("Student ab12cd34") must never be mistaken for the real name,
      // so the failure is reported instead of silently degrading.
      setError(loadError.message);
      setLoading(false);
      return;
    }
    setError(null);
    const rows =
      (data as Pick<ProfileRow, "id" | "full_name" | "email">[] | null) ?? [];
    setNames(
      Object.fromEntries(
        rows.map((row) => [
          row.id,
          row.full_name?.trim() || row.email || "Unknown account",
        ])
      )
    );
    setLoading(false);
  }, []);

  useEffect(() => {
    let active = true;
    const run = () => {
      if (active) void load();
    };

    run();

    const channel = supabase
      .channel("profiles_names")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "profiles" },
        run
      )
      .subscribe();

    return () => {
      active = false;
      supabase.removeChannel(channel);
    };
  }, [load]);

  return { names, loading, error };
}

