/* A virtual keyboard with a real XKB layout (default "us"), for headless
 * tests: unlike wtype, which uploads a keymap of its own with arbitrary
 * keycodes, keys arrive with the layout's real evdev keycodes and levels,
 * as from a physical keyboard. Built and run by webmux-dev/realkeys-xkb.
 *
 *   xkb-keys [LAYOUT [VARIANT [GROUP]]]    e.g. us | de | "us,ru" "" 1
 *
 * stdin, one command per line:
 *   key SPEC        SPEC = [mod+]...KEY, mods: shift ctrl alt super.
 *                   KEY is a keysym name. One that a US keyboard has
 *                   unshifted (a-z, 0-9, bracketleft, Return, Left, F5,
 *                   Shift_L, ...) names that PHYSICAL key, whatever the
 *                   layout ("ctrl+shift+h" under ru is Ctrl+Shift+Р, "ctrl+1"
 *                   under fr is Ctrl+&). Any other keysym ("exclam",
 *                   "eacute", "ISO_Left_Tab") is looked up in the layout's
 *                   GROUP, and a shifted level adds shift by itself.
 *   type TEXT       each character as its keysym in the layout (text, not
 *                   positions)
 *   mods [MOD...]   hold modifiers until the next "mods" (none: release)
 *   sleep MS
 * Exits non-zero naming the first keysym the layout cannot produce. */
#define _GNU_SOURCE
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;
static struct zwp_virtual_keyboard_v1 *kb;
static struct xkb_keymap *keymap, *us_keymap;
static uint32_t group;
static struct wl_display *display;
static uint32_t now_ms = 1;

static void reg_global(void *d, struct wl_registry *r, uint32_t name, const char *iface, uint32_t ver) {
  (void)d; (void)ver;
  if (!strcmp(iface, wl_seat_interface.name)) seat = wl_registry_bind(r, name, &wl_seat_interface, 1);
  else if (!strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name))
    manager = wl_registry_bind(r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) { (void)d; (void)r; (void)n; }
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

static uint32_t mod_bit(const char *name) {
  xkb_mod_index_t i = xkb_keymap_mod_get_index(keymap, name);
  return i == XKB_MOD_INVALID ? 0 : (1u << i);
}

/* Find the keycode and level-1 need for a keysym in `grp` of `km`, levels
 * 0..max_level. */
static int find_in(struct xkb_keymap *km, uint32_t grp, int max_level, xkb_keysym_t sym, xkb_keycode_t *out, int *shifted) {
  xkb_keycode_t min = xkb_keymap_min_keycode(km), max = xkb_keymap_max_keycode(km);
  for (int level = 0; level <= max_level; level++) {
    for (xkb_keycode_t kc = min; kc <= max; kc++) {
      const xkb_keysym_t *syms;
      int n = xkb_keymap_key_get_syms_by_level(km, kc, grp, level, &syms);
      for (int j = 0; j < n; j++) {
        if (syms[j] == sym) { *out = kc; *shifted = level == 1; return 1; }
      }
    }
  }
  return 0;
}

/* A keysym in the active layout and group. */
static int find_key(xkb_keysym_t sym, xkb_keycode_t *out, int *shifted) {
  return find_in(keymap, group, 1, sym, out, shifted);
}

/* A key named by its US position (level 0 of a US keyboard), else the
 * keysym in the layout. */
static int find_named(xkb_keysym_t sym, xkb_keycode_t *out, int *shifted) {
  if (find_in(us_keymap, 0, 0, sym, out, shifted)) return 1;
  return find_key(sym, out, shifted);
}

/* Modifiers are real key presses (Control_L, Shift_L, Alt_L, Super_L)
 * followed by the modifier state they produce, as from a physical
 * keyboard: input methods and GTK see the modifier keys go down and up
 * (GTK's Ctrl+Shift+U entry, for one, needs the releases). */
static const char *const mod_names[] = { XKB_MOD_NAME_CTRL, XKB_MOD_NAME_SHIFT, XKB_MOD_NAME_ALT, XKB_MOD_NAME_LOGO };
static const xkb_keysym_t mod_syms[] = { XKB_KEY_Control_L, XKB_KEY_Shift_L, XKB_KEY_Alt_L, XKB_KEY_Super_L };
static uint32_t held;

static int find_key(xkb_keysym_t sym, xkb_keycode_t *out, int *shifted);

static void set_mods(uint32_t want) {
  for (int pass = 0; pass < 2; pass++) {
    /* Releases first (in reverse), then presses. */
    for (int k = 0; k < 4; k++) {
      int i = pass == 0 ? 3 - k : k;
      uint32_t bit = mod_bit(mod_names[i]);
      if (!bit) continue;
      int down = (want & bit) != 0, is = (held & bit) != 0;
      if (down == is || (pass == 0) == down) continue;
      xkb_keycode_t kc; int sh;
      if (!find_key(mod_syms[i], &kc, &sh)) continue;
      held = down ? held | bit : held & ~bit;
      if (down) zwp_virtual_keyboard_v1_key(kb, now_ms++, kc - 8, WL_KEYBOARD_KEY_STATE_PRESSED);
      zwp_virtual_keyboard_v1_modifiers(kb, held, 0, 0, group);
      if (!down) zwp_virtual_keyboard_v1_key(kb, now_ms++, kc - 8, WL_KEYBOARD_KEY_STATE_RELEASED);
    }
  }
}

static void press(xkb_keycode_t kc, uint32_t mods) {
  uint32_t before = held;
  set_mods(held | mods);
  zwp_virtual_keyboard_v1_key(kb, now_ms++, kc - 8, WL_KEYBOARD_KEY_STATE_PRESSED);
  zwp_virtual_keyboard_v1_key(kb, now_ms++, kc - 8, WL_KEYBOARD_KEY_STATE_RELEASED);
  set_mods(before);
  wl_display_roundtrip(display);
}

static int do_key(char *spec, int by_position) {
  uint32_t mods = 0;
  char *p = spec, *plus;
  while ((plus = strchr(p, '+')) && plus != p && plus[1]) {
    *plus = 0;
    if (!strcasecmp(p, "shift")) mods |= mod_bit(XKB_MOD_NAME_SHIFT);
    else if (!strcasecmp(p, "ctrl") || !strcasecmp(p, "control")) mods |= mod_bit(XKB_MOD_NAME_CTRL);
    else if (!strcasecmp(p, "alt")) mods |= mod_bit(XKB_MOD_NAME_ALT);
    else if (!strcasecmp(p, "super")) mods |= mod_bit(XKB_MOD_NAME_LOGO);
    else { fprintf(stderr, "virtual-keyboard: bad modifier %s\n", p); return 0; }
    p = plus + 1;
  }
  xkb_keysym_t sym = xkb_keysym_from_name(p, XKB_KEYSYM_NO_FLAGS);
  if (sym == XKB_KEY_NoSymbol) sym = xkb_keysym_from_name(p, XKB_KEYSYM_CASE_INSENSITIVE);
  if (sym == XKB_KEY_NoSymbol && strlen(p) == 1) sym = xkb_utf32_to_keysym((unsigned char)p[0]);
  xkb_keycode_t kc; int shifted;
  if (sym == XKB_KEY_NoSymbol || !(by_position ? find_named(sym, &kc, &shifted) : find_key(sym, &kc, &shifted))) {
    fprintf(stderr, "virtual-keyboard: no key for %s\n", p);
    return 0;
  }
  if (shifted) mods |= mod_bit(XKB_MOD_NAME_SHIFT);
  press(kc, mods);
  return 1;
}

int main(int argc, char **argv) {
  const char *layout = argc > 1 && argv[1][0] ? argv[1] : "us";
  const char *variant = argc > 2 && argv[2][0] ? argv[2] : NULL;
  group = argc > 3 ? (uint32_t)atoi(argv[3]) : 0;
  display = wl_display_connect(NULL);
  if (!display) { fprintf(stderr, "virtual-keyboard: no display\n"); return 1; }
  struct wl_registry *reg = wl_display_get_registry(display);
  wl_registry_add_listener(reg, &reg_listener, NULL);
  wl_display_roundtrip(display);
  if (!seat || !manager) { fprintf(stderr, "virtual-keyboard: no seat or manager\n"); return 1; }
  kb = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);

  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_rule_names names = { .rules = "evdev", .model = "pc105", .layout = layout, .variant = variant };
  keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!keymap) { fprintf(stderr, "virtual-keyboard: cannot compile layout %s\n", layout); return 1; }
  struct xkb_rule_names us = { .rules = "evdev", .model = "pc105", .layout = "us" };
  us_keymap = xkb_keymap_new_from_names(ctx, &us, XKB_KEYMAP_COMPILE_NO_FLAGS);
  if (!us_keymap) { fprintf(stderr, "virtual-keyboard: cannot compile the us layout\n"); return 1; }
  if (group >= xkb_keymap_num_layouts(keymap)) { fprintf(stderr, "virtual-keyboard: no group %u in %s\n", group, layout); return 1; }
  char *str = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(str) + 1;
  int fd = memfd_create("keymap", MFD_CLOEXEC);
  if (fd < 0 || ftruncate(fd, size) < 0) return 1;
  char *map = mmap(NULL, size, PROT_WRITE, MAP_SHARED, fd, 0);
  memcpy(map, str, size);
  munmap(map, size);
  zwp_virtual_keyboard_v1_keymap(kb, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
  wl_display_roundtrip(display);
  /* Let the compositor hand the new keymap to the focused client. */
  /* The locked group (a second layout of "us,ru"). */
  zwp_virtual_keyboard_v1_modifiers(kb, 0, 0, 0, group);
  wl_display_roundtrip(display);
  usleep(100 * 1000);

  char line[4096];
  int rc = 0;
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = 0;
    if (!strncmp(line, "key ", 4)) {
      /* For harnesses: when this key was sent (CLOCK_MONOTONIC ns). */
      struct timespec ts;
      clock_gettime(CLOCK_MONOTONIC, &ts);
      printf("t %lld %s\n", (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec, line + 4);
      fflush(stdout);
      if (!do_key(line + 4, 1)) rc = 2;
    } else if (!strncmp(line, "mods", 4)) {
      /* Hold modifiers (e.g. "mods shift") until the next "mods" line;
       * for modifier+click with realpointer. */
      uint32_t m = 0;
      char *p = line + 4;
      while (*p) {
        while (*p == ' ' || *p == '+') p++;
        if (!*p) break;
        char *e = p; while (*e && *e != ' ' && *e != '+') e++;
        char save = *e; *e = 0;
        if (!strcasecmp(p, "shift")) m |= mod_bit(XKB_MOD_NAME_SHIFT);
        else if (!strcasecmp(p, "ctrl")) m |= mod_bit(XKB_MOD_NAME_CTRL);
        else if (!strcasecmp(p, "alt")) m |= mod_bit(XKB_MOD_NAME_ALT);
        else if (!strcasecmp(p, "super")) m |= mod_bit(XKB_MOD_NAME_LOGO);
        *e = save; p = e;
      }
      set_mods(m);
      wl_display_roundtrip(display);
    } else if (!strncmp(line, "sleep ", 6)) {
      wl_display_flush(display);
      usleep((useconds_t)atoi(line + 6) * 1000);
    } else if (!strncmp(line, "type ", 5)) {
      for (const char *c = line + 5; *c; c++) {
        char one[2] = { *c, 0 };
        if (*c == ' ') { char sp[] = "space"; do_key(sp, 1); continue; }
        if (!do_key(one, 0)) rc = 2;
      }
    } else if (line[0]) {
      fprintf(stderr, "virtual-keyboard: unknown command %s\n", line);
      rc = 2;
    }
  }
  wl_display_roundtrip(display);
  return rc;
}
