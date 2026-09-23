<#
.SYNOPSIS
    Builds a release Android APK for the ProctorGuard student app with the
    Supabase backend baked in via --dart-define.

.DESCRIPTION
    Default command (one test APK per CPU architecture):

        flutter build apk --release --split-per-abi `
          --dart-define=SUPABASE_URL=<url> `
          --dart-define=SUPABASE_PUBLISHABLE_KEY=<key>

    Outputs land in build/app/outputs/flutter-apk/:
        app-arm64-v8a-release.apk    - most modern phones
        app-armeabi-v7a-release.apk  - older 32-bit devices
        app-x86_64-release.apk       - emulators / some tablets

    Flutter signs release builds with the debug keystore until a real signing
    config is added to android/app/build.gradle.kts, so these APKs install via
    `adb install -r` but are NOT Play-Store ready.

    Credentials resolve in order: parameter -> environment variable -> prompt
    (see supabase_defines.ps1). They are compiled into the APK, so only the
    PUBLIC anon/publishable key belongs here - never service_role/secret.

.PARAMETER Url
    Supabase project URL. Falls back to $env:SUPABASE_URL, then prompts.

.PARAMETER Key
    Supabase publishable (anon) key. Falls back to
    $env:SUPABASE_PUBLISHABLE_KEY, then $env:SUPABASE_ANON_KEY, then prompts.

.PARAMETER Single
    Build one universal APK instead of the per-ABI split.

.PARAMETER Clean
    Run `flutter clean` first (slower; handy when a stale build misbehaves).

.PARAMETER NonInteractive
    Never prompt; fail with a clear message instead (CI friendly).

.PARAMETER DryRun
    Print the resolved command without executing anything.

.EXAMPLE
    $env:SUPABASE_URL = 'https://abcdefgh.supabase.co'
    $env:SUPABASE_PUBLISHABLE_KEY = 'sb_publishable_...'
    .\build_apk.ps1

.EXAMPLE
    .\build_apk.ps1 -Url https://abcdefgh.supabase.co -Key sb_publishable_... -Single -Clean

.NOTES
    Needs the Android toolchain (`flutter doctor`): Android SDK with
    cmdline-tools plus the JDK bundled with Android Studio. If script
    execution is blocked:
      powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
#>
[CmdletBinding()]
param(
    [string]$Url,
    [string]$Key,
    [switch]$Single,
    [switch]$Clean,
    [switch]$NonInteractive,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'supabase_defines.ps1')

function Get-AndroidSdkDirectory {
    # Best-effort SDK lookup so we can warn before flutter spends time on
    # pub get. Returns $null when nothing is configured, otherwise the
    # configured path (which the caller checks exists).
    foreach ($name in 'ANDROID_HOME', 'ANDROID_SDK_ROOT') {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value.Trim() }
    }

    $localProperties = Join-Path $PSScriptRoot 'android\local.properties'
    if (Test-Path $localProperties) {
        $line = Select-String -Path $localProperties -Pattern '^\s*sdk\.dir\s*=\s*(.+)$' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $line) {
            $dir = $line.Matches[0].Groups[1].Value.Trim()
            # .properties files escape backslashes (C:\\Users\\...).
            $dir = $dir.Replace('\\', '\')
            if (-not [string]::IsNullOrWhiteSpace($dir)) { return $dir }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $fallback = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
        if (Test-Path $fallback) { return $fallback }
    }
    return $null
}

Push-Location $PSScriptRoot
try {
    if (-not (Test-Path (Join-Path $PSScriptRoot 'pubspec.yaml'))) {
        throw "pubspec.yaml not found next to this script - run it from the mobile/ checkout."
    }

    $flutter = Get-FlutterPath
    $config = Get-SupabaseDefines -Url $Url -Key $Key -NonInteractive:$NonInteractive

    $arguments = @('build', 'apk', '--release')
    if (-not $Single) { $arguments += '--split-per-abi' }
    $arguments += $config.Defines

    Write-Host ''
    Write-Host 'flutter build apk - release test build' -ForegroundColor Cyan
    Write-Host ('  SUPABASE_URL             = {0}' -f $config.Url)
    Write-Host ('  SUPABASE_PUBLISHABLE_KEY = {0}' -f (Format-MaskedKey -Key $config.Key))
    Write-Host ('  split per ABI            = {0}' -f (-not $Single))
    if ($Clean) { Write-Host '  flutter clean            = yes' }
    Write-Host ''
    Write-Host ('  {0} {1}' -f $flutter, ($arguments -join ' '))
    Write-Host ''

    $sdkDir = Get-AndroidSdkDirectory
    if ($null -eq $sdkDir) {
        Write-Warning 'No Android SDK configured (ANDROID_HOME / ANDROID_SDK_ROOT, android/local.properties sdk.dir, or %LOCALAPPDATA%\Android\Sdk). Install Android Studio or the command-line tools, then re-run - Gradle cannot build without it.'
    }
    elseif (-not (Test-Path -LiteralPath $sdkDir)) {
        Write-Warning ('android/local.properties points at "{0}", which does not exist. Install the Android SDK or fix sdk.dir, otherwise Gradle will fail.' -f $sdkDir)
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $sdkDir 'cmdline-tools'))) {
        Write-Warning ('The Android SDK at "{0}" has no cmdline-tools component, which `flutter doctor` reports as an incomplete Android toolchain. Install it from Android Studio > SDK Manager > SDK Tools, then re-run.' -f $sdkDir)
    }
    else {
        Write-Host ('  Android SDK              = {0}' -f $sdkDir)
    }

    if ($DryRun) {
        Write-Host 'DryRun: nothing was executed.' -ForegroundColor Yellow
        exit 0
    }

    Write-Host 'Resolving packages...' -ForegroundColor Cyan
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed with exit code $LASTEXITCODE." }

    if ($Clean) {
        Write-Host 'Cleaning previous build output...' -ForegroundColor Cyan
        & $flutter clean
        if ($LASTEXITCODE -ne 0) { throw "flutter clean failed with exit code $LASTEXITCODE." }
    }

    Write-Host 'Building APK...' -ForegroundColor Cyan
    & $flutter @arguments
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed with exit code $LASTEXITCODE." }

    $outDir = Join-Path $PSScriptRoot 'build\app\outputs\flutter-apk'
    $apks = @()
    if (Test-Path $outDir) {
        $apks = @(Get-ChildItem -Path $outDir -Filter '*.apk' -File | Sort-Object Name)
    }

    Write-Host ''
    if ($apks.Count -eq 0) {
        Write-Warning "Build reported success but no .apk was found under $outDir."
    }
    else {
        Write-Host 'Built APK(s):' -ForegroundColor Green
        foreach ($apk in $apks) {
            $sizeMb = [math]::Round($apk.Length / 1MB, 1)
            Write-Host ('  {0,-34} {1,7} MB' -f $apk.Name, $sizeMb)
        }
        Write-Host ''
        Write-Host 'Install on a connected device (adb ships with platform-tools):'
        Write-Host ('  adb install -r "{0}"' -f (Join-Path $outDir 'app-arm64-v8a-release.apk'))
        Write-Host 'Pick app-armeabi-v7a-release.apk for 32-bit phones and'
        Write-Host 'app-x86_64-release.apk for x86 emulators instead.'
    }
    Write-Host ''
}
finally {
    Pop-Location
}
