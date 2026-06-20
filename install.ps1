# WatchParty mpv installer for Windows
# Run this in PowerShell: .\install.ps1

$ErrorActionPreference = "Stop"

Write-Host "=== WatchParty mpv Installer (Windows) ===" -ForegroundColor Cyan

# ── Paths ─────────────────────────────────────────────────────────────────────
$mpvScripts = "$env:APPDATA\mpv\scripts"
$mpvOpts    = "$env:APPDATA\mpv\script-opts"
$mpvBin     = "$env:APPDATA\mpv\watchparty-bin"

# ── Check mpv is installed ────────────────────────────────────────────────────
if (-not (Get-Command mpv -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "WARNING: mpv not found in your PATH." -ForegroundColor Yellow
    Write-Host "The files will still install to your mpv AppData directory." -ForegroundColor Gray
    Write-Host "But you must open mpv manually or add it to PATH to use it via terminal." -ForegroundColor Gray
}

# ── Check Python 3 is installed ───────────────────────────────────────────────
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: Python 3 not found." -ForegroundColor Red
    Write-Host "Download from: https://www.python.org/downloads/" -ForegroundColor Yellow
    Write-Host "Make sure to check 'Add Python to PATH' during install." -ForegroundColor Yellow
    exit 1
}

# ── Create directories ────────────────────────────────────────────────────────
New-Item -ItemType Directory -Force -Path $mpvScripts | Out-Null
New-Item -ItemType Directory -Force -Path $mpvOpts    | Out-Null
New-Item -ItemType Directory -Force -Path $mpvBin     | Out-Null

# ── Copy Lua script ───────────────────────────────────────────────────────────
Copy-Item -Force "watchparty.lua" "$mpvScripts\watchparty.lua"
Write-Host "OK  Lua script   -> $mpvScripts\watchparty.lua" -ForegroundColor Green

# ── Copy Python bridge (NOT inside scripts\ so mpv doesn't try to load it) ───
Copy-Item -Force "watchparty-bridge.py" "$mpvBin\watchparty-bridge.py"
Write-Host "OK  Python bridge -> $mpvBin\watchparty-bridge.py" -ForegroundColor Green

# ── Copy config (only if it doesn't exist yet) ────────────────────────────────
$confDest = "$mpvOpts\watchparty.conf"
if (-not (Test-Path $confDest)) {
    Copy-Item -Force "watchparty.conf" $confDest
    Write-Host "OK  Config       -> $confDest" -ForegroundColor Green
} else {
    Write-Host "OK  Config       -> kept existing $confDest" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "=== Installation complete! ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "How to use:" -ForegroundColor White
Write-Host "  1. Open any video: mpv movie.mkv" -ForegroundColor Gray
Write-Host "  2. HOST:  press F5 (or Ctrl+H) -> share the IP:port shown" -ForegroundColor Gray
Write-Host "  3. GUEST: press F6 (or Ctrl+J) -> type host's IP:port -> Enter" -ForegroundColor Gray
Write-Host "  4. CHAT:  press F7 (or Ctrl+C)" -ForegroundColor Gray
Write-Host "  5. PIN:   press F8 to keep chat visible" -ForegroundColor Gray
Write-Host "  6. HELP:  press F1" -ForegroundColor Gray
Write-Host ""
Write-Host "Note: Both players must have the SAME video file." -ForegroundColor Yellow
