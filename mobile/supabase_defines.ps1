# =====================================================================
# Shared helpers for run_app.ps1 / build_apk.ps1
# ---------------------------------------------------------------------
# This file is DOT-SOURCED, not run directly - it only defines functions.
#
# Both scripts need the same two values, resolved the same way, because
# lib/main.dart reads them via String.fromEnvironment:
#     --dart-define=SUPABASE_URL=<project url>
#     --dart-define=SUPABASE_PUBLISHABLE_KEY=<anon/publishable key>
# (`SUPABASE_ANON_KEY` is still accepted as a fallback define name; here we
# also accept it as an environment variable so existing setups keep working.)
#
# Resolution order for each value:
#   1. explicit parameter (-Url / -Key)
#   2. environment variable  ($env:SUPABASE_URL / $env:SUPABASE_PUBLISHABLE_KEY)
#   3. interactive prompt    (skipped when -NonInteractive is passed)
# =====================================================================

Set-StrictMode -Version Latest

# Placeholder strings that appear in READMEs / copy-pasted commands. Treated
# as "not set" so a run can never quietly target a bogus backend (the app
# would otherwise boot against https://your-project.supabase.co and every
# network call would fail in a confusing way).
$script:SupabasePlaceholders = @(
  'your-url', 'your_url', 'yoururl',
  'your-key', 'your_key', 'yourkey',
  'your-anon-key', 'your-publishable-key',
  'https://your-project.supabase.co',
  'replace-me', 'replace_me', 'changeme', 'change-me'
)

function Test-PlaceholderValue {
  <#
    .SYNOPSIS
      True when a value is empty or is one of the documented placeholders.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }

  $candidate = $Value.Trim().TrimEnd('/')
  foreach ($placeholder in $script:SupabasePlaceholders) {
    if ($candidate -ieq $placeholder) { return $true }
  }
  if ($candidate -match 'your-project|your-anon-key|your-publishable-key|YOUR_URL|YOUR_KEY') {
    return $true
  }
  return $false
}

function Read-SupabaseValue {
  <#
    .SYNOPSIS
      Resolves one value from parameter -> environment -> prompt.
    .OUTPUTS
      The trimmed value, or $null when nothing is available and
      -NonInteractive was used (the caller turns that into a clear error).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [string]$Value,
    [string[]]$EnvNames,
    [string]$Prompt,
    [switch]$NonInteractive
  )

  if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value.Trim() }

  foreach ($name in $EnvNames) {
    $fromEnv = [Environment]::GetEnvironmentVariable($name)
    if (-not (Test-PlaceholderValue -Value $fromEnv)) { return $fromEnv.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
      Write-Warning "Ignoring placeholder value in `$env:$name."
    }
  }

  if ($NonInteractive) { return $null }
  return (Read-Host -Prompt $Prompt)
}

function Format-MaskedKey {
  <#
    .SYNOPSIS
      Masks a key for console output (the value is public/anon, but no
      reason to spray it across terminals and CI logs).
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param([string]$Key)

  if ([string]::IsNullOrEmpty($Key)) { return '<empty>' }
  if ($Key.Length -le 12) { return ('*' * $Key.Length) }
  return $Key.Substring(0, 6) + ('*' * 6) + $Key.Substring($Key.Length - 4)
}

function Get-FlutterPath {
  <#
    .SYNOPSIS
      Returns the flutter executable path or throws a readable error.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $command = Get-Command flutter -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw 'flutter was not found on PATH. Install the Flutter SDK, then reopen your terminal.'
  }
  return $command.Source
}

function Get-SupabaseDefines {
  <#
    .SYNOPSIS
      Resolves the Supabase URL + key and returns them together with the
      --dart-define arguments to hand to flutter.
    .OUTPUTS
      PSCustomObject with Url, Key and Defines (string[]).
  #>
  [CmdletBinding()]
  param(
    [string]$Url,
    [string]$Key,
    [switch]$NonInteractive
  )

  $urlValue = Read-SupabaseValue -Value $Url `
    -EnvNames @('SUPABASE_URL') `
    -Prompt 'Supabase project URL (https://<project-ref>.supabase.co)' `
    -NonInteractive:$NonInteractive

  if ($null -eq $urlValue -or (Test-PlaceholderValue -Value $urlValue)) {
    throw 'SUPABASE_URL is required. Pass -Url, set $env:SUPABASE_URL, or drop -NonInteractive to be prompted.'
  }
  if ($urlValue -notmatch '^https?://') {
    throw "SUPABASE_URL must start with http:// or https:// (got '$urlValue'). Example: https://abcdefgh.supabase.co"
  }
  $urlValue = $urlValue.TrimEnd('/')

  # Accept the older name too: the app falls back to it, and plenty of
  # existing shells/CI secrets still export SUPABASE_ANON_KEY.
  $keyValue = Read-SupabaseValue -Value $Key `
    -EnvNames @('SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_ANON_KEY') `
    -Prompt 'Supabase publishable (anon) key' `
    -NonInteractive:$NonInteractive

  if ($null -eq $keyValue -or (Test-PlaceholderValue -Value $keyValue)) {
    throw 'SUPABASE_PUBLISHABLE_KEY is required. Pass -Key, set $env:SUPABASE_PUBLISHABLE_KEY, or drop -NonInteractive to be prompted. This is the PUBLIC anon/publishable key - never the service_role key.'
  }
  if ($keyValue.Length -lt 20) {
    Write-Warning "The key looks unusually short ($($keyValue.Length) chars) - double-check you copied the whole value."
  }
  if ($keyValue -match '^sb_secret_') {
    throw 'That looks like a SECRET key (sb_secret_...). Use the publishable/anon key: a secret key in a client build grants full database access.'
  }

  $keyValue = $keyValue.Trim()

  return [PSCustomObject]@{
    Url     = $urlValue
    Key     = $keyValue
    Defines = @(
      "--dart-define=SUPABASE_URL=$urlValue",
      "--dart-define=SUPABASE_PUBLISHABLE_KEY=$keyValue"
    )
  }
}
