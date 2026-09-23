import { createClient } from "@supabase/supabase-js";
import type { Database } from "@/types/database";

const url = import.meta.env.VITE_SUPABASE_URL as string;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

if (!url || !anonKey) {
  // Fail loudly at boot rather than producing confusing runtime errors
  // deep inside a realtime subscription.
  throw new Error(
    "Missing VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY — copy .env.example to .env.local"
  );
}

export const supabase = createClient<Database>(url, anonKey, {
  realtime: { params: { eventsPerSecond: 10 } },
});
