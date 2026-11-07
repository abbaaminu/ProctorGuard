<#
  Applies the ProctorGuard migrations to the project the Supabase CLI is LINKED to, in README order.
  Run it yourself, from the repo root, after a backup. It stops at the first error.
  Resume after a fix with:  .\apply_live_cli.ps1 -StartAt 12
  It never runs db push, db reset or secrets set.
#>
param([int]$StartAt = 1)

$files = @(
 'session_reset_logs','question_types_and_grading','optional_exam_scheduling',
 'private_proctor_snapshots','academic_targeting','profile_identity_numbers',
 'strict_targeting_null_profiles',
 '20261103090000_guard_profile_labels','20261103090100_student_can_access_exam',
 '20261103090200_exams_select','20261103090300_questions_public',
 '20261103090400_submissions_insert_own_ongoing','20261103090500_snapshot_read_policy',
 '20261103090600_submissions_delete_supervisor','20261103090700_register_violation_snapshot_path',
 '20261103090800_snapshot_purge_not_live_attempt',
 '20261104090000_violation_weights','20261104090100_weighted_strikes_and_flagged_review',
 'optional_question_shuffling','20261105090000_proctor_heartbeats','retention_policy',
 '20261106090000_proctoring_consents','20261106090100_snapshot_retention'
)

# 1. Every file must exist before anything runs.
foreach ($f in $files) {
  if (-not (Test-Path "supabase\migrations\$f.sql")) { Write-Host "MISSING supabase\migrations\$f.sql" -ForegroundColor Red; exit 1 }
}

# 2. Show which project the CLI is linked to, and make the human type it.
$refFile = "supabase\.temp\project-ref"
if (-not (Test-Path $refFile)) { Write-Host "No linked project. Run: supabase link --project-ref <ref>" -ForegroundColor Red; exit 1 }
$ref = (Get-Content $refFile -Raw).Trim()
Write-Host "`nLinked project ref: $ref" -ForegroundColor Yellow
Write-Host "Check it in the Supabase dashboard URL (…/project/$ref). This must be the project you mean."
$typed = Read-Host "Type that project ref to continue"
if ($typed.Trim() -ne $ref) { Write-Host "Does not match. Stopped." -ForegroundColor Red; exit 1 }
$bk = Read-Host "Have you taken a backup of THIS project, and is no exam running? (yes/no)"
if ($bk -ne 'yes') { Write-Host "Stopped." -ForegroundColor Red; exit 1 }

# 3. Apply one at a time, stop on the first failure.
for ($i = $StartAt; $i -le $files.Count; $i++) {
  $f = $files[$i - 1]
  if ($f -eq '20261106090000_proctoring_consents') {
    $ok = Read-Host "NEXT is the consent migration. Older app builds will be refused until the build with the consent screen is live. Is it ready to ship right after? (yes/no)"
    if ($ok -ne 'yes') { Write-Host "Paused before [$i]. Resume later with -StartAt $i" -ForegroundColor Yellow; exit 0 }
  }
  Write-Host "[$i/$($files.Count)] $f.sql" -ForegroundColor Cyan
  supabase db query --linked -f "supabase\migrations\$f.sql"
  if ($LASTEXITCODE -ne 0) {
    Write-Host "FAILED at [$i] $f.sql. Fix the cause, then resume with: .\apply_live_cli.ps1 -StartAt $i" -ForegroundColor Red
    exit 1
  }
}
Write-Host "`nAll migrations applied. Next: set ALLOWED_ORIGIN, deploy the functions, smoke test, then merge." -ForegroundColor Green