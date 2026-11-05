# Raw-mode reader for smoke-pane: enters the alternate screen ("alt") or
# turns on SGR mouse reporting ("mouse"), prints RAW-READY, records every
# byte it gets until 4 s of silence, and writes repr(bytes) to OUT.
#   python3 raw-reader.py alt|mouse OUT
import os, sys, tty, termios, time, select
mode = sys.argv[1]; out = sys.argv[2]
fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
w = sys.stdout.write
w("\x1b[?1049h" if mode == "alt" else "\x1b[?1000h\x1b[?1006h"); w("RAW-READY"); sys.stdout.flush()
buf = b""; last = time.time()
try:
    while time.time() - last < 4:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            b = os.read(fd, 4096); buf += b; last = time.time()
            if b"q" in b: break
finally:
    w("\x1b[?1049l" if mode == "alt" else "\x1b[?1000l\x1b[?1006l"); sys.stdout.flush()
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
open(out, "w").write(repr(buf))
