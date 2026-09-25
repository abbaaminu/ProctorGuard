import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

/**
 * `connecting` is the honest first state: on mount nothing has been asked of the
 * socket yet, so reporting "connected" until the first poll would be a lie (and
 * `reconnecting` only after a connection was actually established — a browser
 * that never reaches Realtime should read "connecting", not "flapping").
 */
export type RealtimeStatus = "connecting" | "connected" | "reconnecting";

/**
 * Presentation for each status — one source of truth for the sidebar pill and
 * the live-monitor badge, so the two indicators can never disagree.
 *
 * Realtime is a *convenience* on top of on-demand queries, so the wording says
 * what it actually affects: a dropped socket means "incidents will not stream
 * in", never "the console is broken".
 */
export const REALTIME_STATUS_COPY: Record<
  RealtimeStatus,
  { label: string; dot: string; text: string; badge: string; hint: string }
> = {
  connected: {
    label: "Live sync on",
    dot: "text-ok animate-pulseDot",
    text: "text-slate-500",
    badge: "border-ok/30 bg-ok/10 text-ok",
    hint: "Realtime connected — incidents and status changes stream in as they happen.",
  },
  reconnecting: {
    label: "Reconnecting…",
    dot: "text-warn",
    text: "text-warn",
    badge: "border-warn/30 bg-warn/10 text-warn",
    hint: "The Realtime socket dropped and is retrying. Pages still load their data on demand; only live streaming is paused.",
  },
  connecting: {
    label: "Connecting…",
    dot: "text-slate-600",
    text: "text-slate-500",
    badge: "border-border bg-white/5 text-slate-400",
    hint: "Opening the Realtime socket for the first time. Everything else already works.",
  },
};

/// Watches the shared Realtime socket's connection state (not any single
/// channel's subscription state) so the sidebar pill reflects the actual
/// WebSocket health — a channel can be SUBSCRIBED while the underlying
/// socket is mid-reconnect after a network blip.
///
/// The status is *advisory only*: it is a value the shell renders, never a gate,
/// so a dead socket cannot block the console from painting.
///
/// Note: `@supabase/realtime-js` v2.116 dropped the `onOpen` / `onClose` /
/// `onError` callbacks from the public client API (they now live on the
/// internal socket adapter), so this polls the supported
/// `isConnected()` / `connectionState()` accessors instead.
export function useRealtimeStatus(): RealtimeStatus {
  const [status, setStatus] = useState<RealtimeStatus>("connecting");

  useEffect(() => {
    const socket = supabase.realtime;
    let hasBeenConnected = false;

    const sync = () => {
      if (socket.isConnected()) {
        hasBeenConnected = true;
        setStatus("connected");
        return;
      }
      setStatus(hasBeenConnected ? "reconnecting" : "connecting");
    };

    sync();
    const interval = setInterval(sync, 3000);

    return () => clearInterval(interval);
  }, []);

  return status;
}

