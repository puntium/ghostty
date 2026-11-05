// Expected bytes per key combination, computed by xterm.js 5.5's own
// evaluateKeyboardEvent (electron/node_modules/@xterm/xterm/src/common/
// input/Keyboard.ts, loaded as is with Node's type stripping) plus the
// send decisions of browser/Terminal.ts _keyDown/_keyPress and the
// Electron client's custom key handler (app.js: Ctrl+V / Ctrl+Alt+V).
//
//   node --experimental-strip-types expected.mjs KEYBOARD_TS > expected.json
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const src = readFileSync(process.argv[2], 'utf8')
  .replace(/^import .*$/mg, '')
  .replace(/^/, "const C0 = { NUL: '\\x00', HT: '\\t', CR: '\\r', ESC: '\\x1b', DEL: '\\x7f', FS: '\\x1c', GS: '\\x1d', US: '\\x1f' };\n" +
    "const KeyboardResultType = { SEND_KEY: 0, SELECT_ALL: 1, PAGE_UP: 2, PAGE_DOWN: 3 };\n");
const dir = mkdtempSync(join(tmpdir(), 'xtk-'));
const file = join(dir, 'Keyboard.ts');
writeFileSync(file, src);
const { evaluateKeyboardEvent } = await import(file);
const KeyboardResultType = { SEND_KEY: 0, SELECT_ALL: 1, PAGE_UP: 2, PAGE_DOWN: 3 }; // common/Types.ts

// [xkb keysym for realkeys-xkb, DOM keyCode, key unshifted, key shifted]
const keys = [];
for (let i = 0; i < 26; i++) {
  const c = String.fromCharCode(97 + i);
  keys.push([c, 65 + i, c, c.toUpperCase()]);
}
const shiftedDigits = ')!@#$%^&*(';
for (let i = 0; i < 10; i++) keys.push([String(i), 48 + i, String(i), shiftedDigits[i]]);
for (const [sym, code, a, b] of [
  ['semicolon', 186, ';', ':'], ['equal', 187, '=', '+'], ['comma', 188, ',', '<'],
  ['minus', 189, '-', '_'], ['period', 190, '.', '>'], ['slash', 191, '/', '?'],
  ['grave', 192, '`', '~'], ['bracketleft', 219, '[', '{'], ['backslash', 220, '\\', '|'],
  ['bracketright', 221, ']', '}'], ['apostrophe', 222, "'", '"'],
]) keys.push([sym, code, a, b]);
keys.push(['space', 32, ' ', ' ']);
for (const [sym, code, name] of [
  ['BackSpace', 8, 'Backspace'], ['Tab', 9, 'Tab'], ['Return', 13, 'Enter'], ['Escape', 27, 'Escape'],
  ['Prior', 33, 'PageUp'], ['Next', 34, 'PageDown'], ['End', 35, 'End'], ['Home', 36, 'Home'],
  ['Left', 37, 'ArrowLeft'], ['Up', 38, 'ArrowUp'], ['Right', 39, 'ArrowRight'], ['Down', 40, 'ArrowDown'],
  ['Insert', 45, 'Insert'], ['Delete', 46, 'Delete'],
  ['KP_Enter', 13, 'Enter'],
]) keys.push([sym, code, name, name]);
for (let i = 1; i <= 12; i++) keys.push(['F' + i, 111 + i, 'F' + i, 'F' + i]);
for (const [sym, code, ch] of [['KP_Add', 107, '+'], ['KP_Subtract', 109, '-'], ['KP_Multiply', 106, '*'], ['KP_Divide', 111, '/']]) {
  keys.push([sym, code, ch, ch]);
}

function xtermSends(ev, appCursor) {
  // Electron's custom key handler (app.js:865-879): Ctrl+V and Ctrl+Alt+V.
  if (ev.key.toLowerCase() === 'v' && ev.ctrlKey && !ev.metaKey && !ev.shiftKey) {
    return { bytes: '\x16', note: 'app.js Ctrl+V (empty clipboard) / Ctrl+Alt+V' };
  }
  const r = evaluateKeyboardEvent(ev, appCursor, false, false);
  if (r.type === KeyboardResultType.PAGE_UP || r.type === KeyboardResultType.PAGE_DOWN) {
    return { bytes: '', scroll: r.type === KeyboardResultType.PAGE_UP ? 'up' : 'down' };
  }
  if (r.key) return { bytes: r.key };
  // keypress: a character unless Ctrl/Alt/Meta.
  if (!ev.ctrlKey && !ev.altKey && !ev.metaKey && ev.key.length === 1) return { bytes: ev.key };
  return { bytes: '' };
}

const out = [];
for (const appCursor of [false, true]) {
  for (const [sym, keyCode, k0, k1] of keys) {
    if (appCursor && ![35, 36, 37, 38, 39, 40].includes(keyCode)) continue;
    for (let m = 0; m < 16; m++) {
      const shift = !!(m & 1), alt = !!(m & 2), ctrl = !!(m & 4), meta = !!(m & 8);
      const ev = {
        keyCode, key: shift ? k1 : k0, code: '', shiftKey: shift, altKey: alt, ctrlKey: ctrl, metaKey: meta,
        type: 'keydown',
      };
      const mods = [shift && 'shift', ctrl && 'ctrl', alt && 'alt', meta && 'super'].filter(Boolean);
      const spec = [...mods, sym].join('+');
      const r = xtermSends(ev, appCursor);
      out.push({ spec, appCursor, ...r });
    }
  }
}
process.stdout.write(JSON.stringify(out, null, 1));
