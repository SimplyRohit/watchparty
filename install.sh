#!/usr/bin/env bash
# install.sh — installs watchparty into your mpv config
set -e

MPV_SCRIPTS="$HOME/.config/mpv/scripts"
MPV_OPTS="$HOME/.config/mpv/script-opts"

echo "Installing mpv-watchparty..."

# Create dirs
mkdir -p "$MPV_SCRIPTS" "$MPV_OPTS"

# Copy Lua script
cp watchparty.lua "$MPV_SCRIPTS/watchparty.lua"
echo "✅  Lua script → $MPV_SCRIPTS/watchparty.lua"

# Copy Python bridge into ~/.config/mpv/watchparty-bin/ (NOT inside scripts/)
# mpv auto-loads every file/subdir in scripts/ — keeping bridge.py outside prevents that error
MPV_BIN="$HOME/.config/mpv/watchparty-bin"
mkdir -p "$MPV_BIN"
cp watchparty-bridge.py "$MPV_BIN/watchparty-bridge.py"
chmod +x "$MPV_BIN/watchparty-bridge.py"
echo "✅  Python bridge → $MPV_BIN/watchparty-bridge.py"

# Copy config (only if doesn't exist)
if [ ! -f "$MPV_OPTS/watchparty.conf" ]; then
    cp watchparty.conf "$MPV_OPTS/watchparty.conf"
    echo "✅  Config → $MPV_OPTS/watchparty.conf"
else
    echo "⚠️   Config already exists, skipping: $MPV_OPTS/watchparty.conf"
fi

# Install Python dependency
echo ""
echo "Installing Python dependency (websockets)..."
pip install websockets --quiet && echo "✅  websockets installed"

echo ""
echo "════════════════════════════════════════"
echo "  WatchParty installed! "
echo "════════════════════════════════════════"
echo ""
echo "  Open any video with mpv:"
echo "    mpv movie.mkv"
echo "    mpv 'https://...' "
echo ""
echo "  Controls (inside mpv):"
echo "    Ctrl+Shift+H  →  Host a room"
echo "    Ctrl+Shift+J  →  Join a room"
echo "    Ctrl+Shift+C  →  Send chat"
echo "    Ctrl+Shift+O  →  Toggle overlay"
echo "    Ctrl+Shift+/  →  Help"
echo ""
echo "  Edit your name/settings:"
echo "    $MPV_OPTS/watchparty.conf"
echo ""
