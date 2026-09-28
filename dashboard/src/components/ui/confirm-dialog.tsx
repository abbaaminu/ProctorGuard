import { useEffect, useId, useRef, type ReactNode } from "react";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";

interface ConfirmDialogProps {
  open: boolean;
  title: string;
  /**
   * What will actually happen. This is the reason the console uses a real
   * dialog instead of `window.confirm` for a reset: a destructive action can
   * enumerate its own blast radius (how many incidents, how many images) before
   * the click, which a one-line browser prompt cannot.
   */
  children: ReactNode;
  /** Label of the destructive action, e.g. "Reset attempt". */
  confirmLabel: string;
  /** Label shown while the write is in flight. */
  busyLabel?: string;
  busy?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * Modal confirmation for a destructive supervisor action - the console's second
 * modal after `LiveMonitor`'s snapshot viewer, and the first one that has to hold
 * focus and swallow keys.
 *
 * Hand-rolled against the same primitives as the rest of the console (`Button`,
 * the surface/border tokens) rather than reaching for `@radix-ui/react-dialog`,
 * which is in `package.json` but imported nowhere: the behaviour that actually
 * matters here is small and explicit - Escape and a backdrop click cancel, focus
 * starts on **Cancel**, and neither is possible while a request is in flight.
 */
export function ConfirmDialog({
  open,
  title,
  children,
  confirmLabel,
  busyLabel = "Working…",
  busy = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const titleId = useId();
  const bodyId = useId();
  const cancelButtonRef = useRef<HTMLButtonElement>(null);

  // Latest callbacks held in refs, for the same reason `Toast` does it: the
  // parent re-renders while the request hangs, and re-subscribing the key
  // listener on every one of those renders would be pointless churn.
  const onCancelRef = useRef(onCancel);
  const onConfirmRef = useRef(onConfirm);
  useEffect(() => {
    onCancelRef.current = onCancel;
    onConfirmRef.current = onConfirm;
  });

  useEffect(() => {
    if (!open) return;

    function handleKeyDown(event: KeyboardEvent) {
      // Not while the write is in flight: the request is already on its way and
      // closing the dialog would only hide what happened.
      if (event.key === "Escape" && !busy) onCancelRef.current();
    }

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [open, busy]);

  // Focus starts on *Cancel*, not on the destructive button, so a stray Enter on
  // a dialog that just appeared cannot clear an attempt.
  useEffect(() => {
    if (open) cancelButtonRef.current?.focus();
  }, [open]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4"
      onClick={() => {
        if (!busy) onCancelRef.current();
      }}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={bodyId}
        className="animate-rowIn w-full max-w-md rounded-lg border border-border bg-surface-raised p-4 shadow-lg shadow-black/40"
        onClick={(event) => event.stopPropagation()}
      >
        <h2 id={titleId} className="text-sm font-semibold text-slate-100">
          {title}
        </h2>
        <div id={bodyId} className="mt-2 space-y-2 text-sm text-slate-400">
          {children}
        </div>
        <div className="mt-4 flex justify-end gap-2">
          <Button
            ref={cancelButtonRef}
            type="button"
            variant="outline"
            size="sm"
            disabled={busy}
            onClick={() => onCancelRef.current()}
          >
            Cancel
          </Button>
          <Button
            type="button"
            variant="destructive"
            size="sm"
            disabled={busy}
            onClick={() => onConfirmRef.current()}
          >
            {busy && <Loader2 size={13} className="animate-spin" />}
            {busy ? busyLabel : confirmLabel}
          </Button>
        </div>
      </div>
    </div>
  );
}
