#!/usr/bin/env python3
"""
watchparty-bridge.py  —  cross-platform (Linux + Windows)
Pure stdlib, no pip needed.

Lua → bridge:  named pipe (Linux) or temp-file polling (Windows)
Bridge → mpv:   Unix socket (Linux) or Windows named pipe

Usage (spawned automatically by watchparty.lua):
  python3 watchparty-bridge.py host <port> <name> --in-fifo /tmp/A --mpv-ipc /tmp/B.sock
  python3 watchparty-bridge.py guest <ip> <port> <name> --in-fifo /tmp/A --mpv-ipc /tmp/B.sock
"""

import sys, json, socket, threading, time, hashlib, base64, struct, os, argparse

IS_WIN = sys.platform == "win32"

# ── Parse args ────────────────────────────────────────────────────────────────

parser = argparse.ArgumentParser()
parser.add_argument("role",               choices=["host", "guest"])
parser.add_argument("host_or_port",       help="port (host) or IP (guest)")
parser.add_argument("port_or_name",       nargs="?", default="8765")
parser.add_argument("name",               nargs="?", default="Viewer")
parser.add_argument("--in-fifo",          default="/tmp/wp-lua-to-bridge")
parser.add_argument("--mpv-ipc",          default="/tmp/mpv-watchparty.sock")
parser.add_argument("--github-update",     default="")
args = parser.parse_args()

if args.role == "host":
    PORT      = int(args.host_or_port)
    PEER_NAME = args.port_or_name
    HOST_IP   = None
else:
    HOST_IP   = args.host_or_port
    PORT      = int(args.port_or_name)
    PEER_NAME = args.name

IN_FIFO  = args.in_fifo
MPV_IPC  = args.mpv_ipc

# ── Tiny WS implementation (no pip) ──────────────────────────────────────────

def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        c = s.recv(n - len(buf))
        if not c: raise ConnectionError("closed")
        buf += c
    return buf

def ws_server_handshake(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        data += conn.recv(2048)
    hdrs = {}
    for line in data.decode(errors="ignore").split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    key = hdrs.get("sec-websocket-key", "")
    magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    accept = base64.b64encode(hashlib.sha1((key+magic).encode()).digest()).decode()
    conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())

def ws_client_connect(host, port):
    s = socket.create_connection((host, port), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += s.recv(2048)
    return s

def ws_recv(s):
    try:
        h = _recv_exact(s, 2)
        b0, b1 = h[0], h[1]
        op = b0 & 0x0F
        if op == 8: return None
        if op == 9: ws_send(s, b"", opcode=10); return ws_recv(s)
        masked = (b1 & 0x80) != 0
        ln = b1 & 0x7F
        if ln == 126: ln = struct.unpack(">H", _recv_exact(s, 2))[0]
        elif ln == 127: ln = struct.unpack(">Q", _recv_exact(s, 8))[0]
        mask = _recv_exact(s, 4) if masked else b"\x00\x00\x00\x00"
        payload = bytearray(_recv_exact(s, ln))
        for i in range(ln): payload[i] ^= mask[i % 4]
        return payload.decode("utf-8", errors="ignore")
    except: return None

def ws_send(s, text, opcode=1):
    try:
        data = text.encode() if isinstance(text, str) else text
        ln = len(data)
        hdr = bytes([0x80 | opcode])
        if ln < 126:   hdr += bytes([ln])
        elif ln < 65536: hdr += bytes([126]) + struct.pack(">H", ln)
        else:            hdr += bytes([127]) + struct.pack(">Q", ln)
        s.sendall(hdr + data)
    except: pass

# ── mpv IPC helpers (cross-platform) ─────────────────────────────────────────

def _mpv_send_raw(data: bytes) -> bytes:
    """Send raw bytes to mpv IPC, return response bytes. Cross-platform."""
    if IS_WIN:
        # Windows named pipe — open as a binary file
        try:
            with open(MPV_IPC, 'r+b', buffering=0) as pipe:
                pipe.write(data)
                return pipe.read(512)
        except Exception:
            return b''
    else:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            s.connect(MPV_IPC)
            s.sendall(data)
            try: return s.recv(512)
            except: return b''

def to_lua(msg: dict):
    """Send a script-message to mpv via its IPC channel."""
    try:
        payload = json.dumps(msg)
        cmd = {"command": ["script-message", "watchparty-incoming", payload]}
        _mpv_send_raw(json.dumps(cmd).encode() + b"\n")
    except:
        pass

def mpv_get_pos() -> float:
    try:
        resp = _mpv_send_raw(json.dumps({"command": ["get_property", "time-pos"]}).encode() + b"\n")
        return json.loads(resp).get("data", 0) or 0
    except:
        return 0

# ── Lua → bridge reader (cross-platform) ─────────────────────────────────────

def lua_reader_loop(callback):
    """Read JSON commands from Lua.
       Linux: blocking reads on a named pipe (FIFO).
       Windows: poll a regular temp file, truncate after reading.
    """
    if IS_WIN:
        # Polling a temp file — Lua appends lines, we drain and truncate
        while True:
            try:
                with open(IN_FIFO, 'r+', encoding='utf-8') as f:
                    lines = f.readlines()
                    f.seek(0); f.truncate()
                for line in lines:
                    line = line.strip()
                    if line:
                        try: callback(json.loads(line))
                        except: pass
            except Exception:
                pass
            time.sleep(0.05)
    else:
        # Linux: FIFO — blocking open, iterate lines
        while True:
            try:
                with open(IN_FIFO, 'r') as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            try: callback(json.loads(line))
                            except: pass
            except Exception:
                time.sleep(0.05)

# ── HOST ──────────────────────────────────────────────────────────────────────

class HostBridge:
    def __init__(self):
        self.guests  = {}       # id → socket
        self.ts_map  = {}       # name → ts
        self.lock    = threading.Lock()
        self.cur_ts  = 0.0
        self.paused  = True

    def broadcast(self, msg: dict, exclude_id=None):
        text = json.dumps(msg)
        dead = []
        with self.lock:
            for gid, gs in list(self.guests.items()):
                if gid == exclude_id: continue
                try: ws_send(gs, text)
                except: dead.append(gid)
            for d in dead:
                self.guests.pop(d, None)

    def handle_guest(self, conn, gid):
        try: ws_server_handshake(conn)
        except: conn.close(); return

        with self.lock:
            self.guests[gid] = conn

        name = f"Guest{gid}"
        to_lua({"type": "REC:guest_joined", "name": name, "count": len(self.guests)})

        # Send current state immediately
        ws_send(conn, json.dumps({
            "type": "CMD:state", "paused": self.paused, "ts": self.cur_ts
        }))

        try:
            while True:
                raw = ws_recv(conn)
                if raw is None: break
                try: msg = json.loads(raw)
                except: continue
                t = msg.get("type", "")

                if t == "CMD:ts":
                    n = msg.get("name", name)
                    self.ts_map[n] = msg.get("ts", 0)
                    self.broadcast({"type": "REC:tsMap", "tsMap": self.ts_map})

                elif t == "CMD:chat":
                    msg.setdefault("name", name)
                    self.broadcast(msg, exclude_id=gid)
                    to_lua(msg)

                else:
                    to_lua(msg)
                    self.broadcast(msg, exclude_id=gid)
        except: pass
        finally:
            with self.lock: self.guests.pop(gid, None)
            self.ts_map.pop(name, None)
            try: conn.close()
            except: pass
            to_lua({"type": "REC:guest_left", "name": name, "count": len(self.guests)})

    def from_lua(self, msg: dict):
        t = msg.get("type", "")
        if t == "CMD:state_update":
            self.paused  = msg.get("paused", self.paused)
            self.cur_ts  = msg.get("ts", self.cur_ts)
        self.broadcast(msg)

    def run(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", PORT))
        srv.listen(10)
        to_lua({"type": "REC:started", "port": PORT})

        gid_counter = [0]
        threading.Thread(target=lua_reader_loop, args=(self.from_lua,), daemon=True).start()

        while True:
            try:
                conn, addr = srv.accept()
                gid_counter[0] += 1
                gid = gid_counter[0]
                threading.Thread(target=self.handle_guest, args=(conn, gid), daemon=True).start()
            except: break

# ── GUEST ─────────────────────────────────────────────────────────────────────

class GuestBridge:
    def __init__(self):
        self.conn = None

    def send(self, msg: dict):
        if self.conn:
            try: ws_send(self.conn, json.dumps(msg))
            except: pass

    def from_lua(self, msg: dict):
        self.send(msg)

    def run(self):
        for attempt in range(15):
            try:
                self.conn = ws_client_connect(HOST_IP, PORT)
                break
            except Exception as e:
                to_lua({"type": "REC:connecting", "attempt": attempt + 1})
                time.sleep(2)
        else:
            to_lua({"type": "REC:error", "msg": f"Cannot connect to {HOST_IP}:{PORT}"})
            return

        to_lua({"type": "REC:connected"})

        # Lua reader thread
        threading.Thread(target=lua_reader_loop, args=(self.from_lua,), daemon=True).start()

        # Heartbeat
        def hb():
            while self.conn:
                self.send({"type": "CMD:ts", "name": PEER_NAME, "ts": mpv_get_pos()})
                time.sleep(1)
        threading.Thread(target=hb, daemon=True).start()

        # Receive
        while True:
            raw = ws_recv(self.conn)
            if raw is None: break
            try:
                msg = json.loads(raw)
                to_lua(msg)
            except: pass

        to_lua({"type": "REC:disconnected"})

def check_for_updates(github_repo):
    if not github_repo: return
    try:
        import urllib.request
        current_py = os.path.abspath(__file__)
        if IS_WIN:
            current_lua = os.path.join(os.environ.get("APPDATA", ""), "mpv", "scripts", "watchparty.lua")
        else:
            current_lua = os.path.expanduser("~/.config/mpv/scripts/watchparty.lua")
            
        lua_url = f"https://raw.githubusercontent.com/{github_repo}/main/scripts2/watchparty.lua"
        py_url = f"https://raw.githubusercontent.com/{github_repo}/main/scripts2/watchparty-bridge.py"
        
        updated = False
        
        try:
            with urllib.request.urlopen(lua_url, timeout=5) as r:
                new_lua = r.read()
            if os.path.exists(current_lua):
                with open(current_lua, 'rb') as f:
                    old_lua = f.read()
            else:
                old_lua = b""
            if new_lua and new_lua != old_lua:
                os.makedirs(os.path.dirname(current_lua), exist_ok=True)
                with open(current_lua, 'wb') as f:
                    f.write(new_lua)
                updated = True
        except: pass
        
        try:
            with urllib.request.urlopen(py_url, timeout=5) as r:
                new_py = r.read()
            with open(current_py, 'rb') as f:
                old_py = f.read()
            if new_py and new_py != old_py:
                os.makedirs(os.path.dirname(current_py), exist_ok=True)
                with open(current_py, 'wb') as f:
                    f.write(new_py)
                updated = True
        except: pass
        
        if updated:
            time.sleep(2)
            to_lua({"type": "CMD:chat", "name": "System", "msg": "✨ WatchParty updated! Please restart mpv.", "color": "#7bfa50"})
    except: pass

# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Ensure IN_FIFO exists (FIFO on Linux, regular file on Windows)
    if IS_WIN:
        # Regular temp file used for polling
        open(IN_FIFO, 'a').close()
    else:
        try: os.mkfifo(IN_FIFO)
        except FileExistsError: pass

    if args.github_update:
        threading.Thread(target=check_for_updates, args=(args.github_update,), daemon=True).start()

    if args.role == "host":
        HostBridge().run()
    else:
        GuestBridge().run()
