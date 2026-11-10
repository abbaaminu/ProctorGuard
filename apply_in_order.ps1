# Copies each migration to the clipboard, in README order. Run from the repo root.
# It does NOT connect to Supabase. You paste into the SQL Editor of the TEST project.
$files = @(
 'session_reset_logs',
 'question_types_and_grading',
 'optional_exam_scheduling',
 'private_proctor_snapshots',
 'academic_targeting',
 'profile_identity_numbers',
 'strict_targeting_null_profiles',
 '20261103090000_guard_profile_labels',
 '20261103090100_student_can_access_exam',
 '20261103090200_exams_select',
 '20261103090300_questions_public',
 '20261103090400_submissions_insert_own_ongoing',
 '20261103090500_snapshot_read_policy',
 '20261103090600_submissions_delete_supervisor',
 '20261103090700_register_violation_snapshot_path',
 '20261103090800_snapshot_purge_not_live_attempt',
 '20261104090000_violation_weights',
 '20261104090100_weighted_strikes_and_flagged_review',
 'optional_question_shuffling',
 '20261105090000_proctor_heartbeats',
 'retention_policy',
 '20261106090000_proctoring_consents',
 '20261106090100_snapshot_retention',
 '20261108090000_looking_away_and_noise_count',
 '20261109090000_supervisor_exam_assignments',
 '20261110090000_supervisor_student_arm',
 '20261110090100_snapshot_orphan_check'
)
$i = 0
foreach ($f in $files) {
  $i++
  $path = "supabase\migrations\$f.sql"
  if (-not (Test-Path $path)) { Write-Host "MISSING: $path" -ForegroundColor Red; break }
  Get-Content $path -Raw | Set-Clipboard
  Read-Host "[$i/$($files.Count)] Copied $f.sql. In the 'ab test' project: new tab, paste, Run, check for a red error, then press Enter"
}