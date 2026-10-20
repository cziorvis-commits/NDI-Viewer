'use strict';

/* ---------- helpers ---------- */
const $ = (s, el = document) => el.querySelector(s);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const HOST = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ndi)
  || new URLSearchParams(location.search).get('host') === 'popover';
const dec = new TextDecoder();
const Q_NAMES = ['thumb', 'medium', 'full', 'native'];
const GAP = 8;
const MAX_SIZE = 4;

function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k === 'text') e.textContent = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (k === 'icon') e.append(icon(v));
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) e.append(kid.nodeType ? kid : document.createTextNode(kid));
  return e;
}

const ICON_PATHS = {
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>',
  chevron: '<path d="m6 9 6 6 6-6"/>',
  camera: '<path d="M4 8h3l1.6-2.2h6.8L17 8h3v11H4z"/><circle cx="12" cy="13.2" r="3.4"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>',
  layout: '<rect x="3.5" y="4" width="10" height="9" rx="1.5"/><rect x="15.5" y="4" width="5" height="4" rx="1.2"/><rect x="15.5" y="10" width="5" height="10" rx="1.2"/><rect x="3.5" y="15" width="10" height="5" rx="1.2"/>',
  users: '<circle cx="9" cy="8.5" r="3.2"/><path d="M3.5 19.5c.6-3.2 2.8-5 5.5-5s4.9 1.8 5.5 5"/><path d="M15.5 5.6a3 3 0 0 1 0 5.8M17.5 14.8c1.6.6 2.7 2.2 3 4.7"/>',
  phone: '<rect x="7" y="3" width="10" height="18" rx="2.2"/><path d="M11 17.5h2"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 3v2.2M12 18.8V21M3 12h2.2M18.8 12H21M5.6 5.6l1.6 1.6M16.8 16.8l1.6 1.6M5.6 18.4l1.6-1.6M16.8 7.2l1.6-1.6"/>',
  back: '<path d="M15 5 8 12l7 7"/>',
  detach: '<rect x="3.5" y="7.5" width="12" height="12" rx="1.6"/><path d="M10 4h10v10M20 4l-8 8"/>',
  expand: '<path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/>',
  speaker: '<path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z"/><path d="M15.5 9a4.2 4.2 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11"/>',
  mute: '<path d="M4 9.5h3.5L12 6v12l-4.5-3.5H4z"/><path d="m16 10 4 4M20 10l-4 4"/>',
  stats: '<path d="M5 20V11M10 20V5M15 20v-7M20 20V8"/>',
  pause: '<rect x="6.5" y="5" width="4" height="14" rx="1"/><rect x="13.5" y="5" width="4" height="14" rx="1"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  minus: '<path d="M5 12h14"/>',
  resize: '<path d="M20 10v10H10M20 20 9 9"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  grid: '<rect x="4" y="4" width="7" height="7" rx="1"/><rect x="13" y="4" width="7" height="7" rx="1"/><rect x="4" y="13" width="7" height="7" rx="1"/><rect x="13" y="13" width="7" height="7" rx="1"/>',
  stage: '<path d="M3 20h18M5 20V9l7-5 7 5v11"/><rect x="9" y="13" width="6" height="7"/>',
  live: '<circle cx="12" cy="12" r="2.5"/><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4M5 5a10 10 0 0 0 0 14M19 5a10 10 0 0 1 0 14"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.3-4.9L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4"/>',
  trash: '<path d="M5 7h14M10 7V4.5h4V7M7 7l1 13h8l1-13"/>',
  pencil: '<path d="M4 20h4L19 9l-4-4L4 16z"/>',
  save: '<path d="M5 4h11l3 3v13H5z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="1.8"/><path d="M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16H8"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  open: '<path d="M14 4h6v6M20 4l-9 9M18 14v6H4V6h6"/>',
  rec: '<circle cx="12" cy="12" r="7.5"/><circle cx="12" cy="12" r="3.5" fill="currentColor"/>',
  stop: '<rect x="7" y="7" width="10" height="10" rx="1.5" fill="currentColor"/>',
  radar: '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><path d="M12 12 18 6"/>',
};
function icon(name) {
  const i = document.createElement('i');
  i.dataset.icon = name;
  i.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${ICON_PATHS[name] || ''}</svg>`;
  return i;
}
function hydrateIcons(root = document) {
  root.querySelectorAll('i[data-icon]').forEach(i => { if (!i.firstChild) i.replaceWith(Object.assign(icon(i.dataset.icon), { className: i.className })); });
}
function setIcon(btn, name) { const old = btn.querySelector('i[data-icon]'); if (old) old.replaceWith(icon(name)); }

function fmtDate(ms) {
  const d = new Date(ms);
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: d.getFullYear() === new Date().getFullYear() ? undefined : 'numeric' })
    + ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}
function fmtRate(bytesPerSec) {
  const bits = bytesPerSec * 8;
  return bits > 1e6 ? (bits / 1e6).toFixed(1) + ' Mb/s' : Math.round(bits / 1e3) + ' kb/s';
}
function deviceName() {
  const ua = navigator.userAgent;
  if (HOST) return 'Menu bar';
  const dev = /iPhone/.test(ua) ? 'iPhone' : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? 'iPad'
    : /Android/.test(ua) ? 'Android' : /Macintosh/.test(ua) ? 'Mac' : /Windows/.test(ua) ? 'Windows' : 'Device';
  const br = /CriOS|Chrome/.test(ua) && !/Edg/.test(ua) ? 'Chrome' : /Edg/.test(ua) ? 'Edge' : /Firefox|FxiOS/.test(ua) ? 'Firefox' : /Safari/.test(ua) ? 'Safari' : 'Browser';
  return `${dev} · ${br}`;
}

/* ---------- state ---------- */
const S = {
  ws: null, connected: false, id: null, local: false, urls: [], port: 0,
  sources: new Map(),        // name -> {name, host, label, ip, url}
  profiles: [],
  scope: 'live',
  search: '',
  edit: false,
  full: null,                // source name in viewer
  audioOn: false, statsOn: true,
  held: null, capped: false,
  hostVisible: !HOST,        // popover starts hidden until the app says otherwise
  settings: {}, viewers: [], receivers: 0,
  cols: 1, cellW: 200,
  visible: new Set(),
  lastSubsKey: '',
  bytes: 0, frames: 0, rate: { bytes: 0, fps: 0 },
  sheet: null,
  scan: null,                // last {state, done, total, found} from the host
  recordings: new Map(),     // source name -> start time (ms), recordings running on the host
  mics: [],                  // [{id, name}] microphones on the host
};
const tiles = new Map();     // name -> {el, canvas, snap, lastFrame, ...}

/* ---------- layout storage (per device) ---------- */
const LS_KEY = 'ndiviewer.layouts.v1';
let store = loadStore();
function loadStore() {
  try { const v = JSON.parse(localStorage.getItem(LS_KEY)); if (v && v.scopes) return v; } catch (e) {}
  return { scopes: {}, lastScope: 'live' };
}
function saveStore() { try { localStorage.setItem(LS_KEY, JSON.stringify(store)); } catch (e) {} }
function defaultBase() { return window.innerWidth < 560 ? 160 : 240; }
function scopeLayouts(scope = S.scope) {
  if (!store.scopes[scope]) store.scopes[scope] = { current: 'Default', layouts: {} };
  const sc = store.scopes[scope];
  if (!sc.layouts[sc.current]) sc.layouts[sc.current] = { order: [], hidden: [], sizes: {}, base: defaultBase() };
  return sc;
}
function layout() { const sc = scopeLayouts(); return sc.layouts[sc.current]; }

/* ---------- connection ---------- */
function send(obj) { if (S.ws && S.ws.readyState === 1) S.ws.send(JSON.stringify(obj)); }

let reconnectTimer = null;
function connect() {
  clearTimeout(reconnectTimer);
  if (S.ws && S.ws.readyState <= 1) return;
  const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  ws.binaryType = 'arraybuffer';
  S.ws = ws;
  ws.onopen = () => {
    S.connected = true;
    S.lastSubsKey = '';
    send({ t: 'hello', kind: HOST ? 'popover' : 'browser', device: deviceName() });
    send({ t: 'viewProfile', id: S.scope === 'live' ? null : S.scope });
    const vis = isVisible();
    if (!vis) send({ t: 'visibility', visible: false });
    syncSubs(true);
    renderStatus();
  };
  ws.onmessage = e => typeof e.data === 'string' ? onJSON(JSON.parse(e.data)) : onBinary(e.data);
  ws.onclose = () => {
    if (S.ws !== ws) return;
    S.connected = false;
    renderStatus();
    if (isVisible() || HOST) reconnectTimer = setTimeout(connect, 1500);
  };
}
function isVisible() { return HOST ? S.hostVisible : !document.hidden; }

function onJSON(m) {
  switch (m.t) {
    case 'welcome':
      S.id = m.id; S.local = !!m.local; S.urls = m.urls || []; S.port = m.port;
      if (m.settings) S.settings = m.settings;
      if (m.mics) S.mics = m.mics;
      document.body.classList.toggle('is-local', S.local);
      S.held = null; hideHold();
      if (!m.ndiReady) toast('NDI runtime failed to initialize on the host');
      break;
    case 'sources':
      S.sources = new Map(m.list.map(s => [s.name, s]));
      S.everDiscovered = S.everDiscovered || m.list.length > 0;
      render();
      if (S.sheet === 'scan') renderScanStatus();
      break;
    case 'profiles':
      S.profiles = m.list;
      if (S.scope !== 'live' && !S.profiles.some(p => p.id === S.scope)) setScope('live');
      else render();
      break;
    case 'profileSaved':
      setScope(m.id);
      toast('Stage saved — grabbing snapshots…');
      break;
    case 'held': showHold(m.reason); break;
    case 'resumed': S.held = null; hideHold(); syncSubs(true); break;
    case 'capped':
      S.capped = true;
      updateBanner();
      toast(`Full-quality limit reached (${m.cap} remote). Showing preview quality.`);
      break;
    case 'uncapped':
      S.capped = false;
      updateBanner();
      toast('Full quality available again');
      break;
    case 'stats': if (m.s === S.full) renderStats(m); break;
    case 'levels': if (m.s === S.full) renderMeters(m.p); break;
    case 'viewers':
      S.viewers = m.list; S.receivers = m.receivers;
      renderViewersBadge();
      if (S.sheet === 'viewers') renderViewersSheet();
      renderStatus();
      break;
    case 'settings': S.settings = m.values; break;
    case 'toast': toast(m.text); break;
    case 'recordings':
      S.recordings = new Map(m.list.map(r => [r.s, r.since]));
      renderRecording();
      break;
    case 'mics':
      S.mics = m.list;
      if (S.refreshMics) S.refreshMics();
      break;
    case 'scan':
      S.scan = m;
      if (S.sheet === 'scan') renderScanStatus();
      else if (m.state === 'done' && m.total) toast(`Scan finished: ${m.found.length} NDI host${m.found.length === 1 ? '' : 's'} found`);
      break;
  }
}

/* ---------- frames ---------- */
function onBinary(buf) {
  const dv = new DataView(buf);
  const type = dv.getUint8(0);
  if (type === 1) {
    const q = Q_NAMES[dv.getUint8(1)];
    const n = dv.getUint16(2);
    const name = dec.decode(new Uint8Array(buf, 4, n));
    const blob = new Blob([new Uint8Array(buf, 4 + n)], { type: 'image/jpeg' });
    S.bytes += buf.byteLength;
    drawFrame(name, q, blob);
  } else if (type === 2) {
    const sr = dv.getUint32(1);
    const ch = dv.getUint8(5);
    const n = dv.getUint16(6);
    const name = dec.decode(new Uint8Array(buf, 8, n));
    S.bytes += buf.byteLength;
    if (name === S.full && S.audioOn) Audio.push(sr, ch, new Int16Array(buf.slice(8 + n)));
  }
}

const canBitmap = typeof createImageBitmap === 'function';
async function decodeBlob(blob) {
  if (canBitmap) return createImageBitmap(blob);
  return new Promise((res, rej) => {
    const img = new Image();
    const url = URL.createObjectURL(blob);
    img.onload = () => { URL.revokeObjectURL(url); res(img); };
    img.onerror = e => { URL.revokeObjectURL(url); rej(e); };
    img.src = url;
  });
}

async function drawFrame(name, q, blob) {
  try {
    const inViewer = S.full === name && (q === 'full' || q === 'medium');
    const t = tiles.get(name);
    const canvas = inViewer ? $('#vCanvas') : (t && (q === 'thumb' || q === 'medium') ? t.canvas : null);
    if (!canvas) return;
    const img = await decodeBlob(blob);
    const w = img.width, h = img.height;
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
    canvas.getContext('2d').drawImage(img, 0, 0);
    if (img.close) img.close();
    if (inViewer) {
      S.frames++;
      S.viewerLastFrame = performance.now();
      $('#vMsg').hidden = true;
    } else if (t) {
      t.lastFrame = performance.now();
      t.el.classList.add('live');
      t.el.classList.remove('show-snap', 'stale', 'waiting');
    }
  } catch (e) {
    /* decode errors are non-fatal */
  } finally {
    send({ t: 'ack', s: name, q });
  }
}

/* ---------- subscriptions ---------- */
let subsTimer = null;
function syncSubs(force = false) {
  clearTimeout(subsTimer);
  subsTimer = setTimeout(() => {
    let subs = [];
    let audio = null;
    if (!S.held && isVisible()) {
      if (S.full) {
        subs = [{ s: S.full, q: 'full' }];
        if (S.audioOn) audio = S.full;
      } else {
        const L = layout();
        for (const name of S.visible) {
          const item = S.sources.get(name);
          if (!item || !tiles.has(name)) continue;
          subs.push({ s: name, q: (L.sizes[name] || 1) >= 2 ? 'medium' : 'thumb' });
        }
      }
    }
    const key = JSON.stringify([subs, audio]);
    if (!force && key === S.lastSubsKey) return;
    S.lastSubsKey = key;
    send({ t: 'subscribe', subs, audio });
  }, force ? 0 : 120);
}

// Visible tiles are computed from geometry (IntersectionObserver doesn't run in background tabs).
let visTimer = null;
function recomputeVisible() {
  const wrap = $('#galleryWrap').getBoundingClientRect();
  const top = wrap.top - 80, bottom = wrap.bottom + 80;
  const next = new Set();
  for (const [name, t] of tiles) {
    const r = t.el.getBoundingClientRect();
    if (r.bottom >= top && r.top <= bottom && r.height > 0) next.add(name);
  }
  const changed = next.size !== S.visible.size || [...next].some(n => !S.visible.has(n));
  S.visible = next;
  if (changed) syncSubs();
}
function scheduleVisible() {
  if (visTimer) return;
  visTimer = setTimeout(() => { visTimer = null; recomputeVisible(); }, 100);
}
$('#galleryWrap').addEventListener('scroll', scheduleVisible, { passive: true });
window.addEventListener('resize', scheduleVisible);

/* ---------- scope (live vs saved stage) ---------- */
function currentProfile() { return S.scope === 'live' ? null : S.profiles.find(p => p.id === S.scope); }

function currentItems() {
  const p = currentProfile();
  if (!p) return [...S.sources.values()].map(s => ({ ...s, online: true }));
  return p.sources.map(ps => {
    const live = S.sources.get(ps.name);
    return { ...ps, ...(live || {}), snapshot: ps.snapshot, online: !!live };
  });
}

function setScope(scope) {
  S.scope = scope;
  store.lastScope = scope;
  saveStore();
  send({ t: 'viewProfile', id: scope === 'live' ? null : scope });
  closeViewer();
  render();
}

/* ---------- rendering ---------- */
function matches(item, q) {
  if (!q) return true;
  return [item.name, item.host, item.label, item.ip].some(v => v && v.toLowerCase().includes(q));
}

function orderedItems() {
  const L = layout();
  const items = currentItems();
  const byName = new Map(items.map(i => [i.name, i]));
  const ordered = [];
  for (const n of L.order) if (byName.has(n)) { ordered.push(byName.get(n)); byName.delete(n); }
  for (const i of byName.values()) ordered.push(i);
  const hidden = new Set(L.hidden);
  const q = S.search.trim().toLowerCase();
  return {
    visible: ordered.filter(i => !hidden.has(i.name) && matches(i, q)),
    removed: ordered.filter(i => hidden.has(i.name)),
    total: items.length,
  };
}

function render() {
  renderScope();
  renderGallery();
  renderStatus();
  if (S.full) renderViewerHeader();
}

function renderScope() {
  const p = currentProfile();
  const kind = $('#scopeKind');
  kind.textContent = p ? 'Stage' : 'Live';
  kind.classList.toggle('stage', !!p);
  $('#scopeName').textContent = p ? p.name : `All sources${S.sources.size ? ` (${S.sources.size})` : ''}`;
  $('#layoutNameLabel').textContent = `· ${scopeLayouts().current}`;
}

function makeTile(item) {
  const canvas = el('canvas');
  const snap = el('img', { class: 'snap', alt: '', draggable: 'false' });
  const nameText = el('span');
  const meta = el('div', { class: 'meta' });
  const state = el('div', { class: 'state' });
  const minus = el('button', { class: 'sz minus edit', title: 'Smaller', 'aria-label': 'Smaller', icon: 'minus' });
  const plus = el('button', { class: 'sz plus edit', title: 'Bigger', 'aria-label': 'Bigger', icon: 'plus' });
  const rm = el('button', { class: 'rm edit', title: 'Remove from layout', 'aria-label': 'Remove from layout', icon: 'close' });
  const grip = el('div', { class: 'grip edit', title: 'Drag to resize', icon: 'resize' });
  const tileEl = el('div', { class: 'tile waiting', tabindex: '0', role: 'button' },
    canvas, snap, state, el('div', { class: 'q', text: 'HQ' }),
    el('div', { class: 'label' }, el('div', { class: 'name' }, el('span', { class: 'dot' }), nameText), meta),
    minus, plus, rm, grip);
  tileEl.dataset.name = item.name;
  const t = { el: tileEl, canvas, snap, nameText, meta, state, minus, plus, lastFrame: 0 };
  minus.addEventListener('click', e => { e.stopPropagation(); setSize(item.name, (layout().sizes[item.name] || 1) - 1); });
  plus.addEventListener('click', e => { e.stopPropagation(); setSize(item.name, (layout().sizes[item.name] || 1) + 1); });
  rm.addEventListener('click', e => { e.stopPropagation(); removeTile(item.name); });
  tileEl.addEventListener('click', () => { if (!S.edit && !tileEl.classList.contains('offline')) openViewer(item.name); });
  tileEl.addEventListener('keydown', e => { if ((e.key === 'Enter' || e.key === ' ') && !S.edit) { e.preventDefault(); tileEl.click(); } });
  return t;
}

function updateTile(t, item) {
  t.nameText.textContent = item.label || item.name;
  t.meta.textContent = `${item.host || '—'} · ${item.ip || 'no IP'}`;
  t.el.title = item.name;
  t.el.classList.toggle('offline', !item.online);
  t.el.classList.toggle('rec', S.recordings.has(item.name));
  if (item.snapshot) {
    if (t.snap.getAttribute('src') !== item.snapshot) t.snap.src = item.snapshot;
    if (!item.online || !t.lastFrame) t.el.classList.add('show-snap');
  } else {
    t.snap.removeAttribute('src');
    t.el.classList.remove('show-snap');
  }
  if (!item.online) { t.state.textContent = 'OFFLINE'; t.el.classList.remove('live', 'stale', 'waiting'); }
  else if (!t.lastFrame) { t.state.textContent = 'CONNECTING'; t.el.classList.add('waiting'); }
  const size = clamp(layout().sizes[item.name] || 1, 1, Math.min(MAX_SIZE, S.cols));
  t.el.dataset.size = size;
  t.el.style.gridColumn = `span ${size}`;
  t.el.style.gridRow = `span ${size}`;
  t.minus.disabled = size <= 1;
  t.plus.disabled = size >= Math.min(MAX_SIZE, S.cols);
}

function renderGallery() {
  const gallery = $('#gallery');
  const { visible, removed, total } = orderedItems();
  const keep = new Set(visible.map(i => i.name));
  for (const [name, t] of tiles) {
    if (!keep.has(name)) { t.el.remove(); tiles.delete(name); S.visible.delete(name); }
  }
  let prev = null;
  for (const item of visible) {
    let t = tiles.get(item.name);
    if (!t) { t = makeTile(item); tiles.set(item.name, t); }
    updateTile(t, item);
    const want = prev ? prev.nextSibling : gallery.firstChild;
    if (t.el !== want) gallery.insertBefore(t.el, want);
    prev = t.el;
  }
  layoutGrid();
  renderEmpty(visible.length, total);
  renderTray(removed);
  recomputeVisible();
  syncSubs();
}

function renderEmpty(shown, total) {
  const empty = $('#empty');
  empty.innerHTML = '';
  if (shown > 0) { empty.hidden = true; return; }
  empty.hidden = false;
  const p = currentProfile();
  let title, text, spin = false;
  if (!S.connected) { title = 'Connecting to host…'; text = 'Make sure the NDI-Viewer app is running on the Mac.'; spin = true; }
  else if (S.search) { title = 'No matches'; text = `Nothing matches “${S.search}”.`; }
  else if (total > 0) { title = 'All tiles removed'; text = 'Turn on Edit layout to bring sources back.'; }
  else if (p) { title = 'This stage has no sources'; text = 'Use “Update from live” in the stage menu to capture the current sources.'; }
  else { title = 'Looking for NDI sources…'; text = 'Sources on this network appear here automatically. Add discovery IPs in Settings for other subnets.'; spin = true; }
  const scanBtn = !p && S.connected && S.local && !S.search && total === 0
    ? el('button', { class: 'btn sm', icon: 'radar', onclick: openScanSheet }, 'Scan network') : null;
  empty.append(el('div', {}, spin ? el('div', { class: 'spinner' }) : null, el('h3', { text: title }), el('p', { text }), scanBtn));
}

function renderTray(removed) {
  const tray = $('#tray');
  tray.innerHTML = '';
  tray.hidden = !S.edit || removed.length === 0;
  if (tray.hidden) return;
  tray.append(el('span', { class: 'tray-label', text: `Removed (${removed.length}):` }));
  for (const item of removed) {
    tray.append(el('button', { class: 'chip', title: `Restore ${item.name}`, onclick: () => restoreTile(item.name) },
      icon('plus'), item.label || item.name));
  }
}

function layoutGrid() {
  const gallery = $('#gallery');
  const L = layout();
  const W = gallery.clientWidth || $('#galleryWrap').clientWidth - 20;
  const base = L.base || defaultBase();
  const cols = Math.max(1, Math.floor((W + GAP) / (base + GAP)));
  const cellW = (W - GAP * (cols - 1)) / cols;
  const colsChanged = cols !== S.cols;
  S.cols = cols; S.cellW = cellW;
  gallery.style.gridTemplateColumns = `repeat(${cols}, minmax(0, 1fr))`;
  gallery.style.gridAutoRows = `${Math.round(cellW * 9 / 16)}px`;
  if (colsChanged) for (const [name, t] of tiles) {
    const size = clamp(L.sizes[name] || 1, 1, Math.min(MAX_SIZE, cols));
    t.el.dataset.size = size;
    t.el.style.gridColumn = `span ${size}`;
    t.el.style.gridRow = `span ${size}`;
    t.minus.disabled = size <= 1;
    t.plus.disabled = size >= Math.min(MAX_SIZE, cols);
  }
}
new ResizeObserver(() => { layoutGrid(); scheduleVisible(); }).observe($('#galleryWrap'));

function renderStatus() {
  const dot = $('#connDot');
  dot.className = 'dot ' + (S.connected ? 'ok' : 'bad');
  const n = S.sources.size;
  let text = S.connected ? `${n} source${n === 1 ? '' : 's'} online` : 'Disconnected — retrying…';
  const p = currentProfile();
  if (p && S.connected) {
    const online = p.sources.filter(s => S.sources.has(s.name)).length;
    text = `${online}/${p.sources.length} stage sources online · ${n} live`;
  }
  $('#statusText').textContent = text;
  let right = '';
  if (S.local) {
    const remote = S.viewers.filter(v => !v.local);
    const active = remote.filter(v => v.state === 'active').length;
    right = remote.length ? `${active} of ${remote.length} remote viewer${remote.length === 1 ? '' : 's'} active` : 'No remote viewers';
    if (S.receivers) right += ` · ${S.receivers} NDI receiver${S.receivers === 1 ? '' : 's'}`;
  }
  $('#statusRight').textContent = right;
}

/* ---------- stale detection ---------- */
setInterval(() => {
  const now = performance.now();
  for (const [name, t] of tiles) {
    if (!S.visible.has(name) || t.el.classList.contains('offline') || S.full || S.held) continue;
    if (t.lastFrame && now - t.lastFrame > 5000) {
      t.el.classList.add('stale'); t.el.classList.remove('live');
      t.state.textContent = 'NO VIDEO';
    }
  }
  if (S.full && S.viewerLastFrame && now - S.viewerLastFrame > 4000 && !S.held) {
    $('#vMsg').hidden = false; $('#vMsg').textContent = 'No video';
  }
}, 2000);

/* ---------- edit mode: drag, resize, remove ---------- */
function setEdit(on) {
  S.edit = on;
  document.body.classList.toggle('editing', on);
  $('#editBtn').classList.toggle('on', on);
  $('#editBar').hidden = !on;
  $('#zoom').value = layout().base || defaultBase();
  renderGallery();
}

function setSize(name, size) {
  const L = layout();
  size = clamp(size, 1, Math.min(MAX_SIZE, S.cols));
  if (size === 1) delete L.sizes[name]; else L.sizes[name] = size;
  saveStore();
  const t = tiles.get(name);
  const item = currentItems().find(i => i.name === name);
  if (t && item) updateTile(t, item);
  scheduleVisible();
  syncSubs();
}

function removeTile(name) {
  const L = layout();
  if (!L.hidden.includes(name)) L.hidden.push(name);
  saveStore();
  renderGallery();
}
function restoreTile(name) {
  const L = layout();
  L.hidden = L.hidden.filter(n => n !== name);
  saveStore();
  renderGallery();
}

function saveOrderFromDOM() {
  const L = layout();
  const domOrder = [...$('#gallery').children].map(e => e.dataset.name);
  const inDom = new Set(domOrder);
  L.order = domOrder.concat(L.order.filter(n => !inDom.has(n)));
  saveStore();
}

$('#gallery').addEventListener('pointerdown', e => {
  if (!S.edit || e.button > 0) return;
  const tile = e.target.closest('.tile');
  if (!tile || e.target.closest('button')) return;
  if (e.target.closest('.grip')) startResize(e, tile); else startDrag(e, tile);
});

function cloneForGhost(tile) {
  const ghost = el('div', { class: 'ghost' });
  const src = tile.querySelector('canvas');
  if (src && src.width > 1) {
    const c = el('canvas'); c.width = src.width; c.height = src.height;
    c.getContext('2d').drawImage(src, 0, 0);
    ghost.append(c);
  } else {
    const snap = tile.querySelector('.snap');
    if (snap && snap.src) ghost.append(el('img', { src: snap.src }));
  }
  const label = tile.querySelector('.label');
  if (label) { const l = label.cloneNode(true); l.style.position = 'absolute'; ghost.append(l); }
  return ghost;
}

function startDrag(e, tile) {
  e.preventDefault();
  const rect = tile.getBoundingClientRect();
  const offX = e.clientX - rect.left, offY = e.clientY - rect.top;
  const startX = e.clientX, startY = e.clientY;
  let ghost = null, lastOver = null, raf = 0, lastEv = e;
  const wrap = $('#galleryWrap');
  const begin = () => {
    ghost = cloneForGhost(tile);
    ghost.style.width = rect.width + 'px';
    ghost.style.height = rect.height + 'px';
    document.body.append(ghost);
    tile.classList.add('placeholder');
  };
  const frame = () => {
    raf = 0;
    const ev = lastEv;
    ghost.style.transform = `translate(${ev.clientX - offX}px, ${ev.clientY - offY}px)`;
    const wr = wrap.getBoundingClientRect();
    if (ev.clientY < wr.top + 40) wrap.scrollTop -= 12;
    else if (ev.clientY > wr.bottom - 40) wrap.scrollTop += 12;
    const under = document.elementFromPoint(ev.clientX, ev.clientY);
    const over = under && under.closest('.tile');
    if (over && over !== tile && over !== lastOver && over.parentNode === tile.parentNode) {
      const kids = [...tile.parentNode.children];
      const a = kids.indexOf(tile), b = kids.indexOf(over);
      tile.parentNode.insertBefore(tile, a < b ? over.nextSibling : over);
    }
    lastOver = over;
  };
  const move = ev => {
    lastEv = ev;
    if (!ghost) {
      if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < 5) return;
      begin();
    }
    if (!raf) raf = requestAnimationFrame(frame);
  };
  const end = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', end);
    window.removeEventListener('pointercancel', end);
    if (raf) cancelAnimationFrame(raf);
    if (ghost) { ghost.remove(); tile.classList.remove('placeholder'); saveOrderFromDOM(); }
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', end);
  window.addEventListener('pointercancel', end);
}

function startResize(e, tile) {
  e.preventDefault();
  e.stopPropagation();
  const name = tile.dataset.name;
  const rect = tile.getBoundingClientRect();
  const move = ev => {
    const bx = (ev.clientX - rect.left + GAP / 2) / (S.cellW + GAP);
    const by = (ev.clientY - rect.top + GAP / 2) / (S.cellW * 9 / 16 + GAP);
    const size = clamp(Math.round(Math.max(bx, by)), 1, Math.min(MAX_SIZE, S.cols));
    if (size !== (layout().sizes[name] || 1)) setSize(name, size);
  };
  const end = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', end);
    window.removeEventListener('pointercancel', end);
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', end);
  window.addEventListener('pointercancel', end);
}

$('#zoom').addEventListener('input', e => {
  layout().base = +e.target.value;
  saveStore();
  layoutGrid();
  renderGallery();
});

/* ---------- viewer ---------- */
function openViewer(name) {
  S.full = name;
  S.capped = false;
  S.viewerLastFrame = 0;
  S.frames = 0; S.bytes = 0;
  const c = $('#vCanvas');
  c.width = 1; c.height = 1;
  $('#vMsg').hidden = false; $('#vMsg').textContent = 'Connecting…';
  $('#vStats').innerHTML = '';
  $('#vMeters').innerHTML = '';
  meterState = [];
  $('#viewer').hidden = false;
  renderViewerHeader();
  updateBanner();
  syncSubs(true);
  pokeViewerIdle();
}

function closeViewer() {
  if (!S.full) return;
  S.full = null;
  S.capped = false;
  $('#viewer').hidden = true;
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  syncSubs(true);
}

function renderViewerHeader() {
  const item = S.sources.get(S.full) || currentItems().find(i => i.name === S.full) || { name: S.full };
  $('#vName').textContent = item.label || item.name;
  $('#vMeta').textContent = `${item.host || '—'} · ${item.ip || 'no IP'}`;
  setIcon($('#vAudio'), S.audioOn ? 'speaker' : 'mute');
  $('#vAudio').classList.toggle('on', S.audioOn);
  $('#vStatsBtn').classList.toggle('on', S.statsOn);
  $('#vStats').hidden = !S.statsOn;
  renderRecording();
}

function fmtElapsed(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  const p = n => String(n).padStart(2, '0');
  return `${s >= 3600 ? Math.floor(s / 3600) + ':' : ''}${p(Math.floor(s / 60) % 60)}:${p(s % 60)}`;
}

function renderRecording() {
  for (const [name, t] of tiles) t.el.classList.toggle('rec', S.recordings.has(name));
  const since = S.full ? S.recordings.get(S.full) : undefined;
  const btn = $('#vRec');
  btn.classList.toggle('rec', since !== undefined);
  setIcon(btn, since !== undefined ? 'stop' : 'rec');
  btn.title = since !== undefined ? 'Stop recording' : 'Record on this Mac';
  const pill = $('#vRecPill');
  pill.hidden = since === undefined;
  if (since !== undefined) pill.textContent = `REC ${fmtElapsed(Date.now() - since)}`;
}
setInterval(() => { if (S.full && S.recordings.has(S.full)) renderRecording(); }, 1000);

function updateBanner() {
  const b = $('#vBanner');
  b.hidden = !S.capped;
  b.textContent = 'Preview quality — full-quality viewer limit reached';
}

function renderStats(m) {
  if (!S.statsOn) return;
  const fps = m.fps ? `${m.fps.toFixed(2)}${m.prog ? 'p' : 'i'}` : '—';
  const dropPct = m.frames ? (m.dropped / m.frames) * 100 : 0;
  const lines = [
    `<span class="k">Video </span>${m.w}×${m.h} · ${fps} · ${m.mfps.toFixed(1)} fps`,
    `<span class="k">Drops </span><span class="${dropPct > 1 ? 'bad' : dropPct > 0 ? 'warn' : ''}">${m.dropped}</span> / ${m.frames}`,
    `<span class="k">Conn  </span><span class="${m.conns ? '' : 'bad'}">${m.conns ? m.conns + ' connection' + (m.conns > 1 ? 's' : '') : 'not connected'}</span>`,
  ];
  if (m.ach) lines.push(`<span class="k">Audio </span>${m.ach} ch · ${(m.asr / 1000).toFixed(1)} kHz`);
  lines.push(`<span class="k">Here  </span>${fmtRate(S.rate.bytes)} · ${S.rate.fps.toFixed(0)} fps${S.capped ? ' · preview' : ''}`);
  $('#vStats').innerHTML = lines.join('\n');
}

setInterval(() => {
  S.rate = { bytes: S.bytes / 2, fps: S.frames / 2 };
  S.bytes = 0; S.frames = 0;
}, 2000);

let meterState = [];
function renderMeters(peaks) {
  const box = $('#vMeters');
  const n = Math.min(peaks.length, 16);
  if (box.children.length !== n) {
    box.innerHTML = '';
    meterState = [];
    for (let i = 0; i < n; i++) { box.append(el('div', { class: 'm' }, el('b'), el('s'))); meterState.push({ hold: 0, t: 0 }); }
  }
  const now = performance.now();
  for (let i = 0; i < n; i++) {
    const db = 20 * Math.log10(Math.max(peaks[i], 1e-6));
    const frac = clamp((db + 60) / 60, 0, 1);
    const m = box.children[i];
    const bar = m.firstChild, hold = m.lastChild;
    bar.style.height = (frac * 100).toFixed(1) + '%';
    bar.className = db > -3 ? 'r' : db > -12 ? 'y' : '';
    const st = meterState[i];
    if (frac >= st.hold || now - st.t > 1200) { st.hold = frac; st.t = now; }
    hold.style.bottom = `calc(${(st.hold * 100).toFixed(1)}% - 2px)`;
  }
}

const Audio = {
  ctx: null, next: 0,
  enable() {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return false;
    if (!this.ctx) this.ctx = new AC({ latencyHint: 'interactive' });
    this.ctx.resume();
    this.next = 0;
    return true;
  },
  disable() { if (this.ctx) this.ctx.suspend(); },
  push(sr, ch, pcm) {
    const ctx = this.ctx;
    if (!ctx || ctx.state !== 'running' || ch < 1) return;
    const frames = Math.floor(pcm.length / ch);
    if (!frames) return;
    const buf = ctx.createBuffer(2, frames, sr);
    for (let c = 0; c < 2; c++) {
      const out = buf.getChannelData(c);
      const src = Math.min(c, ch - 1);
      for (let i = 0; i < frames; i++) out[i] = pcm[i * ch + src] / 32768;
    }
    const node = ctx.createBufferSource();
    node.buffer = buf;
    node.connect(ctx.destination);
    const now = ctx.currentTime;
    if (this.next < now + 0.03 || this.next > now + 0.5) this.next = now + 0.1;
    node.start(this.next);
    this.next += buf.duration;
  },
};

let viewerIdleTimer = null;
function pokeViewerIdle() {
  $('#viewer').classList.remove('idle');
  clearTimeout(viewerIdleTimer);
  viewerIdleTimer = setTimeout(() => $('#viewer').classList.add('idle'), 3000);
}
$('#viewer').addEventListener('pointermove', pokeViewerIdle);
$('#viewer').addEventListener('pointerdown', pokeViewerIdle);

$('#vBack').addEventListener('click', closeViewer);
$('#vAudio').addEventListener('click', () => {
  S.audioOn = !S.audioOn;
  if (S.audioOn) { if (!Audio.enable()) { S.audioOn = false; toast('Audio is not supported in this browser'); } }
  else Audio.disable();
  renderViewerHeader();
  syncSubs(true);
});
$('#vRec').addEventListener('click', () => {
  if (!S.full) return;
  const on = !S.recordings.has(S.full);
  send({ t: 'record', s: S.full, on });
  if (on) {
    const v = S.settings;
    const mic = !v.recordMic ? 'no audio' : v.recordMic === 'ndi' ? 'NDI audio' : v.recordMic === 'default' ? 'default mic'
      : (S.mics.find(m => m.id === v.recordMic) || { name: 'mic' }).name;
    toast(`Recording ${v.recordHeight}p · ${(v.recordBitrateKbps / 1000).toFixed(1)} Mb/s · ${mic}`);
  }
});
$('#vStatsBtn').addEventListener('click', () => { S.statsOn = !S.statsOn; renderViewerHeader(); });
$('#vDetach').addEventListener('click', () => {
  const name = S.full;
  if (!name) return;
  const item = S.sources.get(name) || {};
  closeViewer();
  try { window.webkit.messageHandlers.ndi.postMessage({ action: 'detach', source: name, ip: item.ip || '' }); } catch (e) {}
});
$('#vFs').addEventListener('click', () => {
  const v = $('#viewer');
  if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
  else if (v.requestFullscreen) v.requestFullscreen().catch(() => {});
  else if (v.webkitEnterFullscreen) v.webkitEnterFullscreen();
  else toast('Fullscreen isn’t available — add to Home Screen for a full-screen view');
});

/* ---------- hold ---------- */
function showHold(reason) {
  S.held = reason;
  closeMenu();
  const mins = reason === 'idle' ? (S.full ? S.settings.fullIdleMinutes : S.settings.galleryIdleMinutes) : null;
  $('#holdTitle').textContent = reason === 'host' ? 'Paused by host' : 'On hold';
  $('#holdText').textContent = reason === 'host'
    ? 'The host paused this viewer to save bandwidth.'
    : `Paused after ${mins ? mins + ' minutes' : 'a while'} without activity to save bandwidth.`;
  $('#hold').hidden = false;
  if (S.audioOn) Audio.disable();
}
function hideHold() {
  $('#hold').hidden = true;
  if (S.audioOn) Audio.enable();
}
$('#hold').addEventListener('click', () => { send({ t: 'resume' }); });

/* ---------- activity / visibility / heartbeat ---------- */
let lastActivitySent = 0;
function activity() {
  const now = Date.now();
  if (now - lastActivitySent > 15000) { lastActivitySent = now; send({ t: 'activity' }); }
}
['pointerdown', 'keydown', 'wheel', 'touchstart'].forEach(ev => window.addEventListener(ev, activity, { passive: true }));
$('#galleryWrap').addEventListener('scroll', activity, { passive: true });

setInterval(() => send({ t: 'ping' }), 10000);

document.addEventListener('visibilitychange', () => {
  if (HOST) return;
  if (document.hidden) {
    send({ t: 'visibility', visible: false });
  } else if (!S.ws || S.ws.readyState > 1) {
    connect();
  } else {
    send({ t: 'visibility', visible: true });
    syncSubs(true);
  }
});

window.NDIHost = {
  setVisible(v) {
    S.hostVisible = !!v;
    if (!v) { closeMenu(); if (S.audioOn) Audio.disable(); }
    else if (S.audioOn) Audio.enable();
    if (!S.ws || S.ws.readyState > 1) { if (v) connect(); return; }
    send({ t: 'visibility', visible: !!v });
    syncSubs(true);
    if (v) { activity(); }
  },
};

/* ---------- menus ---------- */
let menuAnchor = null;
function showMenu(anchor, items) {
  const menu = $('#menu');
  if (menuAnchor === anchor && !menu.hidden) { closeMenu(); return; }
  menu.innerHTML = '';
  for (const it of items) {
    if (it === '-') { menu.append(el('hr')); continue; }
    if (it.header) { menu.append(el('div', { class: 'mh', text: it.header })); continue; }
    const b = el('button', { class: it.danger ? 'danger' : '', role: 'menuitem' },
      it.icon ? icon(it.icon) : null,
      el('span', { class: 'mi-text' }, el('b', { text: it.label }), it.sub ? el('small', { text: it.sub }) : null),
      it.checked ? Object.assign(icon('check'), { className: 'check' }) : null);
    b.addEventListener('click', () => { closeMenu(); it.action && it.action(); });
    menu.append(b);
  }
  menu.hidden = false;
  menuAnchor = anchor;
  const r = anchor.getBoundingClientRect();
  const mw = menu.offsetWidth, mh = menu.offsetHeight;
  menu.style.left = clamp(r.left, 8, window.innerWidth - mw - 8) + 'px';
  menu.style.top = (r.bottom + mh + 8 > window.innerHeight ? Math.max(8, r.top - mh - 4) : r.bottom + 4) + 'px';
  const first = menu.querySelector('button');
  if (first) first.focus({ preventScroll: true });
}
function closeMenu() { $('#menu').hidden = true; menuAnchor = null; }
document.addEventListener('pointerdown', e => {
  if (!$('#menu').hidden && !e.target.closest('#menu') && e.target.closest('button') !== menuAnchor) closeMenu();
});

$('#scopeBtn').addEventListener('click', e => {
  const p = currentProfile();
  const items = [
    { icon: 'live', label: 'Live — all sources', sub: `${S.sources.size} online now`, checked: !p, action: () => setScope('live') },
  ];
  if (S.profiles.length) {
    items.push('-', { header: 'Saved stages' });
    for (const pr of S.profiles) {
      const online = pr.sources.filter(s => S.sources.has(s.name)).length;
      items.push({ icon: 'stage', label: pr.name, sub: `${online}/${pr.sources.length} online · ${fmtDate(pr.updatedAt)}`, checked: p && p.id === pr.id, action: () => setScope(pr.id) });
    }
  }
  items.push('-', { icon: 'camera', label: 'Save current sources as stage…', action: saveStage });
  if (p) {
    items.push(
      { icon: 'refresh', label: 'Update this stage from live', sub: 'Replace its sources and snapshots', action: () => send({ t: 'refreshProfile', id: p.id }) },
      { icon: 'pencil', label: 'Rename stage…', action: async () => {
        const name = await promptDialog({ title: 'Rename stage', value: p.name, ok: 'Rename' });
        if (name) send({ t: 'renameProfile', id: p.id, name });
      } },
      { icon: 'trash', label: 'Delete stage…', danger: true, action: async () => {
        if (await confirmDialog({ title: `Delete “${p.name}”?`, text: 'The saved sources and snapshots are removed for everyone. Layouts saved on this device stay until you clear them.', ok: 'Delete', danger: true }))
          send({ t: 'deleteProfile', id: p.id });
      } });
  }
  showMenu(e.currentTarget, items);
});

async function saveStage() {
  if (!S.sources.size) { toast('No live sources to save yet'); return; }
  const d = new Date();
  const name = await promptDialog({
    title: 'Save stage snapshot',
    text: `Saves the ${S.sources.size} live source${S.sources.size === 1 ? '' : 's'} with name, host, IP and a still frame, so you can check this stage quickly next time.`,
    value: `Stage ${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}`,
    ok: 'Save stage',
  });
  if (name) send({ t: 'saveProfile', name });
}
$('#saveStageBtn').addEventListener('click', saveStage);
$('#browserBtn').addEventListener('click', () => {
  try { window.webkit.messageHandlers.ndi.postMessage({ action: 'openBrowser' }); } catch (e) { window.open(location.origin + '/', '_blank'); }
});
$('#editBtn').addEventListener('click', () => setEdit(!S.edit));
$('#editDone').addEventListener('click', () => setEdit(false));

$('#layoutBtn').addEventListener('click', e => {
  const sc = scopeLayouts();
  const names = Object.keys(sc.layouts);
  const items = [{ header: `Layouts on this device · ${currentProfile() ? 'this stage' : 'live'}` }];
  for (const n of names) items.push({ icon: 'layout', label: n, checked: n === sc.current, action: () => { sc.current = n; saveStore(); renderScope(); layoutGrid(); renderGallery(); } });
  items.push('-',
    { icon: 'save', label: 'Save as new layout…', action: async () => {
      const name = await promptDialog({ title: 'Save layout as', value: uniqueName(sc, sc.current === 'Default' ? 'My layout' : sc.current), ok: 'Save' });
      if (!name) return;
      sc.layouts[name] = JSON.parse(JSON.stringify(layout()));
      sc.current = name; saveStore(); renderScope(); toast(`Saved layout “${name}”`);
    } },
    { icon: 'pencil', label: 'Rename layout…', action: async () => {
      const name = await promptDialog({ title: 'Rename layout', value: sc.current, ok: 'Rename' });
      if (!name || name === sc.current) return;
      if (sc.layouts[name]) { toast('A layout with that name exists'); return; }
      sc.layouts[name] = sc.layouts[sc.current]; delete sc.layouts[sc.current]; sc.current = name; saveStore(); renderScope();
    } },
    { icon: 'refresh', label: 'Reset this layout', sub: 'Default order, sizes, nothing removed', action: async () => {
      if (!await confirmDialog({ title: `Reset “${sc.current}”?`, text: 'Order, sizes and removed tiles go back to default.', ok: 'Reset' })) return;
      sc.layouts[sc.current] = { order: [], hidden: [], sizes: {}, base: defaultBase() }; saveStore(); $('#zoom').value = defaultBase(); renderGallery();
    } });
  if (names.length > 1) items.push({ icon: 'trash', label: 'Delete this layout', danger: true, action: async () => {
    if (!await confirmDialog({ title: `Delete layout “${sc.current}”?`, ok: 'Delete', danger: true })) return;
    delete sc.layouts[sc.current]; sc.current = Object.keys(sc.layouts)[0]; saveStore(); renderScope(); renderGallery();
  } });
  showMenu(e.currentTarget, items);
});
function uniqueName(sc, base) { let n = base, i = 2; while (sc.layouts[n]) n = `${base} ${i++}`; return n; }

/* ---------- dialogs & sheets ---------- */
function openSheet(id, title, body, foot) {
  const sheet = $('#sheet');
  sheet.innerHTML = '';
  const close = el('button', { class: 'ib', title: 'Close', 'aria-label': 'Close', icon: 'close', onclick: closeSheet });
  sheet.append(el('div', { class: 'sheet-head' }, el('h3', { text: title }), close), el('div', { class: 'sheet-body' }, body));
  if (foot) sheet.append(el('div', { class: 'sheet-foot' }, foot));
  sheet.hidden = false;
  $('#scrim').hidden = false;
  S.sheet = id;
  closeMenu();
}
function closeSheet() {
  $('#sheet').hidden = true; $('#scrim').hidden = true;
  const cb = S.sheetResolve; S.sheetResolve = null; S.sheet = null; S.refreshMics = null;
  if (cb) cb(null);
}
$('#scrim').addEventListener('click', closeSheet);

function promptDialog({ title, text, value = '', ok = 'OK' }) {
  return new Promise(resolve => {
    const input = el('input', { class: 'input', value, maxlength: '80' });
    const okBtn = el('button', { class: 'btn primary', text: ok });
    const submit = () => { const v = input.value.trim(); S.sheetResolve = null; closeSheet(); resolve(v || null); };
    okBtn.addEventListener('click', submit);
    input.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
    openSheet('prompt', title, el('div', {}, text ? el('p', { class: 'muted', text, style: 'margin:0 0 12px' }) : null, input),
      [el('button', { class: 'btn', text: 'Cancel', onclick: closeSheet }), okBtn]);
    S.sheetResolve = resolve;
    setTimeout(() => { input.focus(); input.select(); }, 30);
  });
}
function confirmDialog({ title, text, ok = 'OK', danger = false }) {
  return new Promise(resolve => {
    const okBtn = el('button', { class: `btn ${danger ? 'danger' : 'primary'}`, text: ok });
    okBtn.addEventListener('click', () => { S.sheetResolve = null; closeSheet(); resolve(true); });
    openSheet('confirm', title, text ? el('p', { class: 'muted', text, style: 'margin:0' }) : el('div'),
      [el('button', { class: 'btn', text: 'Cancel', onclick: closeSheet }), okBtn]);
    S.sheetResolve = v => resolve(!!v);
    setTimeout(() => okBtn.focus(), 30);
  });
}

function renderViewersBadge() {
  const remote = S.viewers.filter(v => !v.local && v.state === 'active').length;
  const b = $('#viewersBadge');
  b.hidden = remote === 0;
  b.textContent = remote;
}

function renderViewersSheet() {
  const holdable = S.viewers.filter(v => v.kind !== 'popover');
  const body = el('div');
  const holdAll = el('button', { class: 'btn sm', text: 'Hold all', disabled: !holdable.some(v => v.state === 'active'),
    onclick: () => send({ t: 'hold', id: 'all' }) });
  body.append(el('div', { style: 'display:flex;align-items:center;gap:8px;margin-bottom:10px' },
    el('span', { class: 'muted', style: 'flex:1', text: 'Browser viewers (phones and Mac browser windows) go on hold automatically when idle or hidden. Tap a held screen to resume.' }), holdAll));
  const list = el('div', { class: 'vlist' });
  for (const v of S.viewers) {
    const stateClass = v.state === 'active' ? 'active' : v.state.startsWith('held') ? 'held' : 'hidden';
    const stateLabel = v.state === 'active' ? 'Active' : v.state === 'held-idle' ? 'Idle hold' : v.state === 'held-host' ? 'Held' : 'Hidden';
    const right = v.kind === 'popover' ? el('span', { class: 'pill local', text: 'Menu bar' })
      : el('button', { class: 'btn sm', text: 'Hold', disabled: v.state !== 'active', onclick: () => send({ t: 'hold', id: v.id }) });
    list.append(el('div', { class: 'vrow' },
      el('span', { class: `pill ${stateClass}`, text: stateLabel }),
      el('div', { class: 'who' }, el('b', { text: v.local && v.kind !== 'popover' ? `${v.device} · this Mac` : v.device }), el('span', { text: `${v.ip}${v.kbps ? ' · ' + (v.kbps > 1000 ? (v.kbps / 1000).toFixed(1) + ' Mb/s' : v.kbps + ' kb/s') : ''}` }),
        el('div', { class: 'what', text: v.watching })),
      right));
  }
  body.append(list);
  if (S.sheet === 'viewers') { const b = $('#sheet .sheet-body'); b.innerHTML = ''; b.append(body); }
  else openSheet('viewers', `Viewers (${S.viewers.length})`, body);
}
$('#viewersBtn').addEventListener('click', renderViewersSheet);

$('#phoneBtn').addEventListener('click', () => {
  const url = S.urls[0];
  const body = el('div');
  if (!url) {
    body.append(el('p', { class: 'muted', text: 'This Mac has no network address right now. Connect to the stage network first.' }));
  } else {
    const copy = el('button', { class: 'btn sm', icon: 'copy', onclick: () => copyText(url) }, 'Copy link');
    const open = el('button', { class: 'btn sm', icon: 'open', onclick: () => openURL(url) }, 'Open');
    body.append(el('div', { class: 'phone' },
      el('img', { src: `/qr.png?t=${Date.now()}`, alt: 'QR code for the viewer link' }),
      el('div', {},
        el('p', { style: 'margin:0 0 8px', text: 'Scan with a phone on the same network:' }),
        el('div', { class: 'url', text: url }),
        el('div', { style: 'display:flex;gap:6px' }, copy, open),
        S.urls.length > 1 ? el('p', { class: 'muted', style: 'margin:10px 0 0;font-size:12px', text: 'Other addresses: ' + S.urls.slice(1).join(', ') }) : null)));
  }
  openSheet('phone', 'Open on phone', body);
});

function copyText(text) {
  if (HOST) { try { window.webkit.messageHandlers.ndi.postMessage({ action: 'copy', text }); toast('Link copied'); return; } catch (e) {} }
  if (navigator.clipboard) navigator.clipboard.writeText(text).then(() => toast('Link copied'), () => toast(text));
  else toast(text);
}
function openURL(url) {
  if (HOST) { try { window.webkit.messageHandlers.ndi.postMessage({ action: 'openURL', url }); return; } catch (e) {} }
  window.open(url, '_blank');
}

$('#settingsBtn').addEventListener('click', () => {
  const v = { ...S.settings };
  const num = (key, label, opts = {}) => {
    const input = el('input', { class: 'input', type: 'number', value: v[key], min: opts.min, max: opts.max, step: opts.step || 1 });
    input.addEventListener('change', () => { v[key] = +input.value; });
    return el('label', { class: 'field' }, el('span', { text: label }), input, opts.hint ? el('small', { text: opts.hint }) : null);
  };
  const range = (key, label, min, max, step, fmt) => {
    const out = el('output', { text: fmt(v[key]) });
    const input = el('input', { type: 'range', min, max, step, value: v[key] });
    input.addEventListener('input', () => { v[key] = +input.value; out.textContent = fmt(v[key]); });
    return el('label', { class: 'field' }, el('span', { text: label }), el('div', { class: 'range-row' }, input, out));
  };
  const widthSel = el('select', { class: 'input' }, ...[960, 1280, 1920, 3840].map(w => el('option', { value: w, text: `${w} px`, selected: v.fullMaxWidth === w })));
  widthSel.addEventListener('change', () => { v.fullMaxWidth = +widthSel.value; });
  const ips = el('textarea', { class: 'input', placeholder: '192.168.10.20, 10.0.5.0' });
  ips.value = v.extraIPs || '';
  ips.addEventListener('change', () => { v.extraIPs = ips.value; });
  const RES = [[480, '480p SD'], [720, '720p HD'], [1080, '1080p FHD'], [1440, '1440p QHD'], [2160, '2160p 4K']];
  const resSel = el('select', { class: 'input' }, ...RES.map(([h, label]) => el('option', { value: h, text: label, selected: v.recordHeight === h })));
  if (!RES.some(([h]) => h === v.recordHeight)) resSel.append(el('option', { value: v.recordHeight, text: `${v.recordHeight}p`, selected: true }));
  resSel.addEventListener('change', () => { v.recordHeight = +resSel.value; });
  const micSel = el('select', { class: 'input' });
  const fillMics = () => {
    micSel.replaceChildren(
      el('option', { value: '', text: 'No audio', selected: !v.recordMic }),
      el('option', { value: 'ndi', text: 'NDI source audio', selected: v.recordMic === 'ndi' }),
      el('option', { value: 'default', text: 'System default microphone', selected: v.recordMic === 'default' }),
      ...S.mics.map(m => el('option', { value: m.id, text: m.name, selected: v.recordMic === m.id })));
    if (v.recordMic && v.recordMic !== 'default' && v.recordMic !== 'ndi' && !S.mics.some(m => m.id === v.recordMic)) {
      micSel.append(el('option', { value: v.recordMic, text: 'Saved microphone (not connected)', selected: true }));
    }
  };
  fillMics();
  S.refreshMics = fillMics;
  send({ t: 'listMics' });
  micSel.addEventListener('change', () => { v.recordMic = micSel.value; });
  const sizeSel = el('select', { class: 'input' }, ...['small', 'medium', 'large'].map(s => el('option', { value: s, text: s[0].toUpperCase() + s.slice(1), selected: v.popoverSize === s })));
  sizeSel.addEventListener('change', () => { v.popoverSize = sizeSel.value; });

  const body = el('div', {},
    el('div', { class: 'section-title', text: 'Remote viewers' }),
    el('div', { class: 'row2' },
      num('galleryIdleMinutes', 'Gallery idle hold (min)', { min: 0.5, max: 240, step: 0.5 }),
      num('fullIdleMinutes', 'Full view idle hold (min)', { min: 0.5, max: 240, step: 0.5 })),
    num('remoteFullCap', 'Max remote full-quality streams', { min: 0, max: 50, hint: '0 = unlimited. Beyond the limit, phones get preview quality.' }),
    el('div', { class: 'section-title', text: 'Quality' }),
    el('div', { class: 'row2' },
      range('thumbFPS', 'Thumbnail frame rate', 1, 15, 1, x => `${x} fps`),
      range('mediumFPS', 'Enlarged tile frame rate', 1, 30, 1, x => `${x} fps`)),
    el('div', { class: 'row2' },
      range('fullFPS', 'Full view frame rate (web)', 5, 60, 1, x => `${x} fps`),
      range('jpegQuality', 'JPEG quality', 0.3, 0.95, 0.05, x => `${Math.round(x * 100)}%`)),
    el('label', { class: 'field' }, el('span', { text: 'Full view max width' }), widthSel),
    el('div', { class: 'section-title', text: 'Recording' }),
    el('div', { class: 'row2' },
      el('label', { class: 'field' }, el('span', { text: 'Resolution' }), resSel),
      num('recordBitrateKbps', 'Video bitrate (kb/s)', { min: 500, max: 100000, step: 500 })),
    el('label', { class: 'field' }, el('span', { text: 'Audio source' }), micSel,
      el('small', { text: 'H.264 MP4 saved to Movies/NDI-Viewer on this Mac. NDI source audio records the first two channels. Sources smaller than the resolution are not upscaled.' })),
    el('div', { class: 'section-title', text: 'Discovery' }),
    el('label', { class: 'field' }, el('span', { text: 'Extra discovery IPs' }), ips,
      el('small', { text: 'For sources on other subnets. Saved stages add their own source IPs automatically while open.' })),
    el('button', { class: 'btn sm', icon: 'radar', onclick: openScanSheet }, 'Scan network…'),
    el('div', { class: 'section-title', text: 'App' }),
    el('div', { class: 'row2' },
      el('label', { class: 'field' }, el('span', { text: 'Popover size' }), sizeSel),
      num('port', 'Web port', { min: 1024, max: 65000, hint: `Currently ${S.port}. Takes effect on relaunch.` })));
  const save = el('button', { class: 'btn primary', text: 'Save', onclick: () => {
    if (ips.value !== v.extraIPs) v.extraIPs = ips.value;
    send({ t: 'settings', values: v });
    if (HOST && v.popoverSize !== S.settings.popoverSize) { try { window.webkit.messageHandlers.ndi.postMessage({ action: 'popoverSize', size: v.popoverSize }); } catch (e) {} }
    closeSheet();
    toast('Settings saved');
  } });
  openSheet('settings', 'Settings', body, [el('button', { class: 'btn', text: 'Cancel', onclick: closeSheet }), save]);
});

/* ---------- network scan ---------- */
const SCAN_KEY = 'ndiviewer.scanRanges';
function openScanSheet() {
  let saved = '';
  try { saved = localStorage.getItem(SCAN_KEY) || ''; } catch (e) {}
  const ranges = el('input', { class: 'input', value: saved, placeholder: '10.0.5.0/24, 192.168.20.10-80', spellcheck: 'false', autocomplete: 'off' });
  const start = () => {
    try { localStorage.setItem(SCAN_KEY, ranges.value.trim()); } catch (e) {}
    send({ t: 'scan', ranges: ranges.value });
  };
  ranges.addEventListener('keydown', e => { if (e.key === 'Enter' && !(S.scan && S.scan.state === 'running')) start(); });
  const body = el('div', {},
    el('p', { class: 'muted', style: 'margin:0 0 12px', text: 'Checks every address on this Mac’s networks for NDI (TCP port 5960). Hosts found are added to discovery, which also finds sources on networks that block mDNS.' }),
    el('label', { class: 'field' }, el('span', { text: 'Also scan' }), ranges,
      el('small', { text: 'Optional. Subnets or ranges on other networks: 10.0.5.0/24, 10.0.5.10-80. A single address scans its /24.' })),
    el('div', { id: 'scanStatus' }));
  const action = el('button', { class: 'btn primary', id: 'scanAction' });
  action.addEventListener('click', () => (S.scan && S.scan.state === 'running') ? send({ t: 'cancelScan' }) : start());
  const saveBtn = el('button', { class: 'btn', id: 'scanSave', text: 'Save to discovery IPs', onclick: saveScanned });
  openSheet('scan', 'Scan network', body, [saveBtn, action]);
  renderScanStatus();
  setTimeout(() => ranges.focus(), 30);
}

function scannedNotSaved() {
  const have = new Set((S.settings.extraIPs || '').split(/[\s,]+/).filter(Boolean));
  return ((S.scan && S.scan.found) || []).filter(ip => !have.has(ip));
}
function saveScanned() {
  const add = scannedNotSaved();
  if (!add.length) return;
  const cur = (S.settings.extraIPs || '').trim();
  const extraIPs = [cur, add.join(', ')].filter(Boolean).join(', ');
  S.settings = { ...S.settings, extraIPs };
  send({ t: 'settings', values: { extraIPs } });
  toast(`Saved ${add.length} IP${add.length === 1 ? '' : 's'} to discovery`);
  renderScanStatus();
}

function renderScanStatus() {
  const box = $('#scanStatus'), action = $('#scanAction'), saveBtn = $('#scanSave');
  if (!box) return;
  const sc = S.scan;
  const running = !!(sc && sc.state === 'running');
  action.textContent = running ? 'Stop' : sc ? 'Scan again' : 'Scan';
  action.className = running ? 'btn' : 'btn primary';
  saveBtn.hidden = running || scannedNotSaved().length === 0;
  box.innerHTML = '';
  if (!sc) return;
  const found = sc.found || [];
  const pct = sc.total ? Math.round(sc.done / sc.total * 100) : 100;
  const summary = running ? `Checked ${sc.done} of ${sc.total} addresses · ${found.length} found`
    : !sc.total ? 'Nothing to scan. Connect to a network or enter a range.'
    : `${sc.done < sc.total ? 'Stopped after' : 'Checked'} ${sc.done} address${sc.done === 1 ? '' : 'es'} · ${found.length} NDI host${found.length === 1 ? '' : 's'} found`;
  box.append(el('div', { class: 'section-title', text: 'Results' }),
    el('div', { class: 'scan-progress' + (running ? ' running' : '') }, el('div', { style: `width:${pct}%` })),
    el('p', { class: 'muted', style: 'margin:6px 0 10px;font-size:12px', text: summary }));
  if (!found.length) return;
  const all = [...S.sources.values()];
  const list = el('div', { class: 'vlist' });
  for (const ip of found) {
    const srcs = all.filter(s => s.ip === ip);
    list.append(el('div', { class: 'vrow' },
      el('span', { class: `pill ${srcs.length ? 'active' : 'hidden'}`, text: srcs.length ? `${srcs.length} live` : 'Waiting' }),
      el('div', { class: 'who' },
        el('b', { text: srcs.length ? srcs[0].host : 'NDI host' }),
        el('span', { text: ip }),
        el('div', { class: 'what', text: srcs.length ? srcs.map(s => s.label).join(' · ') : 'Port open, no sources listed yet' })),
      el('span')));
  }
  box.append(list);
}

let toastTimer = null;
function toast(text) {
  const t = $('#toast');
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, 2800);
}

/* ---------- search & keyboard ---------- */
$('#search').addEventListener('input', e => { S.search = e.target.value; renderGallery(); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    if (!$('#menu').hidden) closeMenu();
    else if (!$('#sheet').hidden) closeSheet();
    else if (S.full) closeViewer();
    else if (S.edit) setEdit(false);
    else if (S.search) { $('#search').value = ''; S.search = ''; renderGallery(); }
    return;
  }
  const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement && document.activeElement.tagName);
  if ((e.key === 'f' && (e.metaKey || e.ctrlKey)) || (e.key === '/' && !typing)) {
    e.preventDefault();
    if (S.full) closeViewer();
    $('#search').focus(); $('#search').select();
  }
});

/* ---------- boot ---------- */
hydrateIcons();
document.body.classList.toggle('is-host', HOST);
if (store.lastScope) S.scope = store.lastScope;
render();
connect();
