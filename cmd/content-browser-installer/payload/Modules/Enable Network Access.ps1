# Enable Network Access.ps1 — one-time setup for the ITGMania Content Browser module.
#
# ITGmania deliberately prevents themes from granting themselves network
# access: HttpEnabled/HttpAllowHosts are immutable preferences, and
# Preferences.ini / Static.ini / Defaults.ini are all write-protected inside
# the game. That protection exists so an untrusted theme can't quietly reach
# the internet — so the machine's owner has to authorize it, from outside the
# game. That's what this script is: you run it yourself, with the game closed.
#
# It adds stepmaniaonline.net to the HttpAllowHosts line in your
# Preferences.ini (keeping every host already listed) and makes sure
# HttpEnabled=1. Nothing else is touched, and a timestamped backup is written
# next to the file.
#
# Run it by double-clicking "Enable Network Access.bat" in this folder.

param([switch]$NoPause)

$ErrorActionPreference = "Stop"

$Hosts = @("stepmaniaonline.net", "*.stepmaniaonline.net")

function Fail($msg) {
    Write-Host ""
    Write-Host "  $msg" -ForegroundColor Red
    Write-Host ""
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit 1
}

Write-Host ""
Write-Host "  ITGMania Content Browser - enable network access" -ForegroundColor Cyan
Write-Host "  ----------------------------------------"
Write-Host ""

# The game rewrites Preferences.ini from memory when it exits, so an edit made
# while it is running would simply be discarded.
if (Get-Process -Name "ITGmania" -ErrorAction SilentlyContinue) {
    Fail "ITGmania is running. Close it completely, then run this again."
}

# This script lives in <install>\Themes\Simply Love\Modules\
$installRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path

# Portable installs keep Save\ beside the executable; otherwise it is in AppData.
$candidates = @(
    (Join-Path $installRoot "Save\Preferences.ini"),
    (Join-Path $env:APPDATA "ITGmania\Save\Preferences.ini")
)
$prefs = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $prefs) {
    Fail ("Could not find Preferences.ini. Looked in:`n    " + ($candidates -join "`n    "))
}

Write-Host "  Preferences file:"
Write-Host "    $prefs"
Write-Host ""

$lines = @(Get-Content -LiteralPath $prefs)

# Merge our hosts into the existing comma-separated list, preserving order and
# skipping anything already present (case-insensitive).
function Merge-Hosts([string]$current) {
    $list = @()
    $seen = @{}
    foreach ($h in ($current -split ",")) {
        $h = $h.Trim()
        if ($h -ne "" -and -not $seen.ContainsKey($h.ToLower())) {
            $seen[$h.ToLower()] = $true
            $list += $h
        }
    }
    foreach ($h in $Hosts) {
        if (-not $seen.ContainsKey($h.ToLower())) {
            $seen[$h.ToLower()] = $true
            $list += $h
        }
    }
    return ($list -join ",")
}

$changed = $false
$sawAllowHosts = $false
$sawEnabled = $false
$out = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
    if ($line -match '^\s*HttpAllowHosts\s*=(.*)$') {
        $sawAllowHosts = $true
        $merged = Merge-Hosts $Matches[1]
        if ($merged -ne $Matches[1].Trim()) { $changed = $true }
        $out.Add("HttpAllowHosts=$merged")
    }
    elseif ($line -match '^\s*HttpEnabled\s*=\s*(.*)$') {
        $sawEnabled = $true
        if ($Matches[1].Trim() -ne "1") { $changed = $true }
        $out.Add("HttpEnabled=1")
    }
    else {
        $out.Add($line)
    }
}

# Keys absent entirely: add them under [Options].
if (-not $sawAllowHosts -or -not $sawEnabled) {
    $rebuilt = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($line in $out) {
        $rebuilt.Add($line)
        if (-not $inserted -and $line -match '^\s*\[Options\]\s*$') {
            if (-not $sawAllowHosts) { $rebuilt.Add("HttpAllowHosts=" + (Merge-Hosts "")) }
            if (-not $sawEnabled)    { $rebuilt.Add("HttpEnabled=1") }
            $inserted = $true
            $changed = $true
        }
    }
    if (-not $inserted) {
        Fail "Preferences.ini has no [Options] section - it may be corrupt."
    }
    $out = $rebuilt
}

if (-not $changed) {
    Write-Host "  Already set up - stepmaniaonline.net is allowed." -ForegroundColor Green
    Write-Host "  Start ITGmania and open Find Content from the title menu."
    Write-Host ""
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit 0
}

$backup = "$prefs.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
Copy-Item -LiteralPath $prefs -Destination $backup
Set-Content -LiteralPath $prefs -Value $out -Encoding ascii

Write-Host "  Done." -ForegroundColor Green
Write-Host "    stepmaniaonline.net added to HttpAllowHosts"
Write-Host "    HttpEnabled=1"
Write-Host "    backup saved as $(Split-Path -Leaf $backup)"
Write-Host ""
Write-Host "  Start ITGmania and open Find Content from the title menu."
Write-Host ""
if (-not $NoPause) { Read-Host "Press Enter to close" }
