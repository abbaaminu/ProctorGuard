/**
 * `proctoring_logs.action_type` -> student-facing label.
 *
 * Single source of truth for every panel that renders an incident (the live
 * monitor's feed, the dashboard's breakdown chart and the submission audit): the
 * CHECK constraint in `../supabase/schema.sql` is the list of types that can
 * exist, so a new one has to be added here once instead of in three pages.
 *
 * The last six are the enterprise integrity signals: browser exam lockdown
 * (copy/paste, right-click, devtools/open panel), device integrity (a second
 * display or a virtual camera on Android) and inactivity. They are named exactly
 * as the constraint, the mobile `ViolationType` and the offline queue name them,
 * so a queued row replayed later still lands under the right label.
 */
export const INCIDENT_LABELS: Record<string, string> = {
  looking_away: "Looking away",
  multiple_faces: "Multiple faces",
  no_face: "No face",
  app_minimized: "App minimized",
  audio_noise: "Audio noise",
  copy_paste_attempt: "Copy/paste blocked",
  right_click_blocked: "Right-click blocked",
  devtools_detected: "Developer tools",
  secondary_display_detected: "Second display",
  virtual_camera_detected: "Virtual camera",
  idle_afk: "Idle / away",
};

/** Label for one `action_type`, falling back to the raw value. */
export function incidentLabel(actionType: string): string {
  return INCIDENT_LABELS[actionType] ?? actionType;
}
