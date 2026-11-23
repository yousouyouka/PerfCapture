/*
 * probe-reports-ui —— 历史报告页逻辑探针（纯 Node，轻量 DOM stub）
 *
 * 由来：2.1.13 首版把 bridge 的 send() 当成「先命令、再参数」的两段式调用，
 *       实际它只收一个对象，宿主拿到裸字符串后 $msg.cmd 为空、静默丢弃 ——
 *       表现为「列表空的、打开目录没反应」。静态断言当时全是绿的，所以补这支探针，
 *       专门钉住**发出的消息体形状**，而不只是「有没有调用」。
 *
 * 覆盖：消息体（列表/详情/删除/对比/打开目录）、列表渲染与徽标、
 *       删除两段确认、对比 A/B 时间序、可比性三级判定。
 *
 * 用法：node tests\probe-reports-ui.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
let fail = 0;
const assert = (cond, m) => cond ? console.log('  ✅ ' + m) : (console.log('  ❌ ' + m), fail++);

/* ── DOM stub：元素带 addEventListener 记录，便于直接触发 click ── */
const els = {};
function mk(id) {
  const e = {
    id, innerHTML: '', textContent: '', hidden: false, placeholder: '', value: '',
    dataset: {}, _l: {},
    classList: { toggle() {}, add() {}, remove() {}, contains() { return false; } },
    addEventListener(ev, fn) { (this._l[ev] = this._l[ev] || []).push(fn); },
    closest() { return this; },
    focus() {},
  };
  els[id] = e;
  return e;
}
['repList', 'repPanel', 'repChips', 'repCount', 'repPickInfo', 'repSearch',
 'repRefresh', 'repOpenFolder', 'repClearPick'].forEach(mk);

const sent = [];
const ctx = {
  console,
  window: {},
  document: {
    readyState: 'complete',
    getElementById: (id) => els[id] || null,
    querySelectorAll: () => [],
    addEventListener() {},
    documentElement: { lang: 'zh-CN' },
  },
  // i18n 桩：返回 fallback，等价于中文环境（探针断言的就是这些中文兜底文案）
  t: (k, d) => d,
  escapeHtml: (s) => String(s),
  fillParams: (s, p) => String(s).replace(/\{(\w+)\}/g, (m, k) => (p && p[k] != null ? p[k] : m)),
  send: (m) => sent.push(m),
  state: {},
  LANG: 'zh-CN',
  setTimeout: () => 0,
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(root, 'ui', 'js', 'reports.js'), 'utf8'), ctx);

const H = ctx.window.PerfReports;
assert(!!H, 'reports.js 暴露 PerfReports');

/* ── 1. 消息体形状：必须是 {cmd:...} 对象 ── */
sent.length = 0;
H.ensureLoaded(true);
assert(sent.length === 1 && sent[0] && sent[0].cmd === 'reportsList', '首次进入发 {cmd:reportsList} 对象');

sent.length = 0;
els.repOpenFolder._l.click[0]({ target: els.repOpenFolder });
assert(sent.length === 1 && sent[0] && sent[0].cmd === 'openReports', '「打开目录」发 {cmd:openReports}');

/* ── 2. 列表渲染 ── */
H.handle({
  type: 'reports', total: 2, truncated: false,
  items: [
    { id: 'a', process: 'GameA', mtime: 1700000000000, avg: 120.4, low1: 88.1, seconds: 120, frames: 7200, driver: '566.36', quality: 'ok' },
    { id: 'b', process: 'GameA', mtime: 1700000100000, avg: 98.0, low1: 70.2, seconds: 90, frames: 5400, driver: '566.36', quality: 'caution' },
  ],
});
const listHtml = els.repList.innerHTML;
assert((listHtml.match(/class="rep-row/g) || []).length === 2, '列表渲染两行');
assert(listHtml.includes('数据需注意'), 'caution 显示「数据需注意」徽标');
assert(!listHtml.includes('数据不足'), 'ok 不显示「数据不足」徽标');
assert(els.repCount.textContent.includes('共 2 份'), '计数文案正确');

/* ── 3. 行内动作：详情 / 删除两段确认 ── */
function fire(target, rowId) {
  const row = { dataset: { id: rowId || 'a' } };
  target.closest = () => row;
  els.repList._l.click[0]({ target, currentTarget: els.repList });
}

sent.length = 0;
fire({ dataset: { act: 'detail', rowId: 'a' } }, 'a');
assert(sent[0] && sent[0].cmd === 'reportDetail' && sent[0].id === 'a', '「查看」发 {cmd:reportDetail,id}');

sent.length = 0;
const delBtn = { dataset: { act: 'del' }, textContent: '', classList: { add() {} } };
fire(delBtn, 'a');
assert(sent.length === 0, '删除第一次只提示、不发命令');
assert(delBtn.textContent === '确认删除？', '删除按钮变「确认删除？」');
fire(delBtn, 'a');
assert(sent[0] && sent[0].cmd === 'reportDelete' && sent[0].id === 'a' && sent[0].withAssets === true,
  '删除第二次发 {cmd:reportDelete,withAssets:true}');

/* ── 4. 勾选两份 → 对比，A 必须是比较早的那次 ── */
sent.length = 0;
H.handle({
  type: 'reports', total: 2, truncated: false,
  items: [
    { id: 'new', process: 'G', mtime: 2000, avg: 130, low1: 95, seconds: 120, frames: 7800 },
    { id: 'old', process: 'G', mtime: 1000, avg: 120, low1: 88, seconds: 120, frames: 7200 },
  ],
});
fire({ dataset: { act: 'pick', rowId: 'new' } }, 'new');
fire({ dataset: { act: 'pick', rowId: 'old' } }, 'old');
const cmp = sent[sent.length - 1];
assert(cmp && cmp.cmd === 'reportCompare' && Array.isArray(cmp.ids) && cmp.ids.length === 2,
  '勾两份发 {cmd:reportCompare,ids:[2]}');
assert(cmp.ids[0] === 'old' && cmp.ids[1] === 'new', 'A 固定为较早的一次（与点击顺序无关）');

/* ── 5. 可比性三级判定 ── */
const base = {
  process: 'G', avg_fps: 120, fps_1pct_low: 88, fps_01pct_low: 70,
  stutter: { count: 10, worst_ms: 120 }, gpu_util_avg_pct: 95, gpu_temp_max_c: 70, cpu_util_avg_pct: 40,
  resolution: '2560x1440', present_mode: 'Hardware: Independent Flip',
  environment: { gpu_model: 'RTX 5060', driver_version: '566.36', os_version: 'Win11', bios_version: 'X', fps_source: 'presentmon' },
};
const clone = (o) => JSON.parse(JSON.stringify(o));

// 5a. 条件一致 → 出百分比
H.handle({ type: 'reportCompare', ok: true, a: base, b: Object.assign(clone(base), { avg_fps: 130 }) });
let html = els.repPanel.innerHTML;
assert(html.includes('条件指纹一致'), '条件一致：提示可直接对比');
assert(/\+8\.3%/.test(html), '条件一致：给出 +8.3% 百分比');
assert(html.includes('+10.0'), '条件一致：给出原始差值 +10.0');

// 5b. 驱动不同 → 不可比、无百分比
const b2 = clone(base); b2.environment.driver_version = '566.99'; b2.avg_fps = 140;
H.handle({ type: 'reportCompare', ok: true, a: base, b: b2 });
html = els.repPanel.innerHTML;
assert(html.includes('关键条件不同'), '驱动不同：明确标注不可比');
assert(!/变化[\s\S]*?\+\d+\.\d%/.test(html), '驱动不同：不出现百分比结论');
assert(html.includes('566.36') && html.includes('566.99'), '驱动不同：列出两侧取值');

// 5c. 老报告缺指纹 → 明确「无法确认」，不当成相同
const old = clone(base); old.environment = { gpu_model: 'RTX 5060' };
H.handle({ type: 'reportCompare', ok: true, a: old, b: base });
html = els.repPanel.innerHTML;
assert(html.includes('无法确认条件是否一致'), '缺字段：提示无法确认');
assert(!html.includes('条件指纹一致'), '缺字段：不得声称条件一致');

// 5d. 分辨率不同 → 只提示注意，仍可对比
const b4 = clone(base); b4.resolution = '1920x1080';
H.handle({ type: 'reportCompare', ok: true, a: base, b: b4 });
html = els.repPanel.innerHTML;
assert(html.includes('结论需结合'), '分辨率不同：提示结论需注意');
assert(!html.includes('关键条件不同'), '分辨率不同：不算不可比');

/* ── 6. 详情渲染 ── */
H.handle({
  type: 'reportDetail', ok: true, id: 'a',
  data: { run: 'a', process: 'GameA', captured_seconds: 120, frames: 7200, resolution: '2560x1440',
    environment: { gpu_model: 'RTX 5060', driver_version: '566.36', os_version: 'Win11', bios_version: 'X' },
    quality: { level: 'ok' } },
  files: [{ kind: 'json' }, { kind: 'html' }, { kind: 'pmcsv' }],
});
html = els.repPanel.innerHTML;
assert(html.includes('566.36'), '详情卡显示驱动版本');
assert(html.includes('逐帧 CSV'), '详情卡给出逐帧 CSV 按钮');
assert(!html.includes('传感器 CSV'), '没有 sensors csv 时不显示该按钮');

console.log('');
if (fail) { console.log('== 失败 ' + fail + ' 项 =='); process.exit(1); }
console.log('== 全部通过 ==');
process.exit(0);
