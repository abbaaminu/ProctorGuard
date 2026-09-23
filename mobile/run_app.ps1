<#
.SYNOPSIS
    Runs the ProctorGuard student app (Flutter) with the Supabase backend
    injected through --dart-define.

.DESCRIPTION
    Produces exactly this command:

        flutter run --dart-define=SUPABASE_URL=<url> \
                    --dart-define=SUPABASE_PUBLISHABLE_KEY=<key>

    Credentials are resolved in order: parameter -> environment variable ->
    interactive prompt (see supabase_defines.ps1).

    The app only gets a Supabase client when these defines are present, so a
    bare `flutter run` boots with an empty URL/key and cannot talk to the
    backend - that is why this wrapper exists.

.PARAMETER Url
    Supabase project URL. Falls back to $env:SUPABASE_URL, then prompts.

.PARAMETER Key
    Supabase publishable (anon) key. Falls back to
    $env:SUPABASE_PUBLISHABLE_KEY, then the legacy $env:SUPABASE_ANON_KEY,
    then prompts.

.PARAMETER Device
    Device id to target (e.g. emulator-5554). See -ListDevices.

.PARAMETER Release
    Run in release mode instead of debug.

.PARAMETER Profile
    Run in profile mode.

.PARAMETER Mock
    Adds --dart-define=MOCK_CAMERA=true: the app opens no camera and the
    detection engine emits a simulated no_face / looking_away gaze deviation
    every 12s instead, so the overlay, the log rows and the escalation ladder
    can be exercised on an emulator, a desktop target or CI without a physical
    camera. Violations logged this way carry no snapshot (nothing to capture).
    -MockCamera is accepted as an alias.

.PARAMETER ListDevices
    Just print `flutter devices` and exit - useful before picking -Device.

.PARAMETER FlutterArgs
    Extra arguments appended verbatim, e.g. -FlutterArgs '--verbose'

.PARAMETER NonInteractive
    Never prompt; fail with a clear message instead (CI friendly).

.PARAMETER DryRun
    Print the resolved command without executing it.

.EXAMPLE
    .\run_app.ps1

.EXAMPLE
    $env:SUPABASE_URL = 'https://abcdefgh.supabase.co'
    $env:SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_...'
    .\run_app.ps1 -Device emulator-5554

.EXAMPLE
    .\run_app.ps1 -Url https://abcdefgh.supabase.co -Key sb_publishable_... -Release

.EXAMPLE
    .\run_app.ps1 -Mock -Device emulator-5554

.NOTES
    If script execution is blocked:
      powershell -ExecutionPolicy Bypass -File .\run_app.ps1
#>
[CmdletBinding()]
param(
    [string]$Url,
    [string]$Key,
    [string]$Device,
    [switch]$Release,
    [switch]$Profile,
    [Alias('MockCamera')]
    [switch]$Mock,
    [switch]$ListDevices,
    [string[]]$FlutterArgs = @(),
    [switch]$NonInteractive,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'supabase_defines.ps1')

if ($Release -and $Profile) {
    throw 'Pass either -Release or -Profile, not both.'
}

Push-Location $PSScriptRoot
try {
    if (-not (Test-Path (Join-Path $PSScriptRoot 'pubspec.yaml'))) {
        throw "pubspec.yaml not found next to this script - run it from the mobile/ checkout."
    }

    $flutter = Get-FlutterPath

    if ($ListDevices) {
        & $flutter devices
        exit $LASTEXITCODE
    }

    $config = Get-SupabaseDefines -Url $Url -Key $Key -NonInteractive:$NonInteractive

    $mode = 'debug'
    if ($Release) { $mode = 'release' }
    elseif ($Profile) { $mode = 'profile' }

    $arguments = @('run') + $config.Defines
    if ($Release) { $arguments += '--release' }
    if ($Profile) { $arguments += '--profile' }
    if ($Mock) { $arguments += '--dart-define=MOCK_CAMERA=true' }
    if (-not [string]::IsNullOrWhiteSpace($Device)) { $arguments += @('-d', $Device) }
    if ($FlutterArgs.Count -gt 0) { $arguments += $FlutterArgs }

    Write-Host ''
    Write-Host 'flutter run - Supabase backend injected via --dart-define' -ForegroundColor Cyan
    Write-Host ('  SUPABASE_URL             = {0}' -f $config.Url)
    Write-Host ('  SUPABASE_PUBLISHABLE_KEY = {0}' -f (Format-MaskedKey -Key $config.Key))
    Write-Host ('  mode                     = {0}' -f $mode)
    if (-not [string]::IsNullOrWhiteSpace($Device)) {
        Write-Host ('  device                   = {0}' -f $Device)
    }
    if ($Mock) {
        Write-Host '  mock camera              = true (simulated gaze deviations every 12s)' -ForegroundColor Yellow
        if ($Release) {
            Write-Warning 'Mock camera in release mode: the build runs without a real camera. Intended for demos only.'
        }
    }
    Write-Host ''
    Write-Host ('  {0} {1}' -f $flutter, ($arguments -join ' '))
    Write-Host ''
    Write-Host '  For local Supabase (supabase start) use its printed API URL, e.g.'
    Write-Host '  http://localhost:54321 - and remember the phone/emulator reaches the'
    Write-Host '  host differently (10.0.2.2 for the Android emulator).'
    Write-Host ''

    if ($DryRun) {
        Write-Host 'DryRun: command not executed.' -ForegroundColor Yellow
        exit 0
    }

    & $flutter @arguments
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
