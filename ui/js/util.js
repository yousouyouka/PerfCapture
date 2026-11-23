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

/* 下载速度 / 体积：0 或非法回空串，调用方据此决定要不要显示。
   扩展中心与更新提示曾各写一份，现统一在此（util.js 在所有脚本之前加载）。 */
function fmtBytes(b) {
  const n0 = Number(b);
  if (!(n0 > 0)) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  let n = n0;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
  return (i === 0 ? String(Math.round(n)) : n.toFixed(1)) + ' ' + units[i];
}

