# Assign recorded bytes to the key sent just before them and compare with
# xterm.js's expected bytes. Shift+PageUp/Down are expected to scroll and
# send nothing.
import json, sys
d = sys.argv[1]
expected = {(e["spec"], e["appCursor"]): e for e in json.load(open(f"{d}/xterm-expected.json"))}
results, total, bad, vt_skipped = [], 0, [], []
import os
for mode in os.environ.get("XTERM_KEYS_MODES", "normal app").split():
    sent = []
    for line in open(f"{d}/xterm-sent-{mode}.txt"):
        t, ns, spec = line.split(" ", 2)
        sent.append((int(ns), spec.strip()))
    # Every key the driver asked for must have been sent (a keyboard tool
    # that ignores the commands would otherwise compare nothing).
    want_n = sum(1 for l in open(f"{d}/xterm-cmds-{mode}.txt") if l.startswith("key "))
    if want_n == 0 or len(sent) != want_n:
        sys.exit(f"xterm-keys: {mode}: {len(sent)} keys sent of {want_n} asked for")
    got = {spec: b"" for _, spec in sent}
    for ns, hx in json.load(open(f"{d}/host/home/kread-{mode}.json")):
        owner = None
        for sns, spec in sent:
            if sns <= ns:
                owner = spec
            else:
                break
        if owner:
            got[owner] += bytes.fromhex(hx)
    for _, spec in sent:
        e = expected[(spec, mode == "app")]
        want = e["bytes"].encode("utf-8", "surrogatepass")
        total += 1
        ok = got[spec] == want
        results.append({"spec": spec, "mode": mode, "want": want.hex(), "got": got[spec].hex(), "ok": ok, **({"note": e["note"]} if "note" in e else {}), **({"scroll": e["scroll"]} if "scroll" in e else {})})
        parts = spec.split("+")
        # Ctrl+Alt+F1…F12 are XF86Switch_VT_n: the compositor switches VTs
        # and no client (Electron included) ever sees them.
        vt = "ctrl" in parts and "alt" in parts and parts[-1] in [f"F{i}" for i in range(1, 13)]
        if vt:
            results[-1]["note"] = "compositor VT switch; not deliverable"
            vt_skipped.append(spec)
            total -= 1
            continue
        if not ok:
            bad.append((mode, spec, want, got[spec]))
json.dump(results, open(f"{d}/xterm-keys.json", "w"), indent=1)
print(f"xterm-keys: {total} combinations compared, {len(bad)} differ "
      f"({len(vt_skipped)} Ctrl+Alt+F-key combinations sent but not deliverable: VT switch)")
for mode, spec, want, g in bad:
    print(f"  {mode:6} {spec:32} xterm {want!r:24} native {g!r}")
sys.exit(1 if bad else 0)
