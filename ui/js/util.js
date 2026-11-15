/* 通用工具：选择器、HTML 转义、数字格式化、颜色 */

/* PerfCapture · 交互层
   与宿主（PowerShell + WebView2）通过 postMessage 通信；
   所有滚动交给浏览器原生处理，滚动条由 CSS 画成圆角细条。 */

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

function escapeHtml(s) {
  return String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

const fmt = (v, unit, digits = 1) => {
  if (v === null || v === undefined || v === '' || v === 'NA') return { v: '—', unit: '' };
  const n = Number(v);
  const text = Number.isFinite(n) ? n.toFixed(digits).replace(/\.0+$/, '') : String(v);
  return { v: text, unit: unit || '' };
};

function hexA(hex, a) {
  const m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex.trim());
  if (!m) return `rgba(113,100,147,${a})`;
  return `rgba(${parseInt(m[1], 16)},${parseInt(m[2], 16)},${parseInt(m[3], 16)},${a})`;
}

