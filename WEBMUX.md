# webmux-gtk: fork notes

This checkout is Ghostty (`0fa3d577`, tag `vt-1.0.0`) with a second GTK shell,
`src/apprt/webmux/`, that builds the `webmux-gtk` binary: the native
Linux client for webmux. The contract (goal, rules, architecture) is
`../../docs/native-client.md`; this file is how to work in the fork.

Everything below runs from the fork root (`gtk/ghostty`). Commands that
need the toolchain go through Ghostty's nix dev shell
(`nix develop . -c …`); the `webmux-dev/` scripts do that for you.

## Quick reference

| What | Command |
| --- | --- |
| Build webmux-gtk (debug) | `webmux-dev/build` → `zig-out/bin/webmux-gtk` |
| Build stock Ghostty (unchanged) | `nix develop . -c zig build -Dapp-runtime=gtk` → `zig-out/bin/ghostty` |
| Unit tests of the shell | `nix develop . -c zig build test -Dapp-runtime=gtk -Dwebmux=true -Dtest-filter=apprt.webmux` |
| Start headless | `D=$(webmux-dev/headless start)` (prints the run dir) |
| Drive it | `webmux-dev/wmctl -s $D/ctl.sock dump` (or `source $D/env` once, then `wmctl dump`) |
| Screenshot | `webmux-dev/wmctl -s $D/ctl.sock screenshot path=$D/shot.png`, then open the PNG |
| Real typing (text only) | `webmux-dev/realkeys $D 'echo hi' -k Return` |
| Real chords, any layout | `webmux-dev/realkeys-xkb $D ctrl+shift+Return` (`--layout ru`, `--group 1`) |
| Real pointer | `webmux-dev/realpointer $D abs 400 300, down, sleep 50, abs 400 200, up` |
| Dev mode (local host, remote pane) | `D=$(webmux-dev/headless start --host)` |
| Restart the dev host's server | `webmux-dev/headless host-restart $D` |
| Stop | `webmux-dev/headless stop $D` |
| Every smoke, one line each | `webmux-dev/smoke --all` (two at a time, `-j N` to change; logs in a fresh `/tmp/wm-smokes-*`) |
| The edit-and-try subset, about a minute | `webmux-dev/smoke --quick` (integration, workspace, host side by side) |
| The app (chrome) | `webmux-dev/smoke` (Connections → fake ssh → freshly deployed host → terminal, retry, sleep, quit) |
| The areas together | `webmux-dev/smoke --integration` (two hosts, workspaces, settings, clipboard, URLs, K-18, resilience) |
| Dev mode, remote pane | `webmux-dev/smoke --host` |
| Terminal-pane features | `webmux-dev/smoke --pane` |
| File browser | `webmux-dev/smoke-files` (dev mode; the pane in the workspace) |
| Workspace, panels | `src/apprt/webmux/workspace/smoke`, `src/apprt/webmux/panels/smoke.sh` |
| The app against fake hosts | `D=$(webmux-dev/headless start -- WEBMUX_GTK_SSH=$PWD/webmux-dev/fake-ssh)` (see The chrome) |

A first build of either flavour takes ~5 minutes cold; after that an
edit-build cycle of the shell is 15–60 s. The test filter above runs the
shell's own tests; the test binary also always runs ~78 core tests that
ignore filters, so the total is larger than the shell's count. Look for
"N pass (N total)", i.e. no failures.

## How the shell is selected in the build

`app_runtime` stays `.gtk` (so the ~20 core files that register GObject
types under `.gtk => …` keep working, and SharedDeps still links GTK,
libadwaita, EGL and Wayland). One extra build option swaps the shell:

- `-Dwebmux=true` sets `Config.webmux`; only then is `webmux = true` added
  to the generated `build_options` module (stock builds get the exact
  same options file as upstream).
- `src/apprt.zig` resolves `apprt.runtime` to `src/apprt/webmux.zig` when
  `build_options` has a `webmux` declaration, else to `apprt/gtk.zig`.
- The executable is named `webmux-gtk` instead of `ghostty`.

Consequences worth knowing:

- Zig loads (parses) every file reachable through `@import` string
  literals, even in branches that are never analysed. So the shell's files
  are *parsed* in stock builds too, and a syntax error anywhere under
  `src/apprt/webmux/` breaks `zig build` for stock Ghostty as well. They are
  never semantically analysed or compiled into the stock binary.
- Ghostty's gresource bundle (its Blueprint UI) is still compiled and
  linked into webmux-gtk because SharedDeps does that for every GTK build;
  nothing uses it. Harmless; removing it would need another upstream edit.
- `zig-out/share/ghostty` (terminfo, shell integration) is installed for
  both binaries; the core finds it relative to the executable.
- Ghostty debug builds are not byte-reproducible: rebuilding *unchanged*
  sources gave a different `ghostty` hash than the earlier build of the
  same sources (`e236265d…` vs `643be8b4…`, and `18bef133…` with our edits).
  So "stock is unchanged" rests on the reasoning above, not on hashes.

## Upstream edits

Every change to a pre-existing Ghostty file. Keep this list complete.

| File | What | Why |
| --- | --- | --- |
| `src/build/Config.zig` | `webmux: bool` field; `-Dwebmux` option; `addOptions` emits `webmux = true` only when set | the build switch for the new shell; stock options unchanged |
| `src/build/GhosttyExe.zig` | exe `.name` is `webmux-gtk` when `cfg.webmux` | binary name from the contract |
| `src/apprt.zig` | `.gtk =>` arm picks `apprt/webmux.zig` when `build_options` declares `webmux` (one line) | selects the shell at compile time |
| `src/termio/backend.zig` | `webmux` variant in `Kind`, `Config`, `Backend`, `ThreadData`; one `.webmux =>` arm per switch | the union the network backend lives in |
| `src/termio.zig` | `pub const Webmux = @import("termio/Webmux.zig");` (one line) | exports the backend |
| `src/Surface.zig` `init` | one `@hasDecl(apprt.runtime.Surface, "termioBackend")` call; `io_exec` → `io_backend`, which is `Webmux.init` when the apprt returned a config and the unchanged `Exec.init` otherwise (+17/−5) | the backend seam: an apprt that does not declare `termioBackend` gets stock behaviour |
| `src/Surface.zig` `childExitedAbnormally` | `.webmux => &.{"webmux"}` switch arm | exhaustiveness only; never reached |
| `.gitignore` | `zig-out-release/` | the release build's output directory (`make linux-client` in the webmux repo) |

Not edited: `flake.nix` (tools come from the pinned nixpkgs via
`--inputs-from .`), `SharedDeps.zig`, `GhosttyI18n.zig`.

The network backend is documented at the top of `src/termio/Webmux.zig`
(config, events, `send`, behaviour); its protocol core and tests are in
`src/termio/webmux/`, the client library in `src/webmux/net/`.

## Directory map

```
src/apprt/webmux.zig          apprt entry: App, Surface, resourcesDir + the shell's exports
src/apprt/webmux/
  App.zig                     apprt App struct the core holds; forwards to Application
  Surface.zig                 apprt Surface struct (inside each pane); the core's view of a pane
  application.zig             WebmuxApplication: run loop, config, CSS, actions, performAction table
  window.zig                  WebmuxWindow: top-level window; capture-phase shortcut dispatch
  pane.zig                    WebmuxTerminalPane: one terminal (input, IME, mouse, clipboard, …)
  terminal/remote.zig         a pane's webmux session: backend config, events → main loop → pane
  terminal/factory.zig        iface.factories.terminal: the Pane vtable over TerminalPane
  terminal/clipboard.zig      paste keys, image paste/conversion, clipboard sync hook, copy, PRIMARY
  terminal/links.zig          link/OSC 8 hit testing, Alt+click arrows, sticky-bottom band
  terminal/terminal.css       the pane's stylesheet (scrollbar), loaded by the pane class
  iface.zig                   the seams between feature areas (the lead's; do not edit)
  iface_test.zig              analyses every iface declaration; registry tests
  features.zig                every area's register(), called once at startup
  chrome/                     window frame, header strip, Connections page, menu, engine wiring,
                              keyring, sleep, first-run import (see The chrome)
  workspace/                  the strip of columns (iface.workspace_factory): layout, sessions,
                              pane frames, animations, persistence; its own smoke
  files/                      the file-browser pane (iface.factories.files): Miller columns,
                              previews, uploads/downloads, watch streams
  panels/                     settings (owner of iface.settings and the colour scheme),
                              connection log window, status toast, URL service; its own smoke.sh
  dev.zig                     dev mode: one connection view on WEBMUX_GTK_DEV_SOCKET
  render_surface.zig          WebmuxRenderSurface: shows the renderer's DMABUF/CPU frames (copied)
  key_event.zig               KeyEvent (real or synthesized), chord parsing
  key.zig                     GDK ↔ Ghostty key translation (copied, Wayland-only)
  shortcuts.zig               the shell's shortcut table (chord → GAction)
  config.zig                  the built-in Ghostty config (Electron defaults, both schemes)
  config_object.zig           WebmuxConfig GObject wrapping a Ghostty config (copied)
  control.zig                 control socket server + command registry
  control/commands.zig        one line per feature that registers commands
  control/core_commands.zig   help, dump, screenshot, text, key, mouse, selection, wait, resize, theme, quit
  mainloop.zig                post work to the GTK main thread from any thread
  style.css                   application stylesheet (embedded)
  class.zig                   Common(): as/ref/unref/private helpers for GObject classes (copied)
  ext.zig, ext/actions.zig    small GTK helpers; GAction table helper (copied)
  weak_ref.zig                typed GWeakRef (copied)
  scale.zig, gsettings.zig    HiDPI geometry, GTK settings readers (copied)
webmux-dev/                   dev scripts: build, headless, wmctl, realkeys, realkeys-xkb (+ with-mods;
                              client in virtual-keyboard/xkb-keys.c), realpointer, pane-point,
                              chrome-click, xterm-keys/, in-session, keyring, fake-ssh, files-fixture,
                              smoke (+ --all), smoke-chrome, smoke-host, smoke-pane, smoke-files,
                              smoke-integration
```

"(copied)" files started as copies of `src/apprt/gtk/` at `f54340ad`; their
header says what changed. Nothing here imports from `src/apprt/gtk/`.

## Running headless

Never run the app on the desktop session (`wayland-0` / `DISPLAY=:2`).
`webmux-dev/headless start [--size 1920x1200] [--scale 2] [-- VAR=val …]`:

- starts **sway 1.12** (from the fork's pinned nixpkgs) with the wlroots
  *headless* backend and the GLES2 renderer on `/dev/dri/renderD128` (Mesa;
  `WEBMUX_WLR_RENDERER=pixman` for a CPU-only compositor);
- in a fresh `/tmp/wm-XXXXXX` with its own `HOME`, `XDG_*_HOME` and
  `XDG_RUNTIME_DIR`, a private D-Bus with no service directories (nothing
  is bus-activated: no portals, no a11y bus), `env -i` for everything, no
  `DISPLAY`, and `WAYLAND_DISPLAY` set to the *absolute path* of the nested
  socket; it refuses to start the app unless that socket exists and sway
  answers on IPC;
- a persistent virtual keyboard (`wtype -` on a FIFO) so the seat has a
  keyboard from the start (see `realkeys` below);
- then `webmux-gtk` with `GDK_BACKEND=wayland` and the control socket at
  `$D/ctl.sock`, and waits until the socket answers. The app also gets
  `WEBMUX_GTK_SLEEP_BUS=session` (logind's PrepareForSleep is watched on
  the private bus, never the real system bus) and `GSETTINGS_SCHEMA_DIR`
  pointing at GTK's own schemas (without them GtkFileChooser aborts the
  app and GLib asserts in `g_settings_schema_source_lookup` at startup);
- with the control socket on, the panels' URL service records instead of
  launching (`WEBMUX_GTK_URL_SINK`, `url-sink`): no test opens a browser
  or file manager.

The run dir holds `app.log`, `app.exit` (exit status once the app has
exited), `sway.log`, `env`, `pids`. Windows are floating, so `resize`
works. Any `VAR=val` after `--` goes to the app's environment (e.g.
`GTK_IM_MODULE=gtk-im-context-simple`, `GSK_RENDERER=cairo`,
`WAYLAND_DEBUG=1`, `GDK_DEBUG=events`).

`webmux-dev/headless stop $D` quits the app over the socket (kills it
only if it does not exit), stops sway, the keyboard and the bus, and
kills anything still referencing the run dir (by command line or by the
run's `XDG_RUNTIME_DIR`), except itself and its callers, whose command
lines often name the run dir. `status $D` shows what is
alive. Run dirs are not deleted.

Real input through the compositor (the true GTK path, including the input
method and the window's capture-phase shortcuts):

Which tool for what:

- `webmux-dev/realkeys $D <wtype args>`: **typing text only** (`'echo hi'
  -k Return`, `-k Escape`, `-k Shift_L` for a fresh input serial). wtype
  uploads its own keymap and gives keysyms arbitrary keycodes, so chords
  matched by physical key do not work through it, and Ghostty keeps the
  *physical* key when it cannot map the keysym back (a wtype '+' arrives
  as Tab): stick to letters, digits, space, `-`, `.`, `/`. Shift+Tab there
  needs `-M shift -k ISO_Left_Tab -m shift` (not `Tab`).
- `webmux-dev/in-session $D <cmd>` runs any Wayland client inside the
  nested session: `wl-paste -n` / `wl-copy -o TEXT` (clipboard),
  `swaymsg -t get_tree`, `wayland-info`.
- `webmux-dev/realkeys-xkb $D [--layout L] [--variant V] [--group N]
  KEYSPEC...` (or `-` for commands on stdin): **every chord, every
  layout test, the input method**. A virtual keyboard with a real XKB
  layout (default `us`): real evdev keycodes and levels, and modifiers
  are real Control_L/Shift_L/Alt_L/Super_L presses and releases (GTK's
  Ctrl+Shift+U entry needs the releases). KEYSPEC is `[mod+]...KEY` or
  `sleep:MS`. A KEY a US keyboard has unshifted (`h`, `1`, `bracketleft`,
  `Return`, `Left`, `Prior`, `F5`, `KP_Enter`, `Shift_L`) names that
  *physical* key under any layout (`--layout ru ctrl+shift+h` is
  Ctrl+Shift+Р, `--layout fr ctrl+1` is Ctrl+&); any other keysym
  (`exclam`, `ISO_Left_Tab`, `eacute`) is looked up in the layout's group
  and adds Shift when it sits on the shifted level. `--layout us,ru
  --group 1` locks the second group. Built on first use into
  `.build/xkb-keys`.
- `webmux-dev/with-mods $D shift -- CMD...` holds modifiers (real key
  presses, through realkeys-xkb) while CMD runs, e.g. a `realpointer`
  shift-click.
- `webmux-dev/realpointer $D abs X Y, down, up, scroll DX DY, ...`: **the
  mouse**, a wlr virtual pointer (real gestures, motion, wheel; `down`
  takes 0x110 left, 0x111 right, 0x112 middle). The pointer device is
  destroyed when the command exits, so keep a whole drag, a hover, or a
  click that depends on a preceding motion in **one** call (a later call
  starts from a new device). `webmux-dev/pane-point $D COL ROW [PANE]`
  prints the screen point of a terminal cell's centre;
  `webmux-dev/chrome-click` does the same for chrome widgets by name
  (see The chrome).
- `webmux-dev/xterm-keys/run $D`: every key × modifier from xterm.js's
  Keyboard.ts (expected bytes computed by xterm's own code, needs the
  Electron checkout's node_modules) sent with real keys to a raw reader in
  the session, compared byte for byte. `XTERM_KEYS_ONLY=a,b` and
  `XTERM_KEYS_MODES=normal|app` narrow it.
- `webmux-dev/ws-proxy.py LISTEN UPSTREAM_FILE LOG [CTL]`: a unix-socket
  WebSocket proxy (smoke-host runs the dev session through it via
  `WEBMUX_GTK_DEV_SOCKET`): logs every close frame and whether each side
  ended with EOF or a reset, and injects a raw JSON text frame sent as one
  line to CTL. This is the way to reproduce frames the host never sends:
  `smoke-host` injects a title with raw control characters
  (`{"type":"title","title":"T\u0007itle\u001b]0;evil\u0007 end"}`, shown
  as `T␇itle␛]0;evil␇ end`) and output with a lone surrogate (shown as
  U+FFFD); start a run with `headless start --host --
  WEBMUX_GTK_DEV_SOCKET=<proxy socket>` and send the same lines to CTL. `webmux-dev/raw-reader.py alt|mouse OUT` (run in a session)
  records the bytes a scroll produces on the alternate screen or with
  mouse reporting.
- `WEBMUX_GTK_REPLAY_PAUSE_US` (app environment): the pause per ~20 ms of
  snapshot replay, default 500, 0 to measure without it.
- The control socket's `mouse` command still exists for quick checks; it
  enters at the core calls the GTK gesture handlers make (no focus or
  gesture path).

### What actually renders (verified)

- GTK uses **GskGLRenderer** (`dump` → `window.gsk_renderer`).
- Ghostty renders on its own EGL context (Mesa, OpenGL 4.6) and every
  frame reaches the pane as a **DMABUF** (`dump` → `panes[i].frames`:
  `dmabuf` counts up, `memory` stays 0). Even with `GSK_RENDERER=cairo`
  GTK imports the DMABUFs; the CPU fallback (`memory` frames) has not been
  observed and is unexercised.
- `screenshot` re-renders the window's last render node with the window's
  own GSK renderer, so it does not depend on the compositor and contains
  the terminal texture; at scale 2 it is full device resolution.

## Control socket

Enabled when `WEBMUX_GTK_CONTROL=<path>` is set (the headless script sets
it). Newline-delimited JSON, one request → one response, in order per
connection: `{"cmd":"dump","id":1}` → `{"id":1,"ok":true,"result":…}` or
`{"id":1,"ok":false,"error":"…"}`. `wmctl help` lists commands.

| Command | Arguments | Result |
| --- | --- | --- |
| `help` | | name + help of every registered command |
| `dump` | `text` (bool, default true) | window size/title/scale/GSK renderer, scheme, `focused_pane`, `last_shortcut`, and per pane (every `TerminalPane` in the window's widget tree): `session_id`, `link` (`connecting`\|`up`\|`down`), `snapshots` (1 + one per reconnect), `last_replay` (`bytes`, wall `ms` of the last snapshot replay), `exit_code` (all null for a local pane), title, pwd, `size_px`, `grid` (what the shell told the core), `terminal` (cols/rows/cursor as the io thread applied them), `cell_px`, `content_scale`, `renderer_health`, `frames`, `text` (visible screen) |
| `screenshot` | `path`, `scale` (default: surface scale) | path, width, height |
| `text` | `text` | types it key by key (press+release per character; `\n` → Return, `\t` → Tab) through the same path as `key` |
| `key` | `key` ("ctrl+shift+w", "Return", "alt+Left", "a"), `action` tap\|press\|release | `consumed`, `shortcut` |
| `mouse` | `action` move\|press\|release\|click\|drag\|scroll, `x`,`y` (CSS px in the pane) or `col`,`row`; `x2`,`y2`/`col2`,`row2` for drag; `button`; `mods` ("ctrl+shift"); `dx`,`dy` for scroll | `consumed`, `has_selection`, `mouse_reporting` |
| `selection` | | selected text or null |
| `wait` | `contains`, `timeout_ms` (5000) | answers when the focused pane's visible text contains the string |
| `resize` | `width`, `height` | sets the window's size (floating in sway, so it applies) |
| `theme` | `scheme` dark\|light | switches the terminal colours of every pane |
| `clipboard-sync` | | runs `iface.hooks.clipboardSync` for the focused pane's connection (what the chrome does on window focus) |
| `focus` | `value` (bool) | focuses the focused pane, or clears the window's focus (unfocused cursor) |
| `shown` | `value` (bool) | `setShown` on the focused pane; `dump` → `visible` |
| `quit` | | answers, then quits |

Synthesized keys (`key`, `text`) go through `KeyEvent.synthesize` →
`Window.dispatchKey` → `shortcuts` → `TerminalPane.handleKey` → Ghostty's
key encoder: the same code as a real key after GDK, minus the input method
(which needs a real `GdkEvent`). Use `realkeys-xkb` to exercise the IME.

`wmctl`: `wmctl [-s SOCK] CMD key=value key:=json …`, `--get a.0.b` prints
one field of the result, `-q` silences, exit status 1 if a reply failed.
String values interpret `\n \t \e \\`.

## Conventions

### GObject classes

Classes are Zig `extern struct`s using zig-gobject, as in Ghostty's own
shell (read the long comment on `Application` in
`src/apprt/gtk/class/application.zig` once). Type names are `Webmux…`.
State lives in `Private`; `Common(Self, Private)` gives `as`, `ref`,
`unref`, `private`. A minimal widget:

```zig
pub const Badge = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "WebmuxBadge",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const activated = struct {
            pub const name = "activated";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };
    };

    const Private = struct {
        label: *gtk.Label = undefined,
        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.* = .{};
        priv.label = gtk.Label.new("hi");
        priv.label.as(gtk.Widget).setParent(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.private().label.as(gtk.Widget).unparent();
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;
        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "badge");
            gtk.Widget.Class.setLayoutManagerType(class.as(gtk.Widget.Class), gtk.BinLayout.getGObjectType());
            signals.activated.impl.register(.{});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }
    };
};
```

Properties: `gobject.ext.defineProperty` + an accessor
(`C.privateStringFieldAccessor("title")`, `privateShallowFieldAccessor`,
`privateObjFieldAccessor`); register in `Class.init` with
`gobject.ext.registerProperties`; after changing the field call
`self.as(gobject.Object).notifyByPspec(properties.x.impl.param_spec)`.
See `TerminalPane` for title/pwd/focused. Signals: `defineSignal`, then
`signals.x.impl.emit(self, null, .{args}, null)`; connect with
`Type.signals.x.connect(obj, *Data, callback, data, .{})` where the
callback is `fn (*Type, …, *Data) callconv(.c) …` (GTK booleans are
`c_int`, never Zig `bool` in callbacks).

### UI in code, not Blueprint

The stock shell uses Blueprint templates compiled into a gresource by the
build (`SharedDeps.zig`). Adding our own would need build edits, so the
webmux shell builds its widget trees in code (`init` creates children,
connects signals, adds controllers — `TerminalPane.init` is the model).
No `.blp`, no `.ui`, no gresource of ours. Static assets are compiled in
with `@embedFile` (CSS today; fonts/icons the same way).

Styling: `src/apprt/webmux/style.css` is embedded and installed once for
the display at application priority. Give a widget a CSS name in
`Class.init` (`setCssName`) or classes (`widget.addCssClass`), and add
rules to `style.css`, or keep your area's own `.css`: add one
`@embedFile` line to the `stylesheets` array at the top of
`application.zig` (the chrome does), or install your own provider from
`Application.new` with one line (the panels' `style.zig`, the files'
`css.zig`). The light/dark switch is libadwaita's
(`Application.setScheme` forces it; the panels' settings own it). Adwaita
colour names work, but `@media (prefers-color-scheme)` does **not** follow
the forced scheme in an application CSS provider: for light/dark variants
toggle a CSS class from `AdwStyleManager:dark` (the chrome puts `wm-light`
on the main window; the workspace and the panels do the same for theirs).

### References and lifetimes

- A widget's parent owns it. `newInstance` returns a floating reference
  for widgets; adding it to a container sinks it. Don't `unref` widgets
  you have parented; remove them (`unparent`/container remove) instead.
- Plain GObjects (not widgets) start with one strong reference you own;
  `unref` in `dispose` (idempotent: null the field) or `finalize`.
- Hold other objects you don't own through `WeakRef(T)` (`weak_ref.zig`):
  `get()` returns a strong ref (unref it) or null; call `deinit()` from
  your `dispose`.
- Anything handed to an async callback or an idle source takes a strong
  reference first (`self.ref()`) and drops it in the callback (see
  `TerminalPane.updateFocus` / `idleFocus`, `Window.paneCloseRequest`).
- Don't destroy things from inside a core callback: the core may still be
  on the stack. Defer to `glib.idleAddOnce` (the window does this when its
  pane asks to close).
- A pane's core surface is created on first allocation and destroyed in
  the pane's `finalize`.

### Actions and shortcuts

Actions are GActions on the application (`app.`), a window (`win.`) or a
widget group. Add them with `ext.actions`:

```zig
// window.zig, in init():
const actions = [_]ext.actions.Action(Self){
    .init("close-pane", actionClosePane, null),
    .init("focus-left", actionFocusLeft, null), // new
};
ext.actions.add(Self, self, &actions);

fn actionFocusLeft(_: *gio.SimpleAction, _: ?*glib.Variant, self: *Self) callconv(.c) void { … }
```

Then bind a chord in `shortcuts.zig`'s `table`, using GTK accelerator
syntax with the *unshifted* key name (the Linux chord modifier is
Ctrl+Shift, see `electron/main.js` `MOD`):

```zig
.{ .accel = "<Control><Shift>Left", .action = "win.focus-left" },
```

The window's capture-phase key controller matches the chord before the
pane sees the key and activates the action from the focused widget, so
`app.`, `win.` and any group on the way up resolve. A matched chord is
always consumed. Ghostty's own keybindings are cleared (`config.zig`);
only `terminal_keybinds` there reach the core (copy/paste for now, since
they need the terminal's selection). Test a shortcut with
`wmctl key key=ctrl+shift+left` (`dump` → `last_shortcut`) and for real
with `realkeys-xkb $D ctrl+shift+Left`.

### Control-socket commands

Every feature adds its own commands from its own file:

```zig
// src/apprt/webmux/layout/control.zig
const control = @import("../control.zig");
const Application = @import("../application.zig").Application;

pub fn register() void {
    control.register(.{ .name = "layout", .help = "columns and panes", .handler = &layout });
}

fn layout(req: *control.Request) void {
    const win = Application.default().activeWindow() orelse return req.fail("no window", .{});
    const n = req.int("column") orelse 0; // arguments: req.string/int/boolean/get
    req.ok(.{ .columns = win.columnCount(), .asked = n }); // anything std.json can serialize
}
```

…and one line in `control/commands.zig`:
`@import("../layout/control.zig").register();`. Handlers run on the main
thread. Answer exactly once with `req.ok(value)` or `req.fail(fmt, args)`,
either before returning or later (keep the `*Request`; see `wait`).
Scratch memory: `req.allocator()`, freed after the answer. Braces in
`fail` format strings must be doubled (`{{x}}`).

### Marshalling to the main loop

Pure packages call back on their own threads. Cross with
`mainloop.post(value, func)` (`mainloop.zig`): it copies `value`, queues
an idle on the default main context and runs `func(&copy)` on the GTK
main thread, in order per posting thread. Take a strong ref (or a WeakRef)
on any GObject the value points at:

```zig
const Up = struct {
    pane: *TerminalPane,
    fn run(self: *Up) void {
        defer self.pane.unref();
        self.pane.setTitle("connected");
    }
};
// on the supervisor thread:
mainloop.post(Up{ .pane = pane.ref() }, Up.run);
```

`mainloop.isMainThread()` / `assertMainThread()` for checks. The core's
own threads already go through the core's mailbox and `App.wakeup`.

### Logging

`const log = std.log.scoped(.webmux_<area>);` Debug builds print debug
level and up to stderr (the headless `app.log`). GLib/GTK messages are
routed into the same log (`scope glib`). Never log keystrokes, terminal
contents, clipboard contents or passwords.

## Feature registration

Every feature area registers itself in one place, `src/apprt/webmux/features.zig`,
called once from `Application.startup` before the first window:

```zig
pub fn registerAll() void {
    @import("terminal/factory.zig").register();
    @import("workspace/register.zig").register(); // your line
}
```

A `register()` lives in your own directory, only assigns `iface` entries
(`iface.factories.files = .{ .create = create }`,
`iface.workspace_factory = …`, `iface.services.status = …`) and creates no
widgets. Control-socket commands keep their own list,
`control/commands.zig` (one `register()` line per area's `control.zig`).

## Panes (`iface.zig`)

The interface between containers and panes is `src/apprt/webmux/iface.zig`
(`Pane`, `PaneHost`, `PaneFactory`, `factories`); read its comments first.
What it does not say, for terminal panes:

- `iface.factories.terminal.create(conn, session_id, state, host)` returns
  a `TerminalPane` widget attached to `session_id` over
  `conn.socket_path`; the session must already exist (the workspace
  creates sessions with `net.api.createSession`). `state` is ignored and
  `saveState` returns null.
- The terminal (and the WebSocket) starts on the pane's first size
  allocation, so the host learns the right grid size from the start. A
  pane that is never shown never attaches.
- `host.titleChanged` fires for the session's title (from the host) and for
  OSC titles the terminal itself processes; read it with `pane.title()`.
- `host.linkChanged(id, false)` on an outage (the backend retries 1 s
  doubling to 10 s and prints the dim "[disconnected — reconnecting…]"
  line), `(id, true)` when the socket reopens (the fresh snapshot repaints
  right after). Nothing is sent for the very first attach.
- `host.closeRequested(id)` after the session exited (1.2 s after the red
  "[session exited: N]" line, as app.js does), immediately when the host
  says the session does not exist, and when the terminal closes itself.
  Remove the widget from an idle callback; that finalizes the pane, stops
  its backend (closing the socket with a WebSocket close handshake, at
  most 250 ms; the session keeps running on the host unless it exited)
  and frees everything.
- `setShown(false)` pauses rendering (the terminal stays attached;
  deviation 4); `setShown(true)` resumes.
- `cellWidthPx()` is null until the terminal started; it changes with the
  scale and font size.
- Put pane chrome around the widget, never inside it. The widget is the
  terminal (4px padding inside, from config.zig; 7 px cell at 13 px,
  floor like xterm's WebGL renderer via `adjust-cell-width = -1`) plus a 10px scrollbar
  column on its right (PARITY T-10), so for the width rule a terminal of C
  columns needs `C * cellWidthPx / scale + 8 + 10` CSS px.
- The pane handles these keys itself, after the window's shortcuts:
  Ctrl+V, Ctrl+Shift+V, Ctrl+Alt+V, Ctrl+Shift+C, Shift+Insert,
  Ctrl+Insert, Shift+PageUp/PageDown. Every other key, while the app has
  not enabled the Kitty keyboard protocol, is encoded as xterm.js 5.5
  encodes it (terminal/xterm_keys.zig) after the input method has seen it.
- Pointer rules that follow the Electron client rather than Ghostty: a
  wheel notch is 3 lines at every display scale (deviation 18); a
  touchpad pixel is 12 CSS px as Chromium on Wayland makes it, against a
  17 CSS px row, Alt ×5, and the result depends only on the distance, not
  on how the touchpad slices it (xterm.js 5.5: on the normal screen a
  pixel position accumulates and the viewport sits at its rounded row, the
  fraction kept until the viewport moves some other way or hits the top or
  bottom; alternate-screen arrows and wheel reports send whole lines of an
  accumulated signed fraction and keep the rest, never reset). Double-click selects by xterm's word rules and a
  click then Shift+click selects between them (terminal/selection.zig);
  a drag after a double-click still extends by Ghostty's words (core).
- Typed input that follows Ctrl+V / Ctrl+Shift+V while the clipboard is
  being read is held and sent after the pasted text (at most 1 s).
- Titles are shown as the Electron label shows them (`displayTitle`):
  whitespace collapsed and trimmed, C0 controls as control pictures.
- Status messages: `iface.services.status(conn_name, text)` takes the
  connection's profile name (workspace, file browser and terminal pass
  theirs; app-wide callers pass null). The panels' toast shows a host's
  message only while that host is in front (the chrome reports the front
  with `toast.setFront`); one from a host behind is held for the rest of
  its 3 s and shown if the host comes to the front in time.
- `paste-result` and `open-url` events go to `iface.services.status` /
  `.url(…, .choose, pane_widget)` (open-url deduped per host by id); other
  sessions' `session-title` fan-out is not used (every pane has its own
  socket and gets its own title).
- Shell-side access beyond the vtable (for the terminal-pane area and the
  control socket): `gobject.ext.cast(TerminalPane, pane.widget)` gives
  `sessionId()`, `getLink()`, `remoteState()`, `core()`; side-channel
  frames go through `core().io.backend.webmux.send(…)` (see the top of
  `src/termio/Webmux.zig`).
- `Window.panes(buf)` / `focusedPane()` find terminal panes anywhere in
  the window's widget tree, so the control socket works with any container.

## Dev mode

Run any feature against a real host without ssh:

```sh
webmux-dev/build
D=$(webmux-dev/headless start --host)      # isolated host + app in dev mode
webmux-dev/wmctl -s $D/ctl.sock dump        # panes[0].session_id, link "up"
webmux-dev/wmctl -s $D/ctl.sock text text='ls\n'
webmux-dev/headless host-restart $D         # server only: link down, reconnect
webmux-dev/headless stop $D                 # app, host server, pty host, sway, bus
```

`--host` starts `host/dist/webmux-host-linux-x64 serve` (override with
`WEBMUX_HOST_BIN`) isolated under the run dir: `$D/h.sock` is its HTTP
socket, `$D/host/{run,tmp,home}` its runtime dir, TMPDIR and HOME,
`$D/host.log` its log, and a unique pty-host name (`ptyname=` in
`$D/pids`). Sessions run `sh` with `PS1='$ '` (set `WEBMUX_HOST_SHELL=bash`
for bash) and `DISPLAY=no-such-display.invalid:0`, so nothing in a session
can reach this machine's X server. The app gets `WEBMUX_GTK_DEV_SOCKET=$D/h.sock` (also in
`$D/env`). `headless stop` runs `ptyhost --name N shutdown` (killing every
session), stops the server and checks nothing of the host is left.

With `WEBMUX_GTK_DEV_SOCKET` set the window shows one connection view, an
`iface.Conn{ socket_path, slug = "dev", name = "dev" }`, with no chrome:

- the registered workspace (it is, in the merged app): its widget fills
  the window, with `setFront(true)` and `grabFocus()`; the
  `WorkspaceHost` only logs (`webmux_dev` scope in `app.log`). Its layout
  file is `$XDG_STATE_HOME/webmux-gtk/layout/dev.json` (pass
  `XDG_STATE_HOME=<dir>` after `--` to start from a prepared one, as
  `smoke-files` does). File browsers are opened in it (`pane-command
  name=new-files`);
- otherwise, or with `WEBMUX_GTK_DEV_SESSION` set, one terminal pane from `iface.factories.terminal`, attached to
  the host's first session (one is created if the host has none). When it
  closes the window shows "dev: the session ended" and the app keeps
  running. The dev `PaneHost` sets the window title and logs link changes.

The chrome's connection engine runs in dev mode too (`iface.engine`), with
no connections: the settings store, the connection log (the dev
workspace's page entries appear under `dev`), the keyring and the panels
behave as in the app. Download folders for `dev` (not a saved profile) are
remembered for the run only.

Without the variable the app is the application: header strip and
connection page (see The chrome). There is no local-shell pane any more.

Testing your area there: register your factory or workspace in
`features.zig`, start `--host`, drive it through the control socket
(your own commands in your `control.zig`), and look at `app.log` and
screenshots. Make sessions with `net.api` or by typing into a terminal.
`WEBMUX_GTK_DEV_SESSION=<id>` (app env: `headless start --host --
WEBMUX_GTK_DEV_SESSION=…`) makes the dev view a single terminal pane
attached to that id as is, even one the host does not have (the `error`
frame, T-39; the workspace never attaches a session the host does not
list).

`webmux-dev/smoke --host` (script `webmux-dev/smoke-host`) is the
reference: type, server restart with exactly one link-down and an identical
repaint, `exit 3` and the pane going away after the delay, clean teardown.

## The chrome

`src/apprt/webmux/chrome/` (the window frame, header pills, connection
page, menu, engine wiring). `hub.zig` holds the state: the `conn.Engine`
(published as `iface.engine`), one entry per connection in pill order,
and which view is in front; `hostview.zig` is a connection's content view
(the registered workspace, else one terminal on the host's first
session); `header.zig`, `page.zig`, `menu.zig` are the UI;
`keyring.zig` the Secret Service over D-Bus (GIO, no libsecret);
`sleep.zig` logind's PrepareForSleep; `import.zig` the first-run import
of the Electron client's profiles; `control.zig` its control commands
(`conns`, `page`, `pill`, `header`, `show`, `connect`, `disconnect`,
`menu`, `sleep-resume`, `keyring`; `wmctl help`).

Development knobs (environment of the app):

| Variable | Effect |
| --- | --- |
| `WEBMUX_GTK_SSH=<path>` | the ssh program the engine runs (default `ssh` from PATH) |
| `WEBMUX_GTK_SLEEP_BUS=session` | watch PrepareForSleep on the session bus instead of the system bus (the headless script sets it) |

Fake hosts: `webmux-dev/fake-ssh` stands in for ssh. Every host is a
directory `$D/remote/<host>` used as the remote HOME; deploy pushes the
real payload (`electron/payload`) there and starts the real webmux-host;
`-N -L` becomes a socat relay. `badhost` fails name resolution,
`$D/remote/<host>/ssh-down` refuses, `$D/remote/<host>/password` demands
that password through the askpass helper, `$D/remote/<host>/slow` stalls.
Kill a tunnel with `pkill -f "UNIX-LISTEN:$D/run/webmux-gtk/"`. Its
pgrep/pkill are stubs, so Restart Sessions can never touch a real pty host.

Real pointer on the chrome: `webmux-dev/chrome-click $D <name>` clicks a
widget by name through `webmux-dev/realpointer` (names from `wmctl
chrome-bounds`: `header.*`, `pill.<name>`, `pill.<name>.x`,
`card.<name>.<button label>`, `card.<name>.menu|restart|delete`, `form.*`,
`page.*`; popover items included); `--drag NAME DX`, `--hover NAME`,
`--at X Y`. Hover lasts only while a `realpointer` process runs.

Connection rules worth knowing when testing: a live connection holds the
host+instance of its current connect cycle; editing its profile applies
from the next Connect/Reconnect (automatic retries keep what it holds), so
two connections never share a tunnel socket. A broken `config.json` is
moved to `config.json.broken-<time>` and reported (page banner, connection
log); it is never overwritten. A cleared or deleted password is recorded in
`keyring.json` (`cleared`) and never used again; its keyring item is
deleted whenever the keyring answers.

Also: a `config.json` that parses but has wrong types, duplicate or
missing ids is repaired in memory, reported (page banner, connection log,
`conns` → `config_problem`) and its original text kept as
`config.json.before-repair-<time>`; an id two profiles shared is re-issued
for both and its saved password cleared. Ports are blank or 1–65535 in
decimal, in the form and in the file. When a popover closes, focus goes
back to what had it (`conns` → `focus`); the menu's Edit items act on
that. A link chooser follows its host: closed while another host is in
front, raised again when it returns, dismissed with the host.

A real Secret Service for a run: `webmux-dev/keyring start $D` (GNOME
Keyring on the run's private bus, data in the run's HOME, login keyring
unlocked with "test"); `keyring lock $D` locks it (the unlock prompt then
fails: there is no prompter); `headless stop` ends it.

Fake-host sessions run `sh` with the host's shims first on PATH and an X
display that cannot exist: a login bash would rebuild PATH from this
machine's profile, and `xdg-open` in a session would then reach the real
desktop's browser.

Settings: the panels own `iface.settings` and the colour scheme. The
chrome creates the engine, calls `panels/settings.zig` `load()` before the
first window, and forwards the engine's `.settings` event to
`settings.external()`; the chrome's `wm-light` class follows
`AdwStyleManager:dark`. Every main window gets the panels' status toast
(`toast.adoptWindow`).

In a clone under `gtk/wt/<name>`, `headless --host` needs
`WEBMUX_HOST_BIN=<webmux>/host/dist/webmux-host-linux-x64` (its default
path assumes `gtk/ghostty`).

## Known gaps

- **CPU presentation fallback** (`memory` frames) is copied unchanged and
  never exercised: DMABUF import succeeded under every setup tried (GSK GL
  and GSK Cairo).
- **Pointer**: real pointer input goes through `realpointer` (selection,
  clicks, links, middle click, wheel, scrollbar, dividers, chrome).
  Cursor shape changes (`mouse_shape`) are wired but unobserved.
  Focus-follows-mouse untested.
- **IME**: pre-edit/commit verified with GTK's simple input method (dead
  keys and Ctrl+Shift+U Unicode entry, `GTK_IM_MODULE=gtk-im-context-simple`,
  `smoke-pane`); not with IBus/fcitx. With
  the default Wayland text-input module and no input-method server, dead
  keys are not composed in the headless session.
- **Clipboard ownership in tests**: Wayland lets a client take CLIPBOARD
  or PRIMARY only with a serial from real input newer than the current
  owner's. The control socket's synthesized keys and mouse carry none, so
  in headless tests do one `webmux-dev/realkeys $D -k Shift_L` (or
  `realkeys-xkb $D Shift_L`) first (and
  use a real Ctrl+Shift+C after `wl-copy` took the clipboard). Real users
  always have that serial.
- **Scrollback** uses `scrollback-limit-lines = 5600`: Ghostty trims by
  page, so with 5000 fewer than 5000 lines survived (T-03); 5600 keeps
  about 5500.
- **Single instance**: the app is always non-unique (`--new-window`-style
  IPC to a running instance does not exist; `performIpc` returns false).
- No context menu, no URL-hover preview, no desktop notifications, no
  search (none exist in the Electron client).
- OSC 8 links get the pointer cursor on hover but no underline (Ghostty
  underlines OSC 8 links only with Ctrl held); plain URLs underline.
- Ctrl+Shift+W is the workspace's `pane.close-pane`; the window has no
  close action of its own (and no accelerator closes it, W-07).
- Remote panes: `session_error`, `paste_result`, `open_url`, clipboard
  sync and `setShown` are exercised by `webmux-dev/smoke --pane`.
- File browser: WebP and AVIF images do not preview (no gdk-pixbuf loader
  in the environment); remote images in markdown are not fetched; preview
  text is not selectable; the preview date is always en-US style.
- File browser: an image inside a paragraph of text is shown on a line of
  its own (labels cannot hold widgets); inline code has square corners
  (a Pango background cannot be rounded).
- Clipboard, headless only: once the app has owned the clipboard (a copy),
  GTK does not see a later outside change (`wl-copy`) while the window
  keeps focus; a focus change refreshes it. Order tests accordingly.
- Synthesized keys (`key`, `text`) reach a terminal only when a terminal
  (or nothing) has the window's focus; a focused file browser, text field
  or dialog gets nothing from them (use `realkeys` / `realkeys-xkb`).
- Ghostty's gresource and translations are still linked/installed, unused.
- Desktop file, icon, packaging: not done (installed `share/` files are
  Ghostty's).

## Zig 0.17 and environment notes

- `@import("file.zig")` is resolved eagerly: imported files are parsed even
  in comptime-dead branches (see the build section).
- `std.json.ObjectMap` and `std.ArrayHashMap` are unmanaged: `.empty`, no
  `.init(alloc)`. `std.json.parseFromSliceLeaky` / `Stringify.valueAlloc`
  are as before.
- Format strings: `{t}` prints an enum/error tag; literal braces must be
  `{{`/`}}` (a stray `{x}` is a compile error deep inside `Io.Writer`).
- `std.mem.printSentinel(&buf, fmt, args, 0)`; `std.Io.Reader.fixed(bytes)`;
  `std.c.getenv`; `std.process.Environ.Map`; `std.Thread.spawn` still works.
- Ghostty renamed `scrollback-limit` → `scrollback-limit-bytes` (and added
  `-lines`); `copy-on-select` takes `none|primary|clipboard|…`;
  `working-directory = home` means the passwd home, not `$HOME`.
- The zig-gobject bindings are in `zig-pkg/gobject-*/src/<lib>/<lib>.zig`;
  grep for the C function name (`extern fn gtk_widget_add_controller`) to
  find the Zig name and signature.
- `in-session`/`headless` fetch tools with
  `nix build --inputs-from . nixpkgs#<pkg>` (pinned to `flake.lock`).
- No `make`, `gcc`, `strings`, `file` on the host PATH; use nix.
