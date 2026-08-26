# Enable Network Access.ps1 — one-time setup for the ITGMania Content Browser module.
#
# ITGmania deliberately prevents themes from granting themselves network
# access: HttpEnabled/HttpAllowHosts are immutable preferences, and
# Preferences.ini / Static.ini / Defaults.ini are all write-protected inside
# the game. That protection exists so an untrusted theme can't quietly reach
# the internet — so the machine's owner has to authorize it, from outside the
# game. That's what this script is: you run it yourself, with the game closed.
#
# It adds every host the browser reaches to the HttpAllowHosts line in your Preferences.ini
# (keeping every host already listed) and makes sure HttpEnabled=1. Nothing
# else is touched, and a timestamped backup is written next to the file.
#
# Run it by double-clicking "Enable Network Access.bat" in this folder.

param([switch]$NoPause)

$ErrorActionPreference = "Stop"

# Every host the browser reaches, written directly: the catalogue and its
# artwork, the popularity and doubles sources, the preview relay (localhost
# in development; put a deployed relay's host here or in webapp.txt), and
# the update manifest with its archive host.
#
# Nothing is ever REMOVED from the list -- an existing GrooveStats entry, or
# anything another module added, is left exactly where it is.
$Hosts = @("stepmaniaonline.net", "*.stepmaniaonline.net", "arrowcloud.dance", "*.arrowcloud.dance", "itgdb.net", "*.itgdb.net", "itgcontent.net", "*.itgcontent.net", "localhost", "127.0.0.1", "github.com", "*.githubusercontent.com")

function Report-Done {
    Write-Host "  Start ITGmania and open Find Content from the title menu." -ForegroundColor Green
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

# Read and write Preferences.ini in the SAME encoding and with the SAME line
# endings it arrived in.
#
# This used to end with "Set-Content -Encoding ascii", which replaces every
# character outside ASCII with a question mark -- so a profile or theme name
# with an accent in it came back mangled, in a file nobody asked this script to
# rewrite. Windows PowerShell reads a BOM-less file as the system codepage, so
# that is what a BOM-less file is written back as.
function Get-IniEncoding([string]$path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        return New-Object System.Text.UTF8Encoding($true)
    }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
    return [System.Text.Encoding]::Default
}

$encoding = Get-IniEncoding $prefs
$raw = [System.IO.File]::ReadAllText($prefs, $encoding)
$newline = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
$lines = @($raw -split "`r?`n")
# A file ending in a newline splits to a trailing empty element; dropping it
# stops the file growing a blank line on every run.
if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq "") {
    $lines = @($lines[0..($lines.Count - 2)])
}

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
    Write-Host "  Already set up - every host is allowed and HttpEnabled=1." -ForegroundColor Green
    Write-Host ""
    Report-Done $prefs
    if (-not $NoPause) { Read-Host "Press Enter to close" }
    exit 0
}

$backup = "$prefs.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
Copy-Item -LiteralPath $prefs -Destination $backup
[System.IO.File]::WriteAllText($prefs, (($out -join $newline) + $newline), $encoding)

# Never claim success without reading the file back. The shell script has always
# done this; this one used to print "Done." on the strength of the write not
# throwing, which is not the same thing.
$after = [System.IO.File]::ReadAllText($prefs, (Get-IniEncoding $prefs))
$hostsOK = $after -match '(?im)^\s*HttpAllowHosts\s*=.*127\.0\.0\.1'
$enabledOK = $after -match '(?im)^\s*HttpEnabled\s*=\s*1\s*$'
if (-not ($hostsOK -and $enabledOK)) {
    Copy-Item -LiteralPath $backup -Destination $prefs -Force
    Fail "The allowlist could not be written; Preferences.ini was restored from the backup."
}

Write-Host "  Done." -ForegroundColor Green
Write-Host "    the browser hosts were added to HttpAllowHosts"
Write-Host "    HttpEnabled=1"
Write-Host "    backup saved as $(Split-Path -Leaf $backup)"
Write-Host ""
Report-Done $prefs
if (-not $NoPause) { Read-Host "Press Enter to close" }
