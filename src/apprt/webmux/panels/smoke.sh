#!/usr/bin/env bash
# End-to-end check of the panels (settings, connection log, status
# messages, URL handling) under the headless recipe in dev mode, where the
# panels' development hook gives the app a connection engine on the run's
# throwaway XDG directories.
#
#   1. settings: defaults loaded from the engine; the panel opens with the
#      colour scheme focused; each control changes its setting, applied at
#      once (app scheme, terminal colours, iface.settings) and written to
#      config.json; the fade previews without writing and saves on release;
#      the width fields clamp (max never below min);
#   2. status: a message shows on the window's toast and hides after 3 s;
#   3. log window: tail, host/level/text filters, Copy visible through a
#      real Ctrl+Shift+C read back with wl-paste, Copy all equal to the log
#      file, the 3000-entry ring, follow, Clear with its marker, Reveal
#      file recorded, Ctrl+F and Escape as real keys;
#   4. URLs (record mode, nothing is launched): open, copy (clipboard read
#      back), the chooser's Copy / Open / Cancel, mailto and other schemes,
#      Escape as a real key;
#   5. restart: a second app run on the same config and state directories
#      starts with the changed settings applied (light scheme before the
#      window shows) and the log file kept.
# Then nothing of either run is left running.
#
#   src/apprt/webmux/panels/smoke.sh     (build first: webmux-dev/build)
#
# WEBMUX_HOST_BIN defaults to the webmux checkout's host/dist binary.
set -euo pipefail
fork="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
dev="$fork/webmux-dev"
if [[ -z "${WEBMUX_HOST_BIN:-}" ]]; then
  for c in "$fork/../../host/dist/webmux-host-linux-x64" "$fork/../../../host/dist/webmux-host-linux-x64"; do
    [[ -x "$c" ]] && { WEBMUX_HOST_BIN="$(cd "$(dirname "$c")" && pwd)/$(basename "$c")"; break; }
  done
  export WEBMUX_HOST_BIN
fi

dir=""
dir2=""
fail() {
  echo "smoke-panels: FAIL: $*" >&2
  [[ -n "$dir" ]] && "$dev/headless" stop "$dir" >/dev/null 2>&1
  [[ -n "$dir2" ]] && "$dev/headless" stop "$dir2" >/dev/null 2>&1
  exit 1
}
ctl() { "$dev/wmctl" -s "$dir/ctl.sock" "$@"; }
get() { local cmd="$1" path="$2"; shift 2; ctl "$cmd" "$@" --get "$path"; }
expect() { # expect WHAT GOT WANT
  [[ "$2" == "$3" ]] || fail "$1: got [$2], want [$3]"
  echo "smoke-panels: ok  $1 = $3"
}
eventually() { # eventually WHAT WANT CMD...
  local what="$1" want="$2" got=""; shift 2
  for _ in $(seq 1 40); do
    got="$("$@" 2>/dev/null || true)"
    [[ "$got" == "$want" ]] && { echo "smoke-panels: ok  $what = $want"; return 0; }
    sleep 0.1
  done
  fail "$what: got [$got], want [$want]"
}
json() { python3 -I -c "import json,sys; v=json.load(sys.stdin)['result']; print($1)"; }

dir="$("$dev/headless" start --host | tail -n1)" || fail "headless start"
echo "smoke-panels: run dir $dir"
ctl -q wait contains='$' timeout_ms:=10000 || fail "terminal never showed a prompt"
config="$dir/home/.config/webmux-gtk/config.json"
logfile="$dir/home/.local/state/webmux-gtk/logs/webmux.log"

# --- 1. settings --------------------------------------------------------
expect "settings source" "$(get settings source)" engine
expect "default settings" "$(ctl settings | json 'v["applied"]')" "{'theme': 'dark', 'unfocused_fade': 40, 'min_cols': 90, 'max_cols': 200}"
expect "url sink defaults to record under the control socket" "$(get url-sink sink)" record

ctl -q settings-show
eventually "settings panel initial focus" theme get settings-dump focus
ctl -q screenshot path="$dir/settings-dark.png"

ctl -q settings-ui control=theme value=light
expect "theme applied" "$(get settings applied.theme)" light
expect "app scheme" "$(get settings app_scheme)" light
expect "terminal scheme (dump)" "$(ctl dump text:=false --get scheme)" light
expect "theme stored" "$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["settings"]["theme"])' "$config")" light
ctl -q screenshot path="$dir/settings-light.png"

writes="$(get settings persisted)"
ctl -q settings-ui control=fade value:=23
expect "fade preview snaps to the step" "$(get settings-dump fade_readout)" "25%"
expect "fade applied during the drag" "$(get settings applied.unfocused_fade)" 25
expect "fade not written during the drag" "$(get settings persisted)" "$writes"
ctl -q settings-ui control=release
expect "fade written on release" "$(get settings stored.unfocused_fade)" 25

ctl -q settings-ui control=min_cols value:=250
expect "raising min lifts max" "$(ctl settings | json 'v["applied"]["min_cols"], v["applied"]["max_cols"]')" "250 250"
expect "fields show the clamped values" "$(ctl settings-dump | json 'v["min_cols"], v["max_cols"]')" "250 250"
ctl -q settings-ui control=max_cols value:=50
expect "max below min is raised to min" "$(get settings applied.max_cols)" 250
ctl -q settings-ui control=min_cols value:=100
ctl -q settings-ui control=max_cols value:=120
expect "widths stored" "$(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1]))["settings"]; print(s["minCols"], s["maxCols"], s["unfocusedFade"])' "$config")" "100 120 25"
ctl -q settings-set fade:=30 persist:=false
expect "panel follows a change made elsewhere" "$(get settings-dump fade_readout)" "30%"
ctl -q settings-set fade:=25
ctl -q settings-ui control=done
eventually "panel closed by Done" false get settings-dump open

# --- 2. status message ----------------------------------------------------
ctl -q status text='clipboard image synced to sessions'
expect "toast visible" "$(get status-dump visible)" true
ctl -q screenshot path="$dir/toast.png"
ctl -q status text='link copied'
expect "a new message replaces the text" "$(get status-dump text)" "link copied"
sleep 2
expect "the timer restarted (still visible 2 s later)" "$(get status-dump visible)" true
sleep 1.4
expect "toast hidden 3 s after the last message" "$(get status-dump visible)" false

# --- 3. log window --------------------------------------------------------
ctl -q log-show
eventually "log window open" true get log-dump open
expect "log window title" "$(get log-dump title)" "webmux — connection log"
# Before our entries the log has "client started" and, in the merged app,
# the dev workspace's "[dev] page attached" (its connLog reaches the real
# engine's log now); wait for that one so the counts are fixed.
for _ in $(seq 1 50); do grep -q 'page attached' "$logfile" && break; sleep 0.1; done
grep -q 'page attached' "$logfile" || fail "no '[dev] page attached' entry from the workspace"
# The dev terminal's session socket logs its own lines (G-08: connecting,
# open, snapshot received); wait for the last, then count everything
# relative to what is there (shown = matching the filter; total = all).
for _ in $(seq 1 50); do grep -q 'snapshot received' "$logfile" && break; sleep 0.1; done
grep -q 'snapshot received' "$logfile" || fail "no 'snapshot received' entry from the dev terminal"
sleep 0.3
shown() { local n; n="$(get log-dump count)"; n="${n%% *}"; echo "$n"; }
counted() { if (( $1 == $2 )); then echo "$2 entries"; else echo "$1 of $2 entries"; fi; }
base_total="$(get log-dump total)"
base_info="$(shown)"
ctl -q log-filter level=warn+; base_warn="$(shown)"
# (the text filter applies after the entry's 80 ms search delay)
ctl -q log-filter level=info+ text=tunnel; sleep 0.5; base_tunnel="$(shown)"
ctl -q log-filter level=info+ text=; sleep 0.5
[[ "$(shown)" == "$base_info" ]] || fail "log filter did not go back to info+"
T=$((base_total + 4))
ctl -q log-push level=info conn=prod msg='connect requested'
ctl -q log-push level=debug conn=prod src=page msg='session socket connecting' 'data:={"session":"s1","attempt":1}'
ctl -q log-push level=warn conn=staging msg='tunnel exited' 'data:={"pid":4242,"code":255,"signal":null}'
ctl -q log-push level=error conn=staging msg='state retry → failed' 'data:={"msg":"ssh exited (255)"}'
eventually "live tail (info+ hides the debug line)" "$(counted $((base_info + 3)) $T)" get log-dump count
expect "hosts in order of first appearance" "$(ctl log-dump | json 'v["hosts"]')" "['all', 'client (no host)', 'dev', 'prod', 'staging']"
ctl -q log-filter level=debug+
expect "debug+" "$(get log-dump count)" "$T entries"
ctl -q log-filter host=staging
expect "host filter" "$(ctl log-dump | json '[r["msg"] for r in v["rows"]]')" "['tunnel exited', 'state retry → failed']"
ctl -q log-filter host=all level=warn+
expect "level filter" "$(get log-dump count)" "$(counted $((base_warn + 2)) $T)"
ctl -q log-filter level=info+ text=' TUNNEL '
eventually "text filter (case-insensitive, trimmed)" "$(counted $((base_tunnel + 1)) $T)" get log-dump count
ctl -q log-filter text=zzz
eventually "empty state" "Nothing matches the current filters." get log-dump empty
ctl -q log-filter text= level=warn+
eventually "filters back" "$(counted $((base_warn + 2)) $T)" get log-dump count
ctl -q panels-screenshot window=log path="$dir/log-light.png"

"$dev/realkeys-xkb" "$dir" ctrl+shift+c >/dev/null
eventually "Ctrl+Shift+C flash" "copied $((base_warn + 2)) visible lines" get log-dump flash
want="$(grep -E ' (WARN |ERROR) ' "$logfile")"
expect "clipboard = the visible lines" "$("$dev/in-session" "$dir" wl-paste)" "$want"
ctl -q log-press button=copy_all
sleep 0.3
"$dev/in-session" "$dir" wl-paste -n > "$dir/copy-all.txt"
cmp -s "$dir/copy-all.txt" "$logfile" || fail "Copy all differs from the log file"
echo "smoke-panels: ok  Copy all = the log file, byte for byte"
expect "Copy all flash" "$(get log-dump flash)" "copied $T lines"

ctl -q log-filter level=info+
ctl -q log-push level=info conn=bulk msg='bulk entry' count:=3100
eventually "ring of 3000 in the window" 3000 get log-dump total
expect "following: newest in view" "$(ctl log-dump limit:=1 | json 'v["filters"]["follow"] and v["scroll"]["value"] + v["scroll"]["page"] >= v["scroll"]["upper"] - 4')" True
ctl -q log-scroll to:=200
expect "scrolling up unticks follow" "$(get log-dump filters.follow)" false
ctl -q log-scroll to=bottom
expect "back at the bottom reticks it" "$(get log-dump filters.follow)" true

ctl -q log-press button=clear
eventually "Clear leaves the marker" "['log cleared (file untouched)']" sh -c "\"$dev/wmctl\" -s \"$dir/ctl.sock\" log-dump | python3 -I -c \"import json,sys; print([r['msg'] for r in json.load(sys.stdin)['result']['rows']])\""
grep -q 'bulk entry' "$logfile" || fail "the file lost entries on Clear"
ctl -q url-sink clear:=true
ctl -q log-press button=reveal
expect "Reveal file (recorded, not launched)" "$(ctl url-sink | json 'v["recorded"]')" "[{'kind': 'reveal', 'target': '$logfile'}]"

"$dev/realkeys-xkb" "$dir" ctrl+f >/dev/null
eventually "Ctrl+F focuses the text filter" search get log-dump focus
"$dev/realkeys" "$dir" -k Escape
eventually "Escape closes the window" false get log-dump open
ctl -q log-show
eventually "it opens again" true get log-dump open
ctl -q log-close

# --- 4. URLs --------------------------------------------------------------
ctl -q url-sink clear:=true
ctl -q url target=https://example.com/a action=open
ctl -q url target=mailto:a@example.com action=open
ctl -q url target=file:///etc/passwd action=open
expect "open: only http(s) is launched" "$(ctl url-sink | json '[r["target"] for r in v["recorded"]]')" "['https://example.com/a']"
"$dev/realkeys" "$dir" 'x'
ctl -q url target=https://example.com/copied action=copy
expect "copy: clipboard" "$("$dev/in-session" "$dir" wl-paste)" "https://example.com/copied"
expect "copy: status" "$(get status-dump text)" "link copied"
ctl -q url target=https://example.com/chosen action=choose
eventually "chooser open, Open in browser focused" open get url-chooser focus
expect "chooser label" "$(get url-chooser open_label)" "Open in browser"
ctl -q screenshot path="$dir/chooser.png"
ctl -q url-chooser press=copy
expect "chooser Copy closes and copies" "$(get url-chooser open):$("$dev/in-session" "$dir" wl-paste)" "false:https://example.com/chosen"
ctl -q url target=https://example.com/opened action=choose
sleep 0.3
ctl -q url-chooser press=open
ctl -q url target=https://example.com/cancelled action=choose
sleep 0.3
ctl -q url-chooser press=cancel
ctl -q url target=mailto:someone@example.com action=choose
sleep 0.3
expect "mailto chooser" "$(get url-chooser open_label)" "Open"
ctl -q url-chooser press=open
ctl -q url target=ssh://host action=choose
sleep 0.3
expect "other schemes: Copy only" "$(ctl url-chooser | json 'v["open_label"]')" None
"$dev/realkeys" "$dir" -k Escape
eventually "Escape cancels the chooser" false get url-chooser open
expect "recorded launches" "$(ctl url-sink | json '[r["target"] for r in v["recorded"]]')" "['https://example.com/a', 'https://example.com/opened', 'mailto:someone@example.com']"
eventually "focus back on the pane" true ctl dump text:=false --get panes.0.focused

# --- 6. audit regressions (real pointer and keys, real pictures) ---------
# Each check would have caught a defect the fix-round audit found.
cat > "$dir/png.py" <<'PY'
import sys, zlib, struct
def load(path):
    d = open(path, 'rb').read(); i = 8; idat = b''; w = h = 0; ct = 6
    while i < len(d):
        n = struct.unpack('>I', d[i:i+4])[0]; t = d[i+4:i+8]; c = d[i+8:i+8+n]; i += 12 + n
        if t == b'IHDR': w, h, _, ct = struct.unpack('>IIBB', c[:10])
        elif t == b'IDAT': idat += c
    raw = zlib.decompress(idat); bpp = 4 if ct == 6 else 3; st = w * bpp; rows = []; prev = bytearray(st); p = 0
    for _ in range(h):
        f = raw[p]; p += 1; cur = bytearray(raw[p:p+st]); p += st
        if f:
            for x in range(st):
                a = cur[x-bpp] if x >= bpp else 0; b = prev[x]; cc = prev[x-bpp] if x >= bpp else 0
                if f == 1: cur[x] = (cur[x] + a) & 255
                elif f == 2: cur[x] = (cur[x] + b) & 255
                elif f == 3: cur[x] = (cur[x] + (a + b) // 2) & 255
                elif f == 4:
                    pa = abs(b-cc); pb = abs(a-cc); pc = abs(a+b-2*cc)
                    cur[x] = (cur[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else cc)) & 255
        rows.append(bytes(cur)); prev = cur
    return w, h, lambda x, y: tuple(rows[y][x*bpp:x*bpp+3])
mode = sys.argv[1]
if mode == 'region':  # distinct colours and mean brightness of a region
    w, h, px = load(sys.argv[2]); x0, y0, x1, y1 = map(int, sys.argv[3:7])
    cols = set(); tot = 0; n = 0
    for y in range(y0, y1, 2):
        for x in range(x0, x1, 2):
            c = px(x, y); cols.add(c); tot += sum(c); n += 1
    print(len(cols), tot // (3 * n))
elif mode == 'toast':  # the accent box near the bottom-right: width, right gap, bottom gap
    w, h, px = load(sys.argv[2]); acc = tuple(int(sys.argv[3][i:i+2], 16) for i in (0, 2, 4))
    xs = []; ys = []
    for y in range(h - 300, h - 12):
        for x in range(w // 3, w - 12):
            c = px(x, y)
            if all(abs(c[k] - acc[k]) < 8 for k in range(3)): xs.append(x); ys.append(y)
    print(max(xs) - min(xs) + 1, w - 1 - max(xs), h - 1 - max(ys))
PY
pngq() { python3 -I "$dir/png.py" "$@"; }
winrect() { # winrect main|log -> "X Y W H" of that window on the output
  "$dev/in-session" "$dir" swaymsg -t get_tree | python3 -I -c '
import json, sys
want = sys.argv[1]
def walk(n):
    if n.get("app_id") == "me.puntium.webmux.gtk":
        log = (n.get("name") or "").startswith("webmux — connection log")
        if log == (want == "log"):
            r = n["rect"]; print(r["x"], r["y"], r["width"], r["height"]); sys.exit(0)
    for c in n.get("nodes", []) + n.get("floating_nodes", []): walk(c)
walk(json.load(sys.stdin))' "$1"
}
grab() { # grab FILE [X Y W H]
  if [[ $# -gt 1 ]]; then "$dev/in-session" "$dir" grim -g "$2,$3 ${4}x$5" "$1"; else "$dev/in-session" "$dir" grim "$1"; fi
}

ctl -q settings-set theme=dark
ctl -q text text='ls -la /\n'
sleep 0.5
read -r mx my mw mh <<<"$(winrect main)"
grab "$dir/r-plain.png"
read -r cols_plain mean_plain <<<"$(pngq region "$dir/r-plain.png" $((mx+15)) $((my+40)) $((mx+400)) $((my+360)))"

# M-03: the modal dims the window; the panes stay visible behind it.
for scheme in dark light; do
  ctl -q settings-set theme=$scheme
  sleep 0.3
  grab "$dir/r-$scheme-plain.png"
  read -r _ mean_off <<<"$(pngq region "$dir/r-$scheme-plain.png" $((mx+15)) $((my+40)) $((mx+400)) $((my+360)))"
  ctl -q settings-show
  eventually "settings open ($scheme)" theme get settings-dump focus
  sleep 0.4
  grab "$dir/r-$scheme-modal.png"
  read -r cols mean_on <<<"$(pngq region "$dir/r-$scheme-modal.png" $((mx+15)) $((my+40)) $((mx+400)) $((my+360)))"
  (( cols > 6 )) || fail "M-03 ($scheme): the window behind the panel is one flat colour ($cols colours)"
  (( mean_on < mean_off )) || fail "M-03 ($scheme): the window behind the panel is not dimmed ($mean_on vs $mean_off)"
  echo "smoke-panels: ok  M-03 $scheme: panes visible through the dim ($cols colours, brightness $mean_off -> $mean_on)"
  ctl -q settings-close
  eventually "settings closed ($scheme)" false get settings-dump open
done
ctl -q settings-set theme=dark

# D3: no GTK layout warnings when the panel opens; usable in a short window.
grep -qE 'Widget reports min|exceeds AdwDialog' "$dir/app.log" && fail "D3: GTK layout warnings from the settings panel"
echo "smoke-panels: ok  D3 no layout warnings"
ctl -q resize width:=440 height:=380
sleep 0.6
read -r mx my mw mh <<<"$(winrect main)"
ctl -q settings-show
eventually "settings open in a 440x380 window" theme get settings-dump focus
grep -qE 'Widget reports min|exceeds AdwDialog' "$dir/app.log" && fail "D3: GTK layout warnings in the short window"
ctl -q settings-close
eventually "closed" false get settings-dump open
ctl -q resize width:=1400 height:=900
sleep 0.6
read -r mx my mw mh <<<"$(winrect main)"

# Backdrop click (real pointer) closes the panel; a click inside does not.
ctl -q settings-show
eventually "settings open" theme get settings-dump focus
"$dev/realpointer" "$dir" abs $((mx+mw/2)) $((my+mh/2)), sleep 60, down, sleep 50, up, sleep 300
expect "a click inside the panel keeps it" "$(get settings-dump open)" true
"$dev/realpointer" "$dir" abs $((mx+40)) $((my+mh-40)), sleep 60, down, sleep 50, up, sleep 500
eventually "backdrop click closes the panel" false get settings-dump open

# Tab order (real keys, both directions; Shift+Tab is ISO_Left_Tab on a
# real keyboard) and E-13 typed values.
ctl -q settings-show
eventually "settings open" theme get settings-dump focus
fwd=""; for _ in 1 2 3 4 5 6; do "$dev/realkeys" "$dir" -k Tab; sleep 0.12; fwd+="$(get settings-dump focus) "; done
expect "Tab order" "$fwd" "fade min_cols max_cols open_log theme fade "
back=""; for _ in 1 2 3 4 5 6; do "$dev/realkeys-xkb" "$dir" shift+Tab >/dev/null; sleep 0.12; back+="$(get settings-dump focus) "; done
expect "Shift+Tab order" "$back" "theme open_log max_cols min_cols fade theme "
ctl -q settings-set min_cols:=100 max_cols:=150
for _ in 1 2 3; do "$dev/realkeys" "$dir" -k Tab; sleep 0.1; done
expect "focus on the max field" "$(get settings-dump focus)" max_cols
"$dev/realkeys-xkb" "$dir" ctrl+a >/dev/null; "$dev/realkeys" "$dir" '12.7' -k Tab
sleep 0.3
expect "E-13: typed 12.7 is a number (clamped, raised to min)" "$(ctl settings | json 'v["applied"]["max_cols"]')" 100
"$dev/realkeys-xkb" "$dir" shift+Tab >/dev/null
"$dev/realkeys-xkb" "$dir" ctrl+a >/dev/null; "$dev/realkeys" "$dir" '150.4' -k Return
sleep 0.3
expect "E-13: 150.4 + Return commits 150" "$(ctl settings | json 'v["applied"]["max_cols"]')" 150
"$dev/realkeys-xkb" "$dir" shift+Tab >/dev/null
"$dev/realkeys-xkb" "$dir" ctrl+a >/dev/null; "$dev/realkeys" "$dir" '123' -k Escape
eventually "Escape closes the panel" false get settings-dump open
expect "E-13: Escape drops an uncommitted edit" "$(ctl settings | json 'v["applied"]["min_cols"]')" 100

# M-01: the toast is at most 640px wide, 18px from the edges.
ctl -q status text="$(python3 -c 'print("a long status message that keeps going " * 12)')"
sleep 0.5
grab "$dir/r-toast.png" $mx $my $mw $mh
read -r tw tr tb <<<"$(pngq toast "$dir/r-toast.png" 7aa2f7)"
(( tw <= 640 && tw >= 560 )) || fail "M-01: toast width $tw"
expect "M-01 toast gaps" "$tr $tb" "18 18"
echo "smoke-panels: ok  M-01 toast width $tw"
sleep 3.2

# D8: a background host's message waits for its host to come to the front.
ctl -q status-front name=alpha
ctl -q status from=beta text='uploaded 2 file(s) → ~'
expect "D8: message from a host behind is not shown" "$(get status-dump visible)" false
ctl -q status from=alpha text='deleted notes.txt'
expect "D8: message from the host in front is shown" "$(get status-dump text)" "deleted notes.txt"
ctl -q status-front name=beta
expect "D8: switching to beta shows its message" "$(get status-dump text)" "uploaded 2 file(s) → ~"
ctl -q status text='cannot open the config file'
expect "D8: app-wide message shows anyway" "$(get status-dump visible)" true
sleep 3.2
ctl -q status-front name=alpha
expect "D8: an expired message does not come back" "$(get status-dump visible)" false

# G-22: the log toolbar wraps; every control stays whole and inside.
ctl -q log-push conn=production-cluster-eu-west-1-bastion msg=hi
ctl -q log-show
eventually "log open" true get log-dump open
toolbar_ok() { # every item inside the window, none overlapping, search 200px
  ctl log-dump limit:=0 | python3 -I -c '
import json, sys
r = json.load(sys.stdin)["result"]; W = r["size"]["width"]; b = r["toolbar"]
bad = [i for i in b if i["x"] < 0 or i["x"] + i["w"] > W]
over = [(a["name"], c["name"]) for i, a in enumerate(b) for c in b[i+1:] if a["w"] and c["w"] and a["x"] < c["x"] + c["w"] and c["x"] < a["x"] + a["w"] and a["y"] < c["y"] + c["h"] and c["y"] < a["y"] + a["h"]]
s = [i for i in b if i["name"] == "entry"][0]
print("ok" if not bad and not over and s["w"] == 200 else "bad %s %s search %d" % (bad, over, s["w"]))
lines = len(set(i["y"] for i in b if i["name"] == "button"))
print(lines)'
}
expect "G-22: one line at 900px with host all" "$(toolbar_ok | tr '\n' ' ')" "ok 1 "
ctl -q log-filter host=production-cluster-eu-west-1-bastion level=debug+
sleep 0.3
expect "G-22: long host at 900px" "$(toolbar_ok | head -1)" ok
for w in 600 380; do
  "$dev/in-session" "$dir" swaymsg "[title=\"^webmux — connection log\"] resize set $w 420" >/dev/null
  sleep 0.5
  expect "G-22: window stays ${w}px" "$(ctl log-dump limit:=0 | json 'v["size"]["width"]')" "$w"
  expect "G-22: long host at ${w}px" "$(toolbar_ok | head -1)" ok
done
"$dev/in-session" "$dir" swaymsg "[title=\"^webmux — connection log\"] resize set 900 560" >/dev/null
ctl -q log-filter host=all level=info+
# G-24 with a real wheel and touchpad (second number = vertical).
ctl -q log-push conn=bulk msg='bulk line' count:=300
sleep 0.6
read -r lx ly lw lh <<<"$(winrect log)"
"$dev/realpointer" "$dir" abs $((lx+lw/2)) $((ly+lh/2)), sleep 80, scroll 0 -5, sleep 400
expect "G-24: wheel up unticks follow" "$(get log-dump filters.follow limit:=0)" false
ctl -q log-push conn=bulk msg='while scrolled up'
sleep 0.3
expect "G-24: no jump while unticked" "$(get log-dump filters.follow limit:=0)" false
"$dev/realpointer" "$dir" abs $((lx+lw/2)) $((ly+lh/2)), sleep 80, scroll 0 40, sleep 500
expect "G-24: wheel back to the bottom reticks it" "$(get log-dump filters.follow limit:=0)" true
"$dev/realpointer" "$dir" abs $((lx+lw/2)) $((ly+lh/2)), sleep 50, fscroll 0 -80, sleep 20, fscroll 0 -80, sleep 20, fstop, sleep 600
expect "G-24: touchpad scroll up unticks follow" "$(get log-dump filters.follow limit:=0)" false
ctl -q log-close

# M-04: the chooser shows the URL exactly; Tab skips the URL box; Return
# opens; focus goes back to the pane the URL came from.
long="https://example.com/$(python3 -c 'print("x"*600)')?q=a-b"
ctl -q url target="$long" action=choose
eventually "chooser open" open get url-chooser focus
expect "M-04: shown text is the URL" "$(get url-chooser shown_text)" "$long"
ctl url-chooser --get markup | grep -q 'insert_hyphens="false"' || fail "M-04: Pango may insert hyphens at wraps"
"$dev/realkeys" "$dir" -k Tab
expect "M-04: Tab from Open goes to Cancel" "$(get url-chooser focus)" cancel
"$dev/realkeys" "$dir" -k Escape
eventually "chooser closed" false get url-chooser open
ctl -q url-sink clear:=true
ctl -q url target=https://example.com/return action=choose
eventually "chooser open" open get url-chooser focus
"$dev/realkeys" "$dir" -k Return
eventually "Return opens" "https://example.com/return" get url-sink recorded.0.target
"$dev/realkeys-xkb" "$dir" ctrl+shift+Return >/dev/null
eventually "a second pane" 2 sh -c "\"$dev/wmctl\" -s \"$dir/ctl.sock\" dump text:=false | python3 -I -c \"import json,sys; print(len(json.load(sys.stdin)['result']['panes']))\""
eventually "the new pane has focus" 1 ctl dump text:=false --get focused_pane
ctl -q url target=https://example.com/from-pane-0 action=choose pane:=0
eventually "chooser open" open get url-chooser focus
"$dev/realkeys" "$dir" -k Escape
eventually "M-04: focus back on the source pane (Escape)" 0 ctl dump text:=false --get focused_pane
"$dev/realkeys-xkb" "$dir" ctrl+shift+l >/dev/null   # chords: realkeys-xkb (physical keys, real modifiers), not realkeys
eventually "focus moved to pane 1" 1 ctl dump text:=false --get focused_pane
ctl -q url target=https://example.com/from-pane-0 action=choose pane:=0
eventually "chooser open" open get url-chooser focus
"$dev/realpointer" "$dir" abs $((mx+40)) $((my+mh-40)), sleep 60, down, sleep 50, up, sleep 400
eventually "backdrop click closes the chooser" false get url-chooser open
eventually "M-04: focus back on the source pane (backdrop)" 0 ctl dump text:=false --get focused_pane
"$dev/realkeys" "$dir" 'echo typed-into-0' -k Return
ctl -q wait contains=typed-into-0 timeout_ms:=3000 || fail "M-04: typed keys did not reach the source pane"
echo "smoke-panels: ok  M-04 keys go to the source pane"
# Back to what the restart below expects.
ctl -q settings-set theme=light fade:=25 min_cols:=100 max_cols:=120

# --- 5. restart: settings persisted and applied at start -----------------
ctl -q quit || true
sleep 1
"$dev/headless" stop "$dir" >/dev/null 2>&1 || true
first="$dir"
dir="$("$dev/headless" start --host -- \
  "XDG_CONFIG_HOME=$first/home/.config" "XDG_STATE_HOME=$first/home/.local/state" | tail -n1)" || fail "second start"
dir2="$dir"
echo "smoke-panels: second run dir $dir (config and state of the first)"
ctl -q wait contains='$' timeout_ms:=10000 || fail "terminal never showed a prompt (second run)"
expect "settings after restart" "$(ctl settings | json 'v["applied"]')" "{'theme': 'light', 'unfocused_fade': 25, 'min_cols': 100, 'max_cols': 120}"
expect "app scheme after restart" "$(get settings app_scheme)" light
expect "terminal scheme after restart" "$(ctl dump text:=false --get scheme)" light
grep -q 'settings loaded (engine): theme=light' "$dir/app.log" || fail "settings were not loaded at start"
ctl -q screenshot path="$dir/restarted-light.png"
grep -q 'bulk entry' "$logfile" || fail "log file not kept across the restart"
grep -c 'client started' "$logfile" | grep -qx 2 || fail "expected two 'client started' lines in the file"
echo "smoke-panels: ok  log file kept across the restart"

for d in "$first" "$dir"; do
  if grep -qiE 'panic|segmentation fault|leaked' "$d/app.log"; then fail "crash or leak in $d/app.log"; fi
done
ctl -q quit || true
sleep 1
"$dev/headless" stop "$dir" >/dev/null 2>&1 || true
for d in "$first" "$dir"; do
  left="$(pgrep -f -- "$d/" || true)"
  [[ -z "$left" ]] || fail "processes left for $d: $left"
done
echo "smoke-panels: OK $first $dir"
