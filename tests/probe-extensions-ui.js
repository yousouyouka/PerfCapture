/*
 * B120-extensions-ui —— 扩展中心页逻辑探针（纯 Node，轻量 DOM stub）
 * 用途：在无 WebView2 编译器的环境里，真实加载 ui/js/i18n.js 与 ui/js/extensions.js，
 *       断言页面元素结构、状态徽标、三语文案、筛选、空状态与「按钮置灰防假开关」。
 * 注意：本探针只验 JS 渲染逻辑与文案，不替代真 WebView2 像素回读（后者需 csc/Add-Type，
 *       当前会话被安全策略拦截）。像素级自证待有编译器环境时按 AGENTS.md §验证 补跑。
 * 用法：node tests\probe-extensions-ui.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
let fail = 0;
const ok = (m) => console.log('  ✅ ' + m);
const bad = (m) => { console.log('  ❌ ' + m); fail++; };
const assert = (cond, m) => cond ? ok(m) : bad(m);

/* ── 极简 DOM stub ── */
function makeEl(tag) {
  const e = {
    tagName: (tag || 'div').toUpperCase(),
    className: '', textContent: '', title: '', type: '', checked: false, disabled: false,
    dataset: {}, children: [], hidden: false, style: {},
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    addEventListener() {},
    querySelectorAll() { return []; },
    set innerHTML(v) { this.children = []; this._html = v; },
    get innerHTML() { return this._html || ''; }
  };
  return e;
}
const ids = {};
['extensionsList', 'extensionsCount', 'extAreas', 'extFilters', 'extOnlyInstalled',
 'extRefresh', 'extRiskBanner'].forEach(id => { ids[id] = makeEl('div'); ids[id].id = id; });

const document = {
  getElementById: (id) => ids[id] || null,
  createElement: (tag) => makeEl(tag),
  createTextNode: (t) => ({ nodeType: 3, textContent: t }),
  documentElement: { lang: 'zh-CN', classList: { contains: () => false } },
  querySelectorAll: () => []
};

const sandbox = {
  document, console,
  window: {},
  setTimeout, clearTimeout
};
sandbox.window.PerfExtensions = null; // 稍后从数据文件注入
sandbox.window.__refreshExtensions = null;
vm.createContext(sandbox);

/* ── 加载 i18n.js（顶层只定义常量与函数，无 DOM 副作用） ── */
vm.runInContext(fs.readFileSync(path.join(root, 'ui/js/i18n.js'), 'utf8'), sandbox, { filename: 'i18n.js' });

/* ── 加载扩展数据 ── */
const dataSrc = fs.readFileSync(path.join(root, 'ui/js/extensions-data.js'), 'utf8');
vm.runInContext(dataSrc, sandbox, { filename: 'extensions-data.js' });
const data = sandbox.window.PerfExtensions;
assert(Array.isArray(data) && data.length >= 5, '扩展数据加载成功（' + (data ? data.length : 0) + ' 项）');
const rtssMirror = data.find(x => x.id === 'rtss-shm');
assert(rtssMirror && rtssMirror.available === true && rtssMirror.status === 'notInstalled',
  'RTSS 回退镜像已发布且初始 notInstalled（批次 D）');
assert(data.filter(x => x.id !== 'rtss-shm').every(x => x.status === 'planned' && x.available !== true),
  '其余扩展仍规划中（无假状态）');

/* ── 加载扩展中心脚本（真实执行渲染） ── */
vm.runInContext(fs.readFileSync(path.join(root, 'ui/js/extensions.js'), 'utf8'), sandbox, { filename: 'extensions.js' });
assert(typeof sandbox.window.__refreshExtensions === 'function', 'extensions.js 暴露了 __refreshExtensions');

function flatten(node, out) {
  out = out || [];
  if (node.textContent) out.push(node.textContent);
  (node.children || []).forEach(c => flatten(c, out));
  return out;
}
const list = ids.extensionsList;
assert(list.children.length === data.length, '渲染出 ' + data.length + ' 张扩展卡片');
const allText = flatten(list).join('|');
assert(allText.includes('RTSS 共享内存桥接'), 'RTSS 候选卡片渲染');
assert(allText.includes('规划中') || allText.includes('Planned'), '状态徽标渲染（规划中）');
assert(ids.extensionsCount.textContent.length > 0, '计数已填充：' + ids.extensionsCount.textContent);

/* 已发布 RTSS 的主按钮是「一键启用」且可点；规划中扩展的按钮置灰（防假开关） */
let oneClickButtons = 0, disabledOthers = 0, plannedButtons = 0;
(function walk(n) {
  (n.children || []).forEach(c => {
    if (c.tagName === 'BUTTON' && /一键启用|Enable in one click|ワンクリック/.test(c.textContent)) {
      oneClickButtons++;
      if (c.disabled) disabledOthers++;
      if (c.dataset.cmd !== 'oneClickEnableExtension') disabledOthers++;
    }
    if (c.tagName === 'BUTTON' && /后续版本开放|coming in a later/i.test(c.textContent)) {
      plannedButtons++;
      if (!c.disabled) disabledOthers++;   // 规划中按钮必须禁用
    }
    walk(c);
  });
})(list);
assert(oneClickButtons === 1, '仅 RTSS 显示一键启用按钮（' + oneClickButtons + '）');
assert(plannedButtons === data.length - 1, '其余 ' + (data.length - 1) + ' 项显示「后续版本开放」');
assert(disabledOthers === 0, '规划中按钮全部禁用、RTSS 一键按钮可点（防假开关又不误锁）');

/* 类别筛选按钮已构建 */
assert(ids.extAreas.children.length === 4, '类别筛选渲染 4 个 chip');

/* ── 三语文案断言：直接查 I18N 表 ── */
const i18n = vm.runInContext('I18N', sandbox);
function hasTriple(key) {
  return ['zh-CN', 'en-US', 'ja-JP'].every(l => i18n[l] && i18n[l][key] != null);
}
const keys = ['nav.extensions', 'extensions.title', 'extensions.lead', 'extensions.risk',
  'extensions.count', 'extensions.oneClick', 'extensions.retry', 'extensions.progress',
  'extensions.stage.download', 'extensions.stage.install', 'extensions.stage.verifyRuntime',
  'extensions.notReady', 'extensions.emptyTitle',
  'extensions.status.planned', 'extensions.field.metrics', 'extensions.cat.all',
  'extensions.onlyInstalled', 'extensions.refresh', 'extensions.fastSource', 'extensions.standbySource',
  'extensions.reason.shmNotFound', 'extensions.reason.staleData', 'extensions.reason.noFrames',
  'extensions.reason.hashMismatch', 'extensions.reason.shmNotReady', 'extensions.reason.provisionException',
  'extensions.reason.startFailed', 'extensions.reason.downloadFailed', 'extensions.reason.uacCancelled',
  'extensions.copyDiagnostics'];
keys.forEach(k => assert(hasTriple(k), 'i18n 三语齐全：' + k));

/* 语言切换后文案确实变化 */
assert(i18n['zh-CN']['extensions.title'] === '扩展中心', '中文标题正确');
assert(i18n['en-US']['extensions.title'] === 'Extensions', '英文标题正确');
assert(i18n['ja-JP']['extensions.title'] === '拡張機能', '日文标题正确');

/* ── 批次 E：阶段进度回推后，卡片显示百分比与进度条 ── */
sandbox.window.PerfExtensionsUI.progress({ id: 'rtss-shm', stage: 'download', pct: 42 });
const progressText = flatten(list).join('|');
assert(/42%/.test(progressText), '一键启用阶段进度显示百分比');
assert(/下载|Downloading|ダウンロード/.test(progressText), '阶段文案走三语 i18n');
let hasBar = false;
(function walkBar(n) { (n.children || []).forEach(c => { if (/ext-progress-bar/.test(c.className)) hasBar = true; walkBar(c); }); })(list);
assert(hasBar, '进度条节点已渲染');
sandbox.window.PerfExtensionsUI.progress({ id: 'rtss-shm', stage: 'done', pct: 100 });

/* ── 数据源标记：apply 下发 fpsSource 后显示「当前数据源」并标注口径 ── */
const rtssState = Object.assign({}, rtssMirror, { status: 'enabled' });
sandbox.window.PerfExtensionsUI.apply([rtssState], 'rtss-shm');
const enabledText = flatten(list).join('|');
assert(/当前数据源|Current data source/.test(enabledText), '启用且为当前源时显示数据源标记');
assert(/1% Low|最慢 1%|slowest 1%/.test(enabledText), '高频源标注 1% Low 口径（不假装亚秒级）');

/* ── 兼容兜底：宿主误下发嵌套数组 [[{...}]] 时仍展平，不渲染空白卡片 ── */
sandbox.window.PerfExtensionsUI.apply([data], 'presentmon');
assert(list.children.length === data.length, '嵌套数组被展平为 ' + data.length + ' 张卡片（不渲染空白）');
assert(flatten(list).join('|').includes('RTSS 共享内存桥接'), '嵌套数组兜底后 RTSS 卡片仍可见');

/* ── 空状态：宿主下发空列表后重画 ── */
sandbox.window.PerfExtensionsUI.apply([], 'presentmon');
assert(list.children.length === 1 && list.children[0].className === 'extensions-empty', '无数据显示空状态');

/* ── E1：失败详情上屏（阶段原因 + 宿主原文 + 复制入口） ── */
sandbox.window.PerfExtensionsUI.error({ id: 'rtss-shm', reason: 'startFailed', detail: 'start 阶段：参数不合法' });
const errText = flatten(list).join('|');
assert(/启动阶段出错|Startup failed|起動段階/.test(errText), '阶段化原因上屏（不再笼统「安装过程出错」）');
assert(errText.includes('start 阶段：参数不合法'), '宿主 detail 原文原样展示');
let hasCopy = false;
(function walkCopy(n) { (n.children || []).forEach(c => {
  if (c.tagName === 'BUTTON' && /复制诊断信息|Copy diagnostics|診断情報をコピー/.test(c.textContent)) hasCopy = true;
  walkCopy(c);
}); })(list);
assert(hasCopy, '失败时提供「复制诊断信息」入口');

console.log('\n' + (fail === 0 ? 'B120 全部通过（' + '逻辑层' + '）' : 'B120 失败 ' + fail + ' 项'));
process.exit(fail === 0 ? 0 : 1);
