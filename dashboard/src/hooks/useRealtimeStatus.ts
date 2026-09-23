import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

type Status = "connected" | "reconnecting";

/// Watches the shared Realtime socket's connection state (not any single
/// channel's subscription state) so the sidebar pill reflects the actual
/// WebSocket health — a channel can be SUBSCRIBED while the underlying
/// socket is mid-reconnect after a network blip.
///
/// Note: `@supabase/realtime-js` v2.116 dropped the `onOpen` / `onClose` /
/// `onError` callbacks from the public client API (they now live on the
/// internal socket adapter), so this polls the supported
/// `isConnected()` / `connectionState()` accessors instead.
export function useRealtimeStatus(): Status {
  const [status, setStatus] = useState<Status>("connected");

  useEffect(() => {
    const socket = supabase.realtime;

    const sync = () => {
      setStatus(socket.isConnected() ? "connected" : "reconnecting");
    };

    sync();
    const interval = setInterval(sync, 3000);

    return () => clearInterval(interval);
  }, []);

  return status;
}

