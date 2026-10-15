import init, { GridEngine } from './pkg/gridcraft_wasm.js';

const CELL_W = 96;
const CELL_H = 34;
const HEAD_W = 48;
const HEAD_H = 28;
const MAX_ROWS = 1048576;
const MAX_COLS = 16384;
const AUTOSAVE_KEY = 'gridcraft.autosave.v1';

const $ = (id) => document.getElementById(id);
const canvas = $('canvas');
const scroller = $('scroller');
const spacer = $('spacer');
const formula = $('formula');
const ctx = canvas.getContext('2d');

let engine;
let selRow = 0;
let selCol = 0;
let rowCount = 0;
let colCount = 0;
let editing = false;
let drawQueued = false;
let lastTap = { time: 0, row: -1, col: -1 };
let toastTimer;
let autosaveTimer;

// ---------- helpers ----------

function columnName(col) {
  let n = col + 1;
  let name = '';
  while (n > 0) {
    const r = (n - 1) % 26;
    name = String.fromCharCode(65 + r) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}

function looksNumeric(text) {
  const s = text.replace(/[\s,$%€£¥()]/g, '');
  return s !== '' && !Number.isNaN(Number(s));
}

function toast(message, ms = 3500) {
  const el = $('toast');
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, ms);
}

/** Runs an engine call, showing its error instead of throwing; refreshes the UI afterwards. */
function run(action) {
  try {
    action();
  } catch (e) {
    toast(e?.message ?? String(e));
  }
  refresh();
}

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

// ---------- sizing ----------

function ensureSize(rows, cols) {
  const r = Math.min(Math.max(rows, rowCount), MAX_ROWS);
  const c = Math.min(Math.max(cols, colCount), MAX_COLS);
  if (r === rowCount && c === colCount) return;
  rowCount = r;
  colCount = c;
  spacer.style.width = `${HEAD_W + c * CELL_W}px`;
  spacer.style.height = `${HEAD_H + r * CELL_H}px`;
}

function resetSize() {
  const [usedRows, usedCols] = engine.usedSize();
  rowCount = 0;
  colCount = 0;
  ensureSize(usedRows + 200, usedCols + 26);
  scroller.scrollTo(0, 0);
}

function resizeCanvas() {
  const dpr = window.devicePixelRatio || 1;
  const w = scroller.clientWidth;
  const h = scroller.clientHeight;
  canvas.width = Math.round(w * dpr);
  canvas.height = Math.round(h * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  draw();
}

// ---------- drawing ----------

function draw() {
  drawQueued = false;
  if (!engine) return;
  const w = scroller.clientWidth;
  const h = scroller.clientHeight;
  const sx = Math.max(0, scroller.scrollLeft);
  const sy = Math.max(0, scroller.scrollTop);
  const firstCol = Math.min(Math.floor(sx / CELL_W), MAX_COLS - 1);
  const firstRow = Math.min(Math.floor(sy / CELL_H), MAX_ROWS - 1);
  const cols = Math.min(Math.ceil(w / CELL_W) + 1, MAX_COLS - firstCol);
  const rows = Math.min(Math.ceil(h / CELL_H) + 1, MAX_ROWS - firstRow);
  const x0 = HEAD_W + firstCol * CELL_W - sx;
  const y0 = HEAD_H + firstRow * CELL_H - sy;

  const colors = {
    bg: cssVar('--bg'), text: cssVar('--text'), muted: cssVar('--muted'), line: cssVar('--line'),
    header: cssVar('--header'), accent: cssVar('--accent'), soft: cssVar('--accent-soft'),
  };

  ctx.fillStyle = colors.bg;
  ctx.fillRect(0, 0, w, h);

  // Cell texts, clipped to their cell; left-aligned text spills over empty cells to its right,
  // like Excel.
  const texts = engine.viewport(firstRow, firstCol, rows, cols);
  ctx.font = '15px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
  ctx.textBaseline = 'middle';
  ctx.fillStyle = colors.text;
  for (let i = 0; i < rows; i++) {
    for (let j = 0; j < cols; j++) {
      const text = texts[i * cols + j];
      if (!text) continue;
      const x = x0 + j * CELL_W;
      const y = y0 + i * CELL_H;
      let span = 1;
      if (!looksNumeric(text)) {
        while (j + span < cols && !texts[i * cols + j + span]) span++;
      }
      ctx.save();
      ctx.beginPath();
      ctx.rect(x + 4, y, span * CELL_W - 8, CELL_H);
      ctx.clip();
      if (looksNumeric(text)) {
        ctx.textAlign = 'right';
        ctx.fillText(text, x + CELL_W - 6, y + CELL_H / 2);
      } else {
        ctx.textAlign = 'left';
        ctx.fillText(text, x + 6, y + CELL_H / 2);
      }
      ctx.restore();
    }
  }

  // Grid lines.
  ctx.strokeStyle = colors.line;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let j = 0; j <= cols; j++) {
    const x = Math.round(x0 + j * CELL_W) + 0.5;
    ctx.moveTo(x, 0);
    ctx.lineTo(x, h);
  }
  for (let i = 0; i <= rows; i++) {
    const y = Math.round(y0 + i * CELL_H) + 0.5;
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
  }
  ctx.stroke();

  // Selected cell.
  ctx.strokeStyle = colors.accent;
  ctx.lineWidth = 2.5;
  ctx.strokeRect(HEAD_W + selCol * CELL_W - sx + 1, HEAD_H + selRow * CELL_H - sy + 1, CELL_W - 2, CELL_H - 2);

  // Sticky headers, drawn last so cells scroll under them.
  ctx.fillStyle = colors.header;
  ctx.fillRect(0, 0, w, HEAD_H);
  ctx.fillRect(0, 0, HEAD_W, h);
  ctx.font = '500 12px -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif';
  ctx.textAlign = 'center';
  for (let j = 0; j < cols; j++) {
    const col = firstCol + j;
    const x = x0 + j * CELL_W;
    if (x + CELL_W <= HEAD_W) continue;
    if (col === selCol) {
      ctx.fillStyle = colors.soft;
      ctx.fillRect(x, 0, CELL_W, HEAD_H);
    }
    ctx.fillStyle = colors.muted;
    ctx.fillText(columnName(col), x + CELL_W / 2, HEAD_H / 2);
  }
  for (let i = 0; i < rows; i++) {
    const row = firstRow + i;
    const y = y0 + i * CELL_H;
    if (y + CELL_H <= HEAD_H) continue;
    if (row === selRow) {
      ctx.fillStyle = colors.soft;
      ctx.fillRect(0, y, HEAD_W, CELL_H);
    }
    ctx.fillStyle = colors.muted;
    ctx.fillText(String(row + 1), HEAD_W / 2, y + CELL_H / 2);
  }
  ctx.fillStyle = colors.header;
  ctx.fillRect(0, 0, HEAD_W, HEAD_H);
  ctx.strokeStyle = colors.line;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(0, HEAD_H + 0.5);
  ctx.lineTo(w, HEAD_H + 0.5);
  ctx.moveTo(HEAD_W + 0.5, 0);
  ctx.lineTo(HEAD_W + 0.5, h);
  ctx.stroke();
}

function queueDraw() {
  if (drawQueued) return;
  drawQueued = true;
  requestAnimationFrame(draw);
}

// ---------- state ----------

function refresh() {
  $('title').textContent = engine.title() || 'GridCraft';
  document.title = `${engine.title()} – GridCraft`;
  $('undo-btn').disabled = !engine.canUndo();
  $('redo-btn').disabled = !engine.canRedo();
  renderTabs();
  const [usedRows, usedCols] = engine.usedSize();
  ensureSize(usedRows + 200, usedCols + 26);
  if (!editing) formula.value = engine.editText(selRow, selCol);
  $('name-box').textContent = columnName(selCol) + (selRow + 1);
  queueDraw();
  scheduleAutosave();
}

function renderTabs() {
  const tabs = $('tabs');
  const names = engine.sheetNames();
  const active = engine.activeSheet();
  tabs.replaceChildren(...names.map((name, i) => {
    const b = document.createElement('button');
    b.textContent = name;
    b.className = i === active ? 'active' : '';
    b.addEventListener('click', () => {
      run(() => engine.activateSheet(i));
      select(0, 0);
      resetSize();
    });
    return b;
  }));
}

function select(row, col) {
  selRow = Math.max(0, Math.min(row, MAX_ROWS - 1));
  selCol = Math.max(0, Math.min(col, MAX_COLS - 1));
  ensureSize(selRow + 50, selCol + 10);
  scrollIntoView();
  formula.value = engine.editText(selRow, selCol);
  $('name-box').textContent = columnName(selCol) + (selRow + 1);
  queueDraw();
}

function scrollIntoView() {
  const left = selCol * CELL_W;
  const top = selRow * CELL_H;
  const viewW = scroller.clientWidth - HEAD_W;
  const viewH = scroller.clientHeight - HEAD_H;
  let { scrollLeft, scrollTop } = scroller;
  if (left < scrollLeft) scrollLeft = left;
  else if (left + CELL_W > scrollLeft + viewW) scrollLeft = left + CELL_W - viewW;
  if (top < scrollTop) scrollTop = top;
  else if (top + CELL_H > scrollTop + viewH) scrollTop = top + CELL_H - viewH;
  if (scrollLeft !== scroller.scrollLeft || scrollTop !== scroller.scrollTop) {
    scroller.scrollTo({ left: scrollLeft, top: scrollTop });
  }
}

function setEditing(on) {
  editing = on;
  $('cancel-btn').hidden = !on;
  $('commit-btn').hidden = !on;
}

function commit(moveDown) {
  const input = formula.value;
  run(() => engine.setCell(selRow, selCol, input));
  if (moveDown) select(selRow + 1, selCol);
}

function cancelEdit() {
  formula.value = engine.editText(selRow, selCol);
  setEditing(false);
  formula.blur();
}

// ---------- files ----------

function bytesToBase64(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function base64ToBytes(b64) {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function workbookFileName(ext) {
  const base = (engine.title() || 'Book').replace(/\.[^.]+$/, '');
  return `${base}.${ext}`;
}

async function openFile(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  try {
    const warnings = engine.open(file.name, bytes);
    if (warnings.length) toast(warnings.slice(0, 5).join('\n\n'), 6000);
  } catch (e) {
    toast(e?.message ?? String(e));
  }
  selRow = 0;
  selCol = 0;
  resetSize();
  refresh();
}

function download(format) {
  let bytes;
  try {
    bytes = engine.save(format);
  } catch (e) {
    toast(e?.message ?? String(e));
    return;
  }
  const type = format === 'csv' ? 'text/csv' : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const a = document.createElement('a');
  a.href = url;
  a.download = workbookFileName(format);
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

// Keeps the open workbook across reloads, in this browser only.
function scheduleAutosave() {
  clearTimeout(autosaveTimer);
  autosaveTimer = setTimeout(() => {
    try {
      const data = bytesToBase64(engine.save('xlsx'));
      localStorage.setItem(AUTOSAVE_KEY, JSON.stringify({ name: workbookFileName('xlsx'), data }));
    } catch {
      // Storage full or unavailable: autosave is a convenience, so carry on without it.
    }
  }, 800);
}

function restoreAutosave() {
  try {
    const saved = JSON.parse(localStorage.getItem(AUTOSAVE_KEY) ?? 'null');
    if (saved?.data) engine.open(saved.name, base64ToBytes(saved.data));
  } catch {
    // Unreadable autosave: start with a blank workbook.
  }
}

// ---------- events ----------

function cellAt(clientX, clientY) {
  const rect = scroller.getBoundingClientRect();
  const x = clientX - rect.left;
  const y = clientY - rect.top;
  if (x < HEAD_W || y < HEAD_H) return null;
  const col = Math.floor((x - HEAD_W + scroller.scrollLeft) / CELL_W);
  const row = Math.floor((y - HEAD_H + scroller.scrollTop) / CELL_H);
  if (row < 0 || col < 0 || row >= MAX_ROWS || col >= MAX_COLS) return null;
  return { row, col };
}

function bindEvents() {
  scroller.addEventListener('scroll', () => {
    const nearBottom = scroller.scrollTop + 2 * scroller.clientHeight > scroller.scrollHeight;
    const nearRight = scroller.scrollLeft + 2 * scroller.clientWidth > scroller.scrollWidth;
    if (nearBottom || nearRight) ensureSize(rowCount + (nearBottom ? 500 : 0), colCount + (nearRight ? 26 : 0));
    queueDraw();
  }, { passive: true });

  scroller.addEventListener('click', (e) => {
    const hit = cellAt(e.clientX, e.clientY);
    if (!hit) return;
    const now = performance.now();
    const doubleTap = now - lastTap.time < 400 && hit.row === lastTap.row && hit.col === lastTap.col;
    lastTap = { time: now, row: hit.row, col: hit.col };
    if (editing && !doubleTap) commit(false);
    setEditing(false);
    select(hit.row, hit.col);
    if (doubleTap) {
      setEditing(true);
      formula.focus();
    } else {
      formula.blur();
    }
  });

  formula.addEventListener('focus', () => setEditing(true));
  formula.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commit(true);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelEdit();
    }
  });
  $('commit-btn').addEventListener('pointerdown', (e) => {
    e.preventDefault();
    commit(false);
    setEditing(false);
    formula.blur();
  });
  $('cancel-btn').addEventListener('pointerdown', (e) => {
    e.preventDefault();
    cancelEdit();
  });

  // Keyboard navigation when not typing in the formula bar (desktop and iPad keyboards).
  document.addEventListener('keydown', (e) => {
    if (document.activeElement === formula || e.metaKey || e.ctrlKey || e.altKey) {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'z' && document.activeElement !== formula) {
        e.preventDefault();
        run(() => (e.shiftKey ? engine.redo() : engine.undo()));
      }
      return;
    }
    const moves = { ArrowUp: [-1, 0], ArrowDown: [1, 0], ArrowLeft: [0, -1], ArrowRight: [0, 1], Enter: [1, 0], Tab: [0, 1] };
    if (moves[e.key]) {
      e.preventDefault();
      const [dr, dc] = moves[e.key];
      select(selRow + (e.shiftKey ? -dr : dr), selCol + (e.shiftKey ? -dc : dc));
    } else if (e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault();
      run(() => engine.setCell(selRow, selCol, ''));
    } else if (e.key === 'F2') {
      e.preventDefault();
      formula.focus();
    } else if (e.key.length === 1) {
      // Typing starts a fresh entry, like Excel.
      formula.value = '';
      formula.focus();
    }
  });

  const menu = $('menu');
  const menuBtn = $('menu-btn');
  const closeMenu = () => { menu.hidden = true; menuBtn.setAttribute('aria-expanded', 'false'); };
  menuBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    menu.hidden = !menu.hidden;
    menuBtn.setAttribute('aria-expanded', String(!menu.hidden));
  });
  document.addEventListener('click', (e) => { if (!menu.contains(e.target)) closeMenu(); });
  menu.addEventListener('click', (e) => {
    const item = e.target.closest('button');
    if (!item) return;
    closeMenu();
    switch (item.dataset.action) {
      case 'new':
        engine.newWorkbook();
        selRow = 0; selCol = 0;
        resetSize();
        refresh();
        break;
      case 'open':
        $('file-input').click();
        break;
      case 'sample':
        run(() => engine.openSample(item.dataset.sample));
        selRow = 0; selCol = 0;
        resetSize();
        refresh();
        break;
      case 'export':
        download(item.dataset.format);
        break;
    }
  });
  $('file-input').addEventListener('change', async (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';
    if (file) await openFile(file);
  });

  $('clear-btn').addEventListener('click', () => run(() => engine.setCell(selRow, selCol, '')));
  $('undo-btn').addEventListener('click', () => run(() => engine.undo()));
  $('redo-btn').addEventListener('click', () => run(() => engine.redo()));

  new ResizeObserver(resizeCanvas).observe(scroller);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', queueDraw);
}

// ---------- start ----------

async function main() {
  try {
    await init();
  } catch (e) {
    $('loading').textContent = `Couldn't load the spreadsheet engine: ${e?.message ?? e}`;
    return;
  }
  engine = new GridEngine();
  restoreAutosave();
  bindEvents();
  resetSize();
  refresh();
  resizeCanvas();
  $('loading').hidden = true;

  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
}

main();
