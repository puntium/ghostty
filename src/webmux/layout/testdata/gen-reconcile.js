// Expected results for persist reconciliation tests (test_persist.zig),
// computed by the real app.js loadLayout / sanitizeColumns / columnsFromTree
// / attachExisting (extracted from the source by name; network and DOM
// stubbed). Usage: node gen-reconcile.js electron/ui/app.js
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function extract(name) {
  const re = new RegExp(`^(async )?function ${name}\\(|^const ${name} = `, 'm');
  const m = re.exec(src);
  if (!m) throw new Error('missing ' + name);
  if (src.startsWith('const', m.index)) { const end = src.indexOf(';\n', m.index); return src.slice(m.index, end + 2); }
  const i = src.indexOf(') {', m.index) + 2;
  let depth = 0;
  for (let j = i; j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}') { depth--; if (depth === 0) return src.slice(m.index, j + 1); }
  }
}
const names = ['newColumn', 'allIds', 'columnIndexOf', 'columnOf', 'removeFromColumn', 'columnsFromTree',
  'sanitizeColumns', 'loadLayout', 'attachExisting'];
const code = names.map(extract).join('\n');
const make = (stored, sessions) => new Function('stored', 'sessions', `
let columns = [];
let focusedId = null;
const tiles = new Map();
const localStorage = { getItem: () => stored, setItem: () => {} };
const fetch = async () => ({ json: async () => sessions });
const API = '';
const location = { origin: '' };
const logInfo = () => {}, logError = () => {};
const isFilesId = (id) => typeof id === 'string' && id.startsWith('files-');
const makeTile = (id) => { const t = { setTitle() {}, focus() {} }; tiles.set(id, t); return t; };
const makeFilesTile = () => ({ focus() {} });
const pruneWidgetStates = () => {};
const saveLayout = () => {};
const render = () => { if (!allIds().includes(focusedId)) focusedId = columns[0]?.active ?? null; };
const newSession = async () => {};
${code}
return attachExisting().then(() => ({ columns, focusedId }));
`)(stored, sessions);
const spec = ({ columns, focusedId }) => columns.map((c) => (c.full === true ? '!' : '') + c.panes.map((id, i) =>
  `${id}:${c.sizes[i]}${c.active === id ? '^' : ''}${focusedId === id ? '*' : ''}`).join(',')).join('|');
const cases = JSON.parse(fs.readFileSync(0, 'utf8'));
(async () => {
  for (const [stored, live] of cases) {
    const out = await make(stored, live.map((id) => ({ id, title: '' })));
    console.log(JSON.stringify([stored, live, spec(out)]));
  }
})();
