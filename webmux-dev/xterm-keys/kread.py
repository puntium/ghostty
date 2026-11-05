# Raw-mode byte recorder run inside a test session: every read chunk with
# its CLOCK_MONOTONIC time, until 4 s pass without input. Writes JSON to
# argv[1]: [[t_ns, hex], ...].
import json, os, select, sys, termios, time, tty
out = sys.argv[1]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
chunks = []
try:
    sys.stdout.write("KREAD-READY\r\n"); sys.stdout.flush()
    while True:
        r, _, _ = select.select([fd], [], [], 4.0)
        if not r:
            break
        data = os.read(fd, 4096)
        chunks.append([time.monotonic_ns(), data.hex()])
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
with open(out, "w") as f:
    json.dump(chunks, f)
print("KREAD-DONE", len(chunks))
