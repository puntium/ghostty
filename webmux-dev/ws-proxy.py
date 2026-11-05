#!/usr/bin/env python3
"""Unix-socket WebSocket proxy for smoke-host: logs how each connection ends,
and can inject frames to the client.

usage: ws-proxy.py LISTEN_SOCK UPSTREAM_FILE LOG [CTL_SOCK]

UPSTREAM_FILE holds the upstream socket path (read per connection). Per
connection and direction LOG gets one JSON line per close frame (opcode 8,
its code) and one for how that side ended: "eof", "reset" (ECONNRESET), or
an error. CTL_SOCK takes one line of raw JSON text per connection and
sends it as a server text frame to every open WebSocket (frames from the
server are forwarded whole, so an injected frame never splits one)."""
import json, os, socket, sys, threading, time

LISTEN, UPFILE, LOGF = sys.argv[1:4]
CTL = sys.argv[4] if len(sys.argv) > 4 else None
lock = threading.Lock()
logf = open(LOGF, "a", buffering=1)
nid = [0]
clients = {}  # conn id -> (client socket, send lock), WebSocket connections


def log(**kw):
    kw["ts"] = round(time.time(), 3)
    with lock:
        logf.write(json.dumps(kw) + "\n")


class Dir:
    """One direction's byte stream: returns what may be forwarded now."""

    def __init__(self, name):
        self.name, self.buf, self.ws, self.dead, self.head = name, b"", False, False, b""

    def feed(self, cid, data):
        if self.dead:
            return data
        if not self.ws:
            self.head += data
            if b"\r\n\r\n" not in self.head:
                return b""
            i = self.head.index(b"\r\n\r\n") + 4
            first = self.head.split(b"\r\n", 1)[0].decode("latin1")
            head, rest = self.head[:i], self.head[i:]
            self.head = b""
            if not ((self.name == "s2c" and " 101 " in first) or (self.name == "c2s" and b"websocket" in head.lower())):
                self.dead = True
                return head + rest
            self.ws = True
            return head + self.frames(cid, rest)
        return self.frames(cid, data)

    def frames(self, cid, data):
        self.buf += data
        out = b""
        while len(self.buf) >= 2:
            b0, b1 = self.buf[0], self.buf[1]
            ln, p = b1 & 0x7F, 2
            if ln == 126:
                if len(self.buf) < 4: break
                ln, p = int.from_bytes(self.buf[2:4], "big"), 4
            elif ln == 127:
                if len(self.buf) < 10: break
                ln, p = int.from_bytes(self.buf[2:10], "big"), 10
            mk = b""
            if b1 & 0x80:
                if len(self.buf) < p + 4: break
                mk, p = self.buf[p:p + 4], p + 4
            if len(self.buf) < p + ln: break
            if b0 & 0x0F == 8:
                pl = self.buf[p:p + ln]
                if mk: pl = bytes(c ^ mk[i & 3] for i, c in enumerate(pl))
                log(conn=cid, dir=self.name, close=int.from_bytes(pl[:2], "big") if len(pl) >= 2 else None)
            out += self.buf[:p + ln]
            self.buf = self.buf[p + ln:]
        return out


def pump(cid, src, dst, d, done, dst_lock):
    how = "eof"
    try:
        while True:
            try:
                data = src.recv(65536)
            except ConnectionResetError:
                how = "reset"; break
            except OSError as e:
                how = "error:" + str(e); break
            if not data:
                break
            fwd = d.feed(cid, data)
            if d.name == "s2c" and d.ws:
                clients[cid] = (dst, dst_lock)
            try:
                with dst_lock:
                    dst.sendall(fwd)
            except OSError as e:
                how = "send-error:" + str(e); break
    finally:
        if d.name == "s2c":
            clients.pop(cid, None)
        log(conn=cid, dir=d.name, ended=how)
        try: dst.shutdown(socket.SHUT_WR)
        except OSError: pass
        done.append(1)
        if len(done) == 2:
            src.close(); dst.close()


def serve(c):
    with lock:
        nid[0] += 1; cid = nid[0]
    up = open(UPFILE).read().strip()
    u = socket.socket(socket.AF_UNIX)
    try:
        u.connect(up)
    except OSError as e:
        log(conn=cid, upstream_error=str(e)); c.close(); return
    done = []
    threading.Thread(target=pump, args=(cid, c, u, Dir("c2s"), done, threading.Lock()), daemon=True).start()
    threading.Thread(target=pump, args=(cid, u, c, Dir("s2c"), done, threading.Lock()), daemon=True).start()


def control():
    if os.path.exists(CTL): os.unlink(CTL)
    s = socket.socket(socket.AF_UNIX); s.bind(CTL); s.listen(8)
    while True:
        c, _ = s.accept()
        text = c.makefile("rb").readline().rstrip(b"\n")
        n = 0
        for cid, (sock, slock) in list(clients.items()):
            ln = len(text)
            hdr = bytes([0x81]) + (bytes([ln]) if ln < 126 else bytes([126]) + ln.to_bytes(2, "big") if ln < 65536 else bytes([127]) + ln.to_bytes(8, "big"))
            try:
                with slock:
                    sock.sendall(hdr + text)
                n += 1
            except OSError:
                pass
        log(injected=text.decode("utf-8", "replace"), conns=n)
        c.sendall(f"{n}\n".encode()); c.close()


if CTL:
    threading.Thread(target=control, daemon=True).start()
if os.path.exists(LISTEN): os.unlink(LISTEN)
s = socket.socket(socket.AF_UNIX); s.bind(LISTEN); s.listen(64)
while True:
    c, _ = s.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
