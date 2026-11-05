# Emit realkeys-xkb commands for every expected combination of one mode,
# skipping chords in the shell's shortcut table.
import json, os, re, sys
table, expected, mode = sys.argv[1], sys.argv[2], sys.argv[3]
# XTERM_KEYS_ONLY="shift+Return,alt+Left": only these specs (the smoke).
only = set(filter(None, os.environ.get("XTERM_KEYS_ONLY", "").split(",")))
names = {"Page_Up": "Prior", "Page_Down": "Next"}
skip = set()
for accel in re.findall(r'\.accel = "([^"]+)"', open(table).read()):
    mods = set(m.lower() for m in re.findall(r"<(\w+)>", accel))
    key = re.sub(r"<\w+>", "", accel)
    key = names.get(key, key)
    mods = {"ctrl" if m == "control" else m for m in mods}
    skip.add((frozenset(mods), key.lower()))
for e in json.load(open(expected)):
    if e["appCursor"] != (mode == "app"):
        continue
    parts = e["spec"].split("+")
    key, mods = parts[-1], frozenset(parts[:-1])
    # The shell matches keypad Enter and keypad arrows as Enter and the
    # arrows (shortcuts.zig `.key` entries, as app.js does with
    # KeyboardEvent.key).
    same = {"kp_enter": "return", "kp_left": "left", "kp_right": "right", "kp_up": "up", "kp_down": "down"}
    if (mods, same.get(key.lower(), key.lower())) in skip:
        continue
    if only and e["spec"] not in only:
        continue
    print("key " + e["spec"])
    print("sleep 70")
