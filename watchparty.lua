-- watchparty.lua
-- Drop this in ~/.config/mpv/scripts/watchparty.lua
-- Starts automatically when mpv opens any file
--
-- What it does:
--   HOST:  runs a tiny Python WS server (bridge.py) in background
--          broadcasts every play/pause/seek/speed to guests
--   GUEST: connects to host's bridge.py
--          receives commands and applies them to mpv
--   BOTH:  OSD overlay shows sync status, chat, guest count
--          key bindings for room control

local mp      = require "mp"
local msg     = require "mp.msg"
local utils   = require "mp.utils"
local options = require "mp.options"

-- mp.input is a separate module (added in mpv 0.37) — must be require'd explicitly
local ok_input, input_mod = pcall(require, "mp.input")
if not ok_input then input_mod = nil end

-- ─── User config (override in watchparty.conf) ───────────────────────────────
local o = {
    role        = "idle",        -- "idle" | "host" | "guest"
    host_ip     = "0.0.0.0",    -- host: bind address; guest: host IP
    port        = 8765,
    name        = "Viewer",      -- your display name in chat
    color       = "#5865f2",     -- your chat color (hex)
    chat_lines  = 8,             -- how many chat lines to show in OSD
    osd_timeout = 5,             -- seconds OSD stays visible after action
    sync_threshold = 2.0,        -- seconds of drift before force-seek
    github_repo = "SimplyRohit/watchparty",            -- e.g. "username/watchparty" for auto-updates
}
options.read_options(o, "watchparty")

-- INCOMING_PIPE removed in favor of direct mpv IPC

-- ─── OS detection ──────────────────────────────────────────────────────────
local IS_WIN = package.config:sub(1,1) == "\\"
local pid = utils.getpid()

-- ─── State ───────────────────────────────────────────────────────────────────
local state = {
    connected   = false,
    guest_count = 0,
    chat        = {},            -- list of {name, msg, color, time}
    ts_map      = {},            -- guest name → their timestamp
    osd_visible = false,
    osd_timer   = nil,
    chat_pinned = false,         -- true = overlay stays on permanently
    ipc_path    = IS_WIN and (os.getenv("TEMP") or "C:\\Temp") .. "\\mpv-wp-bridge-" .. pid .. ".tmp"
                           or  "/tmp/mpv-wp-bridge-" .. pid .. ".sock",
    bridge_pid  = nil,
    last_seek_by_us = false,     -- prevent echo loop
    last_pause_by_us = false,
    last_speed_by_us = false,
}

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function log(s) msg.info("[WatchParty] " .. s) end

local function ass_color(hex)
    if not hex or type(hex) ~= "string" then return "FFFFFF" end
    local cleaned = hex:gsub("#", "")
    if #cleaned == 6 then
        local r = cleaned:sub(1, 2)
        local g = cleaned:sub(3, 4)
        local b = cleaned:sub(5, 6)
        return b .. g .. r
    end
    return "FFFFFF"
end

local function format_time(seconds)
    if not seconds then return "00:00" end
    local m = math.floor(seconds / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d", m, s)
end

-- Get the machine's outbound LAN IP (the one friends should connect to)
local function get_local_ip()
    if IS_WIN then
        -- Windows: parse ipconfig output
        local f = io.popen("ipconfig 2>nul")
        if f then
            for line in f:lines() do
                local ip = line:match("IPv4 Address[^:]*:%s*([%d%.]+)")
                if ip and not ip:match("^127") then
                    f:close()
                    return ip
                end
            end
            f:close()
        end
        return "<your-ip>"
    end
    -- Linux/macOS: ip route get 1.1.1.1
    local f = io.popen("ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[\\d.]+'")
    if f then
        local ip = f:read("*l")
        f:close()
        if ip and ip ~= "" then return ip end
    end
    -- Fallback: hostname -I (first IP)
    local f2 = io.popen("hostname -I 2>/dev/null")
    if f2 then
        local line = f2:read("*l")
        f2:close()
        if line then return line:match("^(%S+)") or "<your-ip>" end
    end
    return "<your-ip>"
end

local function send_to_bridge(data)
    -- Append a JSON line to the bridge input file (works on Linux+Windows)
    local json_str = utils.format_json(data)
    if IS_WIN then
        -- Windows: use PowerShell to append safely
        local escaped = json_str:gsub('"', '\\"')
        os.execute(string.format('powershell -Command "Add-Content -Path \'%s\' -Value \'%s\'" 2>nul',
            state.ipc_path, escaped))
    else
        local cmd = string.format("printf '%%s\\n' '%s' >> %s 2>/dev/null &",
            json_str:gsub("'", "'\\''"), state.ipc_path)
        os.execute(cmd)
    end
end

local function osd(text, duration)
    duration = duration or o.osd_timeout
    mp.osd_message(text, duration)
end

local function show_overlay()
    -- Build the overlay string shown in OSD
    local lines = {}

    -- Status / pin indicator line
    local pin_icon = state.chat_pinned and "{\\c&Ha0a0a0&} 📌" or ""
    local role_icon = ""
    local status_color = "a0a0a0" -- soft gray/white
    
    if o.role == "host" then
        if state.connected then
            role_icon = "👑 HOST"
            status_color = "ff5555" -- red
        else
            role_icon = "⏳ Starting..."
            status_color = "6cb8ff" -- orange
        end
    elseif o.role == "guest" then
        if state.connected then
            role_icon = "🔗 GUEST"
            status_color = "fde98b" -- cyan
        else
            role_icon = "⏳ Connecting..."
            status_color = "6cb8ff" -- orange
        end
    end

    if o.role == "host" then
        table.insert(lines, string.format("{\\b1\\c&H%s&}%s{\\b0\\c&H888888&} • %d guest(s)%s",
            status_color, role_icon, state.guest_count, pin_icon))
    elseif o.role == "guest" then
        if state.connected then
            table.insert(lines, string.format("{\\b1\\c&H%s&}%s{\\b0\\c&H888888&} • connected%s",
                status_color, role_icon, pin_icon))
        else
            table.insert(lines, string.format("{\\b1\\c&H%s&}%s%s",
                status_color, role_icon, pin_icon))
        end
    else
        -- idle: still show chat if pinned
        if state.chat_pinned then
            table.insert(lines, "{\\b1\\c&H7bfa50&}💬 WatchParty{\\b0}" .. pin_icon)
        end
    end

    -- Lag info (host shows per-guest drift)
    if o.role == "host" and next(state.ts_map) then
        local pos = mp.get_property_number("time-pos") or 0
        local lag_parts = {}
        for name, ts in pairs(state.ts_map) do
            local drift = math.abs(pos - ts)
            table.insert(lag_parts, string.format("%s:%.1fs", name, drift))
        end
        table.insert(lines, "{\\fs12\\c&H888888&}Lag: " .. table.concat(lag_parts, "  "))
    end

    -- Chat lines
    if #state.chat > 0 then
        local start = math.max(1, #state.chat - o.chat_lines + 1)
        for i = start, #state.chat do
            local m = state.chat[i]
            if m.name == "System" then
                table.insert(lines, string.format("{\\c&H%s&}%s", ass_color(m.color), m.msg))
            else
                table.insert(lines, string.format("{\\b1\\c&H%s&}%s:{\\b0\\c&HFFFFFF&} %s", 
                    ass_color(m.color), m.name, m.msg))
            end
        end
    elseif state.chat_pinned then
        table.insert(lines, "{\\c&H666666&}(no messages yet)")
    end

    -- Controls hint (very small and subtle)
    table.insert(lines, "{\\fs12\\c&H555555&}F7 chat  •  F8 pin  •  F1 help")

    local text = table.concat(lines, "\\N")
    mp.set_osd_ass(1280, 720, "{\\an9\\pos(1260,20)\\fs18\\c&HFFFFFF&}" .. text)
end

local function hide_overlay()
    mp.set_osd_ass(0, 0, "")
    state.osd_visible = false
end

local function flash_overlay(duration)
    duration = duration or o.osd_timeout
    state.osd_visible = true
    show_overlay()
    -- If pinned, never auto-hide
    if state.chat_pinned then return end
    if state.osd_timer then state.osd_timer:kill() end
    state.osd_timer = mp.add_timeout(duration, function()
        if not state.osd_visible or state.chat_pinned then return end
        hide_overlay()
    end)
end

-- ─── Apply incoming sync commands ────────────────────────────────────────────

local function apply_cmd(cmd)
    local t = cmd.type

    if t == "CMD:play" then
        log("Received play command")
        state.last_pause_by_us = true
        mp.set_property("pause", "no")
        table.insert(state.chat, { name = "System", msg = "* " .. (cmd.name or "Someone") .. " played", color = "#a0a0a0", time = os.time() })
        flash_overlay(2)

    elseif t == "CMD:pause" then
        log("Received pause command")
        state.last_pause_by_us = true
        mp.set_property("pause", "yes")
        table.insert(state.chat, { name = "System", msg = "* " .. (cmd.name or "Someone") .. " paused", color = "#a0a0a0", time = os.time() })
        flash_overlay(2)

    elseif t == "CMD:seek" then
        log("Received seek command: " .. tostring(cmd.time))
        state.last_seek_by_us = true
        mp.set_property_number("time-pos", cmd.time)
        table.insert(state.chat, { name = "System", msg = "* " .. (cmd.name or "Someone") .. " seeked to " .. format_time(cmd.time), color = "#a0a0a0", time = os.time() })
        flash_overlay(2)

    elseif t == "CMD:speed" then
        log("Received speed command: " .. tostring(cmd.speed))
        state.last_speed_by_us = true
        mp.set_property_number("speed", cmd.speed)
        table.insert(state.chat, { name = "System", msg = "* " .. (cmd.name or "Someone") .. " set speed to " .. string.format("%.2fx", cmd.speed), color = "#a0a0a0", time = os.time() })
        osd(string.format("⚡ Speed → %.2fx", cmd.speed), 2)

    elseif t == "CMD:loop" then
        log("Received loop command: " .. tostring(cmd.loop))
        mp.set_property("loop-file", cmd.loop and "inf" or "no")
        table.insert(state.chat, { name = "System", msg = "* " .. (cmd.name or "Someone") .. (cmd.loop and " enabled loop" or " disabled loop"), color = "#a0a0a0", time = os.time() })
        osd(cmd.loop and "🔁 Loop ON" or "🔁 Loop OFF", 2)

    elseif t == "CMD:host" then
        log("Received host state on join")
        -- Guest received host's current state on join
        if cmd.video and cmd.video ~= "" then
            mp.commandv("loadfile", cmd.video, "replace")
            mp.add_timeout(1.5, function()
                state.last_seek_by_us = true
                mp.set_property_number("time-pos", cmd.ts or 0)
                mp.set_property("pause", cmd.paused and "yes" or "no")
            end)
        end
        flash_overlay(3)

    elseif t == "CMD:chat" then
        log("Received chat from " .. tostring(cmd.name) .. ": " .. tostring(cmd.msg))
        table.insert(state.chat, {
            name  = cmd.name,
            msg   = cmd.msg,
            color = cmd.color or "#ffffff",
            time  = os.time(),
        })
        flash_overlay(o.osd_timeout)

    elseif t == "REC:tsMap" then
        state.ts_map = cmd.tsMap or {}
        show_overlay()   -- refresh lag display

    elseif t == "REC:guestCount" then
        state.guest_count = cmd.count or 0
        show_overlay()

    elseif t == "REC:connected" then
        log("Connected to room!")
        state.connected = true
        table.insert(state.chat, { name = "System", msg = "* Connected to room", color = "#7bfa50", time = os.time() })
        osd("✅ Connected to room!", 3)
        flash_overlay(3)

    elseif t == "REC:started" then
        log("Host bridge started and listening on port " .. tostring(cmd.port))
        -- Host bridge is up and listening
        state.connected = true
        table.insert(state.chat, { name = "System", msg = "* Host bridge started on port " .. tostring(cmd.port), color = "#7bfa50", time = os.time() })
        show_overlay()

    elseif t == "REC:guest_joined" then
        log("Guest joined: " .. tostring(cmd.name) .. " (count: " .. tostring(cmd.count) .. ")")
        state.guest_count = cmd.count or (state.guest_count + 1)
        table.insert(state.chat, { name = "System", msg = "* " .. tostring(cmd.name or "Guest") .. " joined", color = "#7bfa50", time = os.time() })
        osd(string.format("👋 %s joined  (%d guest(s))", cmd.name or "Guest", state.guest_count), 3)
        flash_overlay(3)

    elseif t == "REC:guest_left" then
        log("Guest left: " .. tostring(cmd.name) .. " (count: " .. tostring(cmd.count) .. ")")
        state.guest_count = cmd.count or math.max(0, state.guest_count - 1)
        table.insert(state.chat, { name = "System", msg = "* " .. tostring(cmd.name or "Guest") .. " left", color = "#ff6c6c", time = os.time() })
        osd(string.format("👋 %s left  (%d guest(s))", cmd.name or "Guest", state.guest_count), 3)
        if state.osd_visible then show_overlay() end

    elseif t == "REC:disconnected" then
        log("Disconnected from room")
        state.connected = false
        table.insert(state.chat, { name = "System", msg = "* Disconnected from room", color = "#ff6c6c", time = os.time() })
        osd("❌ Disconnected from room", 3)
    end
end

-- ─── mpv → bridge (outgoing sync) ────────────────────────────────────────────

-- Watch pause property
mp.observe_property("pause", "bool", function(_, paused)
    if state.last_pause_by_us then
        state.last_pause_by_us = false
        return
    end
    if not state.connected then return end
    if paused == nil then return end

    table.insert(state.chat, { name = "System", msg = "* " .. o.name .. (paused and " paused" or " played"), color = "#a0a0a0", time = os.time() })
    send_to_bridge({ type = paused and "CMD:pause" or "CMD:play", name = o.name })
    flash_overlay(2)
end)

-- Watch seek (time-pos jumps)
mp.observe_property("seeking", "bool", function(_, seeking)
    if seeking then return end  -- wait for seek to complete
    if state.last_seek_by_us then
        state.last_seek_by_us = false
        return
    end
    if not state.connected then return end

    local pos = mp.get_property_number("time-pos")
    if pos then
        table.insert(state.chat, { name = "System", msg = "* " .. o.name .. " seeked to " .. format_time(pos), color = "#a0a0a0", time = os.time() })
        send_to_bridge({ type = "CMD:seek", time = pos, name = o.name })
        flash_overlay(2)
    end
end)

-- Watch speed
mp.observe_property("speed", "number", function(_, speed)
    if state.last_speed_by_us then
        state.last_speed_by_us = false
        return
    end
    if not state.connected or not speed then return end

    table.insert(state.chat, { name = "System", msg = "* " .. o.name .. " set speed to " .. string.format("%.2fx", speed), color = "#a0a0a0", time = os.time() })
    send_to_bridge({ type = "CMD:speed", speed = speed, name = o.name })
end)

-- Heartbeat — send our timestamp every second so host can show lag
local ts_timer = mp.add_periodic_timer(1.0, function()
    if not state.connected then return end
    local pos = mp.get_property_number("time-pos")
    if pos then
        send_to_bridge({ type = "CMD:ts", ts = pos, name = o.name })
    end
end)

-- ─── Key bindings ─────────────────────────────────────────────────────────────
-- All keys use Ctrl+Shift prefix to avoid clashing with normal mpv bindings.
-- We register both explicit ctrl+shift+key and implicit ctrl+KEY/ctrl+? (since Shift+key changes casing in mpv)
-- and use forced bindings to override any conflicts.

local function handle_overlay()
    log("wp-overlay triggered")
    if state.osd_visible and not state.chat_pinned then
        hide_overlay()
    else
        state.chat_pinned = false   -- brief flash, not pinned
        state.osd_visible = true
        show_overlay()
    end
end

local function handle_pin_chat()
    log("wp-pin-chat triggered")
    state.chat_pinned = not state.chat_pinned
    if state.chat_pinned then
        state.osd_visible = true
        if state.osd_timer then state.osd_timer:kill() end
        show_overlay()
        mp.osd_message("📌 Chat pinned  (Ctrl+Shift+P to unpin)", 2)
    else
        hide_overlay()
        mp.osd_message("Chat unpinned", 2)
    end
end

local function handle_chat()
    log("wp-chat triggered")

    if input_mod then
        input_mod.get({
            prompt  = "Chat: ",
            submit  = function(text)
                if text and text ~= "" then
                    local m = { name = o.name, msg = text, color = o.color }
                    table.insert(state.chat, m)
                    send_to_bridge({
                        type  = "CMD:chat",
                        name  = o.name,
                        msg   = text,
                        color = o.color,
                    })
                    flash_overlay(o.osd_timeout)
                end
            end,
        })
    else
        osd("Chat input requires mpv 0.37+", 3)
    end
end

local function handle_host()
    log("wp-host triggered")
    o.role = "host"
    start_bridge()
    local ip = get_local_ip()
    local addr = string.format("%s:%d", ip, o.port)
    osd(string.format("👑 Hosting!\nTell friends to join:\n  %s", addr), 6)
    log("Hosting at " .. addr)
end

local function handle_join()
    log("wp-join triggered")
    if input_mod then
        input_mod.get({
            prompt = "Host IP:port (e.g. 192.168.1.5:8765): ",
            submit = function(text)
                if text and text ~= "" then
                    local ip, port = text:match("^(.+):(%d+)$")
                    if ip then
                        o.host_ip = ip
                        o.port    = tonumber(port)
                    else
                        o.host_ip = text
                    end
                    o.role = "guest"
                    start_bridge()
                    osd(string.format("🔗 Connecting to %s:%d...", o.host_ip, o.port), 3)
                end
            end,
        })
    else
        -- mp.input not available — fall back to reading from config
        osd("Set host_ip and role=guest in watchparty.conf, then restart mpv", 5)
    end
end

local function handle_leave()
    log("wp-leave triggered")
    stop_bridge()
    state.connected = false
    o.role = "idle"
    osd("👋 Left room", 2)
    hide_overlay()
end

local function handle_help()
    log("wp-help triggered")
    local help = [[WatchParty Controls
─────────────────────
Ctrl+Shift+H  →  Host a room
Ctrl+Shift+J  →  Join a room
Ctrl+Shift+C  →  Send chat message
Ctrl+Shift+O  →  Briefly show overlay
Ctrl+Shift+P  →  Pin/unpin chat overlay
Ctrl+Shift+L  →  Leave room
Ctrl+Shift+/  →  This help]]
    osd(help, 6)
end

-- Bind standard ctrl+shift+<key>
mp.add_forced_key_binding("ctrl+shift+o", "wp-overlay",  handle_overlay)
mp.add_forced_key_binding("ctrl+shift+p", "wp-pin",      handle_pin_chat)
mp.add_forced_key_binding("ctrl+shift+c", "wp-chat",     handle_chat)
mp.add_forced_key_binding("ctrl+shift+h", "wp-host",     handle_host)
mp.add_forced_key_binding("ctrl+shift+j", "wp-join",     handle_join)
mp.add_forced_key_binding("ctrl+shift+l", "wp-leave",    handle_leave)
mp.add_forced_key_binding("ctrl+shift+/", "wp-help",     handle_help)

-- Bind alternate/implicit shift combinations
mp.add_forced_key_binding("ctrl+O", "wp-overlay-alt", handle_overlay)
mp.add_forced_key_binding("ctrl+P", "wp-pin-alt",     handle_pin_chat)
mp.add_forced_key_binding("ctrl+C", "wp-chat-alt",    handle_chat)
mp.add_forced_key_binding("ctrl+H", "wp-host-alt",    handle_host)
mp.add_forced_key_binding("ctrl+J", "wp-join-alt",    handle_join)
mp.add_forced_key_binding("ctrl+L", "wp-leave-alt",   handle_leave)
mp.add_forced_key_binding("ctrl+?", "wp-help-alt",    handle_help)

-- F-key aliases (bypass any DE shortcut interception)
mp.add_forced_key_binding("F5",  "wp-host-f5",    handle_host)
mp.add_forced_key_binding("F6",  "wp-join-f6",    handle_join)
mp.add_forced_key_binding("F7",  "wp-chat-f7",    handle_chat)
mp.add_forced_key_binding("F8",  "wp-pin-f8",     handle_pin_chat)
mp.add_forced_key_binding("F9",  "wp-leave-f9",   handle_leave)
mp.add_forced_key_binding("F1",  "wp-help-f1",    handle_help)

-- ─── Bridge process management ───────────────────────────────────────────────
-- bridge.py handles WebSocket networking
-- It reads commands from mpv (via state.ipc_path socket)
-- and writes incoming commands back to mpv (via mpv --input-ipc-server)

-- Windows uses named pipe for mpv IPC; Linux uses a Unix socket path
local mpv_ipc_path = IS_WIN and "\\\\.\\pipe\\mpv-wp-ipc-" .. pid or "/tmp/mpv-wp-mpv-" .. pid .. ".sock"

function start_bridge()
    stop_bridge()  -- kill previous if any

    -- bridge.py lives in watchparty-bin/ (outside scripts/ so mpv won't auto-load it)
    local bridge_path
    if IS_WIN then
        local appdata = os.getenv("APPDATA") or "C:\\Users\\User\\AppData\\Roaming"
        bridge_path = appdata .. "\\mpv\\watchparty-bin\\watchparty-bridge.py"
    else
        local home = os.getenv("HOME") or "/root"
        bridge_path = home .. "/.config/mpv/watchparty-bin/watchparty-bridge.py"
    end

    -- Ensure ipc_path exists (FIFO on Linux, temp file on Windows)
    if IS_WIN then
        -- Create empty file if missing
        os.execute(string.format('powershell -Command "if (-not (Test-Path \'%s\')) { New-Item \'%s\' -ItemType File | Out-Null }" 2>nul',
            state.ipc_path, state.ipc_path))
    else
        os.execute("mkfifo " .. state.ipc_path .. " 2>/dev/null || true")
    end

    -- Open the mpv IPC socket FIRST so bridge can connect back immediately
    mp.set_property("input-ipc-server", mpv_ipc_path)

    -- Set connected optimistically for host (bridge confirms via REC:started)
    -- Guests stay in "connecting" until REC:connected arrives
    if o.role == "host" then
        state.connected = true
        show_overlay()
    end

    local args = {
        IS_WIN and "python" or "python3", bridge_path,
        o.role,
    }
    if o.role == "host" then
        table.insert(args, tostring(o.port))
        table.insert(args, o.name)
    else
        table.insert(args, o.host_ip)
        table.insert(args, tostring(o.port))
        table.insert(args, o.name)
    end
    table.insert(args, "--in-fifo")
    table.insert(args, state.ipc_path)
    table.insert(args, "--mpv-ipc")
    table.insert(args, mpv_ipc_path)

    if o.github_repo and o.github_repo ~= "" then
        table.insert(args, "--github-update")
        table.insert(args, o.github_repo)
    end

    -- Delay bridge spawn by 600ms to give mpv's IPC socket time to open
    mp.add_timeout(0.6, function()
        local res = mp.command_native_async({
            name = "subprocess",
            args = args,
            playback_only = false,
            capture_stdout = false,
            capture_stderr = false,
            detach = false,
        }, function(success, result, err)
            if not success or (result and result.status ~= 0) then
                local status = result and result.status or "unknown"
                local errMsg = err or (result and result.error) or "none"
                log("Bridge exited with code: " .. tostring(status) .. ", error: " .. tostring(errMsg))
                state.connected = false
                if state.osd_visible then show_overlay() end
            end
        end)
        state.bridge_pid = res
        log("Bridge started: " .. table.concat(args, " "))
    end)
end

function stop_bridge()
    if state.bridge_pid then
        mp.abort_async_command(state.bridge_pid)
        state.bridge_pid = nil
    end
    state.connected = false
    state.guest_count = 0
    state.ts_map = {}
end

-- ─── Bridge → mpv incoming message handler ────────────────────────────────────
-- Bridge writes to the mpv IPC socket, triggering this handler.

mp.register_script_message("watchparty-incoming", function(payload)
    if payload and payload ~= "" then
        local ok, data = pcall(utils.parse_json, payload)
        if ok and data then
            apply_cmd(data)
        end
    end
end)

mp.register_script_message("watchparty-join", function(url)
    if url and url ~= "" then
        local ip, port = url:match("^(.+):(%d+)$")
        if ip then
            o.host_ip = ip
            o.port    = tonumber(port)
        else
            o.host_ip = url
            o.port    = 8765
        end
        o.role = "guest"
        start_bridge()
    end
end)

-- Create the IPC FIFO on script start
os.execute("mkfifo " .. state.ipc_path .. " 2>/dev/null || true")

-- ─── Startup ─────────────────────────────────────────────────────────────────

mp.register_event("file-loaded", function()
    -- Auto-start if role was set in config
    if o.role == "host" or o.role == "guest" then
        start_bridge()
    end

    -- Show quick help on first load
    mp.add_timeout(1.0, function()
        if o.role == "idle" then
            osd("WatchParty ready\nCtrl+Shift+H = Host  •  Ctrl+Shift+J = Join  •  Ctrl+Shift+/ = Help", 4)
        end
    end)
end)

mp.register_event("shutdown", function()
    stop_bridge()
    os.remove(state.ipc_path)
    if not IS_WIN then
        os.remove(mpv_ipc_path)
    end
end)

log("WatchParty script loaded!")
