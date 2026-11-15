/* 拖动分割：拖报告卡左边框改左右两列宽度。
   规则：只改左栏宽度这一侧，右栏靠最小宽度钳制 + 自身滚动保证可读，不做互相裁切。
   宽度记在 localStorage（perf.split.col，单位 px），双击恢复默认比例。 */

const SPLIT_COL_KEY = 'perf.split.col';

function remPx() {
  const v = parseFloat(getComputedStyle(document.documentElement).fontSize);
  return Number.isFinite(v) ? v : 16;
}
function readPx(key) {
  const v = parseInt(localStorage.getItem(key), 10);
  return Number.isFinite(v) && v > 0 ? v : 0;
}
function writePx(key, v) {
  try { localStorage.setItem(key, String(Math.round(v))); } catch (e) { /* 隐私模式等：忽略 */ }
}
function clearPx(key) {
  try { localStorage.removeItem(key); } catch (e) { /* 忽略 */ }
}

/* ── 左右宽度 ── */
function colRange() {
  const lay = $('.layout');
  const rem = remPx();
  const gap = parseFloat(getComputedStyle(lay).columnGap) || 0;
  const min = 20 * rem;                    // 对应 layout.css 的 minmax(20rem, …)
  const total = lay.clientWidth;
  // 容器没有尺寸（页面被隐藏）时不钳制，避免把宽度压到最小值
  return { min, max: total > 0 ? Math.max(min, total - gap - 18 * rem) : Infinity };
}
function colWidth() { return $('.col-left').getBoundingClientRect().width; }

function setColWidth(w) {
  const r = colRange();
  const v = Math.min(Math.max(w, r.min), r.max);
  const lay = $('.layout');
  lay.classList.add('has-col-width');      // 左栏固定 px 后，右栏改用 1fr 吃掉剩余空间
  lay.style.setProperty('--col-left-w', Math.round(v) + 'px');
  return v;
}
function resetColWidth() {
  const lay = $('.layout');
  lay.classList.remove('has-col-width');
  lay.style.removeProperty('--col-left-w');
  clearPx(SPLIT_COL_KEY);
}

/* ── 拖动绑定 ── */
function initColSplit() {
  const handle = $('#splitCol');
  if (!handle) return;

  const w = readPx(SPLIT_COL_KEY);
  if (w) setColWidth(w);

  let dragging = false;
  let startPos = 0;      // 按下时的鼠标位置
  let startSize = 0;     // 按下时的左栏宽度（整个拖动过程都用它做基准，不能每次重读）
  let last = 0;

  const onMove = (ev) => {
    if (!dragging) return;
    last = setColWidth(startSize + (ev.clientX - startPos));
  };
  const onUp = () => {
    if (!dragging) return;
    dragging = false;
    document.body.classList.remove('is-col-resizing');
    handle.removeEventListener('pointermove', onMove);
    handle.removeEventListener('pointerup', onUp);
    handle.removeEventListener('pointercancel', onUp);
    writePx(SPLIT_COL_KEY, last);
  };

  handle.addEventListener('pointerdown', (ev) => {
    if (ev.button !== 0) return;
    ev.preventDefault();
    dragging = true;
    startPos = ev.clientX;
    startSize = colWidth();
    last = startSize;
    document.body.classList.add('is-col-resizing');
    // 合成事件没有活动指针，捕获失败不影响拖动（move/up 仍会派发到本元素）
    try { handle.setPointerCapture(ev.pointerId); } catch (e) { /* 忽略 */ }
    handle.addEventListener('pointermove', onMove);
    handle.addEventListener('pointerup', onUp);
    handle.addEventListener('pointercancel', onUp);
    handle.focus();
  });

  handle.addEventListener('dblclick', resetColWidth);

  handle.addEventListener('keydown', (ev) => {
    const step = (ev.shiftKey ? 4 : 1) * remPx();
    let d = 0;
    if (ev.key === 'ArrowLeft') d = -step;
    else if (ev.key === 'ArrowRight') d = step;
    if (!d) return;
    ev.preventDefault();
    writePx(SPLIT_COL_KEY, setColWidth(colWidth() + d));
  });

  // 窗口变化后按记录值重新钳制（窗口变小不该让右栏被压到不可读）
  window.addEventListener('resize', () => {
    const cw = readPx(SPLIT_COL_KEY);
    if (cw) setColWidth(cw);
  });
}

initColSplit();
