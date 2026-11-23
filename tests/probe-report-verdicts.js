/*
 * probe-report-verdicts —— 判读增强报告板块探针（2.1.17 / F4-1 + F4-2）
 *
 * 由来：判定逻辑有 PowerShell 探针，但「结论有没有渲染出来、原始数值有没有丢、
 *       无法区分时有没有说清原因」只能靠真实加载 report.js + i18n.js 验证。
 *
 * 覆盖：限制类型五种结论、依据行、后台 Top 3、老报告降级、三语切换。
 *
 * 用法：node tests\probe-report-verdicts.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
let fail = 0;
const assert = (cond, m) => cond ? console.log('  ✅ ' + m) : (console.log('  ❌ ' + m), fail++);

const ctx = {
  console,
  window: {},
  document: {
    readyState: 'complete',
    getElementById: () => null,
    querySelectorAll: () => [],
    addEventListener() {},
    documentElement: { lang: 'zh-CN', dataset: {} },
  },
  escapeHtml: (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'),
  // report.js 顶层会构造一个 Image 用于导出背景，探针里给个空壳即可
  Image: function () { return { src: '', onload: null, addEventListener() {}, complete: false }; },
  setTimeout: () => 0,
  requestAnimationFrame: () => 0,
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(root, 'ui', 'js', 'i18n.js'), 'utf8'), ctx);
vm.runInContext(fs.readFileSync(path.join(root, 'ui', 'js', 'report.js'), 'utf8'), ctx);

assert(typeof ctx.limitBlock === 'function', 'report.js 暴露 limitBlock');
assert(typeof ctx.bgProcBlock === 'function', 'report.js 暴露 bgProcBlock');

/* ── 1. 限制类型：结论 + 原始数值依据 ── */
const rThermal = {
  limit: {
    kind: 'thermal', reason_code: 'gpuThermal',
    evidence: [
      { metric: 'throttle.sw_thermal', name: '温度墙（软）', value: '42.0 %' },
      { metric: 'gpu.temp', name: 'GPU 峰值温度', value: '86.0 °C' },
    ],
  },
};
const h1 = ctx.limitBlock(rThermal);
assert(h1.includes('热墙'), '热墙结论渲染出来');
assert(h1.includes('驱动报告 GPU 温度降频'), '为什么这么判也说出来了');
assert(h1.includes('42.0 %') && h1.includes('86.0 °C'), '两条原始数值都在');
assert(h1.includes('data-metric="throttle.sw_thermal"'), '依据行带稳定 metric 标识');
assert(h1.includes('温度墙（软）'), '限流原因用已有三语词典标签');

/* ── 2. 无法区分：必须说清原因，不许只给个空结论 ── */
const h2 = ctx.limitBlock({ limit: { kind: 'indistinct', reason_code: 'noData', evidence: [] } });
assert(h2.includes('无法区分'), '数据不足时显示无法区分');
assert(h2.includes('不能说成「未观察到限制」'), '明确解释为什么不是「未观察到限制」');
assert(h2.includes('rp-diag warn'), '无法区分用警告样式，不伪装成正常结论');

/* ── 3. 老报告 / 无数据：不占版面 ── */
assert(ctx.limitBlock({}) === '', '老报告没有 limit 时不渲染');
assert(ctx.limitBlock({ limit: {} }) === '', '空 limit 不渲染');

/* ── 4. 后台干扰 Top 3 ── */
const rBg = {
  background_proc: {
    state: 'ok', interval_sec: 5, sample_count: 24,
    procs: [
      { name: 'chrome', avg_cpu_pct: 22, peak_cpu_pct: 45.5, samples: 20 },
      { name: 'explorer', avg_cpu_pct: 3.2, peak_cpu_pct: 9, samples: 24 },
    ],
  },
};
const h3 = ctx.bgProcBlock(rBg);
assert(h3.includes('后台干扰 Top 3'), '板块标题出现');
assert((h3.match(/class="row"/g) || []).length === 2, '渲染两个进程行');
assert(h3.includes('data-proc="chrome"') && h3.includes('平均 22 % · 峰值 45.5 %'), '进程名与平均/峰值都在');
assert(h3.includes('出现 20/24 次采样'), '出现次数如实标注，不按出现次数虚高平均');
assert(h3.includes('只读进程 CPU，不读其它进程的 GPU'), '口径说明写明只读 CPU');
assert(!h3.includes('无干扰'), '不写「无干扰」这种没有数据支撑的结论');

/* ── 5. 关闭 / 没采到 / 老报告：不占版面 ── */
assert(ctx.bgProcBlock({ background_proc: { state: 'skipped' } }) === '', '用户关闭时不渲染');
assert(ctx.bgProcBlock({ background_proc: { state: 'noSamples' } }) === '', '没采到时不渲染');
assert(ctx.bgProcBlock({}) === '', '老报告不渲染');

/* ── 6. 三语：同一份数据切换语言后结论随语言走 ── */
vm.runInContext("LANG = 'en-US'", ctx);
const hEn = ctx.limitBlock(rThermal);
assert(hEn.includes('Thermal wall'), '英文显示 Thermal wall');
assert(hEn.includes('The driver reported GPU thermal throttling.'), '英文原因文案齐全');
vm.runInContext("LANG = 'ja-JP'", ctx);
const hJa = ctx.limitBlock(rThermal);
assert(hJa.includes('温度制限'), '日文显示温度制限');
assert(ctx.bgProcBlock(rBg).includes('バックグラウンド干渉 Top 3'), '日文后台板块标题齐全');

console.log('');
console.log(fail === 0 ? '结果: 全部通过' : ('结果: ' + fail + ' 项失败'));
process.exit(fail ? 1 : 0);
