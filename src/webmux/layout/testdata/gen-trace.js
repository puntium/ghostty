// Differential trace generator (usage: node gen-trace.js electron/ui/app.js <seed> <steps>): runs the real layout code from
// electron/ui/app.js (functions extracted by name from the source text,
// DOM/network stubbed out) on random command sequences, and prints one
// JSON line per step: the command and the resulting layout.
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function extract(name) {
  const re = new RegExp(`^(async )?function ${name}\\(|^const ${name} = `, 'm');
  const m = re.exec(src);
  if (!m) throw new Error('missing ' + name);
  let i = src.indexOf(') {', m.index) + 2;
  if (src.startsWith('const', m.index)) { const end = src.indexOf(';\n', m.index); return src.slice(m.index, end + 2); }
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') { depth--; if (depth === 0) return src.slice(m.index, j + 1); }
  }
}
const names = ['newColumn', 'allIds', 'columnIndexOf', 'columnOf', 'insertIntoColumn', 'removeFromColumn',
  'focusAfterRemoval', 'removeSessionFromLayout', 'setFocus', 'openInNewColumn', 'newSession', 'newSessionBelow',
  'newFilesSession', 'focusColumn', 'focusInColumn', 'commitMove', 'moveColumn', 'expel', 'movePane',
  'consumeOrExpel', 'closeFocused', 'toggleFull', 'removeTile', 'sanitizeColumns'];
const code = names.map(extract).join('\n');
const prelude = `
let columns = [];
let focusedId = null;
const tiles = new Map();
let nextId = 0;
const layoutEl = { querySelectorAll: () => [] };
const paneEl = () => null;
const revealFocused = () => {};
const saveLayout = () => {};
const reducedMotion = () => true;
const isFilesId = (id) => typeof id === 'string' && id.startsWith('files-');
const fetch = () => Promise.resolve();
const API = '';
const discardWidgetState = () => {};
const mk = (id) => ({ root: { remove() {} }, focus() {}, term: null });
const makeTile = (id) => { const t = mk(id); tiles.set(id, t); return t; };
const makeFilesTile = (id) => mk(id);
const createServerSession = async () => 's' + (nextId++);
const createFilesWidget = () => 'files-' + (nextId++);
function render() { if (!allIds().includes(focusedId)) focusedId = columns[0]?.active ?? null; }
`;
const api = `return { get nextId() { return nextId; }, get columns() { return columns; }, get focusedId() { return focusedId; },
  newSession, newSessionBelow, newFilesSession, closeFocused, removeTile, toggleFull, focusColumn, focusInColumn,
  moveColumn, movePane, consumeOrExpel, setFocus, allIds };`;
const L = new Function(prelude + code + api)();
// mulberry32
let seed = Number(process.argv[3] || 1);
const rand = () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
const pick = (a) => a[Math.floor(rand() * a.length)];
// The layout in testing.zig's spec syntax: `|` between columns, `,` between
// panes, `!` full column, `id:weight`, `^` active, `*` focused.
const state = () => L.columns.map((c) => (c.full === true ? '!' : '') + c.panes.map((id, i) =>
  `${id}:${c.sizes[i]}${c.active === id ? '^' : ''}${L.focusedId === id ? '*' : ''}`).join(',')).join('|');
(async () => {
  const steps = Number(process.argv[4] || 400);
  console.log(JSON.stringify({ cmd: 'reset', after: '' })); // a run starts from an empty layout
  for (let k = 0; k < steps; k++) {
    const r = rand();
    let step;
    if (r < 0.12) { step = { cmd: 'new-terminal', id: 's' + L.nextId }; await L.newSession(); }
    else if (r < 0.24) { step = { cmd: 'new-terminal-below', id: 's' + L.nextId }; await L.newSessionBelow(); }
    else if (r < 0.30) { step = { cmd: 'new-files', id: 'files-' + L.nextId }; L.newFilesSession(); }
    else if (r < 0.37) { step = { cmd: 'close-pane' }; L.closeFocused(); await new Promise((res) => setImmediate(res)); }
    else if (r < 0.41 && L.allIds().length) { const id = pick(L.allIds()); step = { cmd: 'remove', id }; await L.removeTile(id, false); }
    else if (r < 0.47 && L.allIds().length) { const id = pick(L.allIds()); step = { cmd: 'click', id }; L.setFocus(id); }
    else if (r < 0.53 && L.columns.length) {
      // What a divider drag leaves behind: some weight changed (the drag
      // itself is DOM code; its arithmetic is unit-tested separately).
      const col = Math.floor(rand() * L.columns.length);
      const row = Math.floor(rand() * L.columns[col].panes.length);
      const w = Math.round((0.1 + rand() * 3) * 1000) / 1000;
      step = { cmd: 'set-weight', col, row, w };
      L.columns[col].sizes[row] = w;
    }
    else {
      const cmd = pick(['toggle-full', 'focus-left', 'focus-right', 'focus-up', 'focus-down', 'move-column-left',
        'move-column-right', 'move-pane-up', 'move-pane-down', 'consume-expel-left', 'consume-expel-right']);
      step = { cmd };
      ({ 'toggle-full': () => L.toggleFull(), 'focus-left': () => L.focusColumn(-1), 'focus-right': () => L.focusColumn(1),
        'focus-up': () => L.focusInColumn(-1), 'focus-down': () => L.focusInColumn(1), 'move-column-left': () => L.moveColumn(-1),
        'move-column-right': () => L.moveColumn(1), 'move-pane-up': () => L.movePane(-1), 'move-pane-down': () => L.movePane(1),
        'consume-expel-left': () => L.consumeOrExpel(-1), 'consume-expel-right': () => L.consumeOrExpel(1) })[cmd]();
    }
    console.log(JSON.stringify({ ...step, after: state() }));
  }
})();
