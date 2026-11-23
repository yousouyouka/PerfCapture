'use strict';
/* 网络页 DOM 探针（2.1.18）：不依赖宿主，喂构造样本验证渲染与启停消息。
   断言目标：消息形状、每接口卡片/曲线/累计、合计口径（只算物理）、
   计数器回退不造数、接口消失清行、启停命令、语言刷新。 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

let pass = 0, fail = 0;
function ok(cond, name, extra) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (extra ? ' —— ' + extra : '')); }
}

/* ---- 迷你 DOM 桩 ---- */
class FakeEl {
  constructor(tag) {
    this.tagName = tag; this.children = []; this.className = '';
    this._text = ''; this.dataset = {}; this.attrs = {};
    this.hidden = false; this.parentNode = null; this.style = {};
  }
  appendChild(c) { c.parentNode = this; this.children.push(c); return c; }
  get textContent() { return this._text; }
  set textContent(v) { this._text = String(v); }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return this.attrs[k]; }
  remove() {
    if (this.parentNode) {
      const i = this.parentNode.children.indexOf(this);
      if (i >= 0) this.parentNode.children.splice(i, 1);
    }
  }
  removeChild(c) {
    const i = this.children.indexOf(c);
    if (i >= 0) this.children.splice(i, 1);
    c.parentNode = null;
    return c;
  }
  get firstChild() { return this.children.length ? this.children[0] : null; }
  querySelector(sel) {
    const m = sel.startsWith('.');
    const want = m ? sel.slice(1) : null;
    for (const c of this.children) {
      if (m && String(c.className).split(' ').indexOf(want) >= 0) return c;
    }
    return null;
  }
}
const ids = {};
['netState', 'netStateText', 'netTotalRecv', 'netTotalSent', 'netTotalAcc', 'netTotalScope', 'netIfs', 'netEmpty',
 'netToday', 'netMonth', 'netBarsDays', 'netBarsMonths', 'netHistEmpty',
 'netConnBody', 'netConnEmpty', 'netConnHint'].forEach((id) => { ids[id] = new FakeEl('div'); });
const pageEl = new FakeEl('section');
pageEl.hidden = true;

const documentStub = {
  getElementById: (id) => ids[id] || null,
  createElement: (tag) => new FakeEl(tag),
  createElementNS: (ns, tag) => new FakeEl(tag),
  querySelector: (sel) => (sel === '.page[data-page="network"]' ? pageEl : null),
};

const sent = [];
const ctx = {
  document: documentStub,
  window: {},
  MutationObserver: function (cb) { ctx.__lastObserverCb = cb; this.observe = function () { }; },
  send: (m) => sent.push(m),
  t: (k, fb) => (fb != null ? fb : k),
  fmtBytes: (b) => { const n = Number(b); if (!(n > 0)) return ''; const u = ['B', 'KB', 'MB', 'GB']; let n2 = n, i = 0; while (n2 >= 1024 && i < u.length - 1) { n2 /= 1024; i += 1; } return (i === 0 ? String(Math.round(n2)) : n2.toFixed(1)) + ' ' + u[i]; },
  console,
};
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'ui', 'js', 'network.js'), 'utf8'), ctx, { filename: 'network.js' });

const P = ctx.window.PerfNetwork;
ok(!!P, 'window.PerfNetwork 已暴露');

/* ---- 样本 1：三块网卡（Wi-Fi 有速率、以太网有速率、VPN 有速率） ---- */
const s1 = {
  type: 'netSample',
  sample: {
    at: '2026-11-23 18:30:00',
    ifs: [
      { ifIndex: 5, name: 'WLAN', desc: 'Intel Wi-Fi', kind: 'wifi', status: 'Up', linkSpeed: '866.7 Mbps', recvBps: 1546, sentBps: 300, recvTotal: 1000, sentTotal: 200 },
      { ifIndex: 20, name: '以太网', desc: 'Realtek', kind: 'ethernet', status: 'Up', linkSpeed: '1 Gbps', recvBps: 1024, sentBps: 100, recvTotal: 500, sentTotal: 50 },
      { ifIndex: 12, name: 'Radmin VPN', desc: 'Radmin', kind: 'virtual', status: 'Up', linkSpeed: '100 Mbps', recvBps: 800, sentBps: 40, recvTotal: 999, sentTotal: 99 }
    ]
  }
};
P.handle(s1);

const cards = ids.netIfs.children;
ok(cards.length === 3, '三块网卡三张卡', '实际 ' + cards.length);
ok(ids.netEmpty.hidden === true, '有数据时空状态隐藏');
ok(ids.netTotalRecv.textContent === '2.5 KB/s', '下行合计只算物理接口（1546+1024=2570 → 2.5 KB/s）', '实际 ' + ids.netTotalRecv.textContent);
ok(ids.netTotalSent.textContent === '400 B/s', '上行合计不含虚拟网卡', '实际 ' + ids.netTotalSent.textContent);
const wifiCard = cards.find((c) => c.children[0].children[0].textContent === 'WLAN');
ok(!!wifiCard, '找到 WLAN 卡');
ok(wifiCard.children[0].children[1].dataset.kind === 'wifi', 'Wi-Fi 徽标 data-kind=wifi');
ok(wifiCard.children[1].children[0].children[1].textContent === '1.5 KB/s', 'WLAN 下行 1546 B/s → 1.5 KB/s', '实际 ' + wifiCard.children[1].children[0].children[1].textContent);
ok(wifiCard.children[2].children[0].attrs['d'].length > 0, '下行曲线 path 已生成');
ok(wifiCard.children[2].children[1].attrs['d'].length > 0, '上行曲线 path 已生成');
ok(wifiCard.children[3].textContent.indexOf('1000') >= 0, '累计行含收发总量');
const vpnCard = cards.find((c) => c.children[0].children[0].textContent === 'Radmin VPN');
ok(vpnCard.children[0].children[1].dataset.kind === 'virtual', 'VPN 徽标 data-kind=virtual');

/* ---- 稳定排序：有速率在前按吞吐降序；首卡应为 WLAN（1874 > 1124 > 840） ---- */
ok(cards[0] === wifiCard, '排序：吞吐最大的 Wi-Fi 排第一');

/* ---- 样本 2：计数器回退 → 该秒不造数 ---- */
P.handle({
  type: 'netSample',
  sample: { at: 'x', ifs: [
    { ifIndex: 5, name: 'WLAN', kind: 'wifi', status: 'Up', recvBps: null, sentBps: null, recvTotal: 10, sentTotal: 5 },
    { ifIndex: 20, name: '以太网', kind: 'ethernet', status: 'Up', recvBps: 0, sentBps: 0, recvTotal: 500, sentTotal: 50 },
    { ifIndex: 12, name: 'Radmin VPN', kind: 'virtual', status: 'Up', recvBps: 0, sentBps: 0, recvTotal: 999, sentTotal: 99 }
  ] }
});
const wifi2 = ids.netIfs.children.find((c) => c.children[0].children[0].textContent === 'WLAN');
ok(wifi2.children[1].children[0].children[1].textContent === '—', '计数器回退时速率显示「—」不造数', '实际 ' + wifi2.children[1].children[0].children[1].textContent);

/* ---- 样本 3：以太网消失 → 行被清掉 ---- */
P.handle({
  type: 'netSample',
  sample: { at: 'x', ifs: [
    { ifIndex: 5, name: 'WLAN', kind: 'wifi', status: 'Up', recvBps: 100, sentBps: 10, recvTotal: 500, sentTotal: 50 },
    { ifIndex: 12, name: 'Radmin VPN', kind: 'virtual', status: 'Up', recvBps: 0, sentBps: 0, recvTotal: 999, sentTotal: 99 }
  ] }
});
ok(ids.netIfs.children.length === 2, '接口消失后卡片被清理', '实际 ' + ids.netIfs.children.length);

/* ---- 空样本：显示空状态 ---- */
P.handle({ type: 'netSample', sample: { at: 'x', ifs: [] } });
ok(ids.netEmpty.hidden === false, '无网卡时显示空状态');
ok(ids.netIfs.children.length === 0, '空样本清空列表');

/* ---- netCaps 驱动状态徽标 ---- */
P.handle({ type: 'netCaps', caps: { running: true } });
ok(ids.netState.dataset.state === 'on', 'netCaps.running=true → 状态徽标 on');
P.handle({ type: 'netCaps', caps: { running: false } });
ok(ids.netState.dataset.state === 'off', 'netCaps.running=false → 状态徽标 off');

/* ---- 进出页面自动启停 ---- */
sent.length = 0;
pageEl.hidden = false;
// 直接触发 observer 回调（桩里记录了 cb）
const obs = ctx.__lastObserverCb;
ok(typeof obs === 'function', '注册了页面显隐 observer');
obs();
ok(sent.some((m) => m.cmd === 'netStart'), '进页面发 netStart');
pageEl.hidden = true;
obs();
ok(sent.some((m) => m.cmd === 'netStop'), '离页面发 netStop');

/* ---- 持久化汇总：今日 / 本月 / 柱状图 ---- */
function mkDay(d, recv, sent) { return { d: d, recv: recv, sent: sent }; }
const totals1 = {
  today: { recv: 1024 * 100, sent: 1024 * 10 },
  month: { recv: 1024 * 1024 * 3, sent: 1024 * 1024 * 0.5 },
  days: Array.from({ length: 30 }, (_, i) => mkDay('2026-11-' + String(23 - i).padStart(2, '0'), i === 0 ? 1024 * 200 : 1024 * 50, 1024 * 5)),
  months: Array.from({ length: 12 }, (_, i) => ({ m: '2026-' + String(12 - i).padStart(2, '0'), recv: 1024 * 1024 * 30, sent: 1024 * 1024 * 3 }))
};
P.handle({ type: 'netTotals', totals: totals1 });
ok(ids.netToday.textContent === '110.0 KB', '今日 = 收+发合计（100K+10K → 110.0 KB）', '实际 ' + ids.netToday.textContent);
ok(ids.netMonth.textContent === '3.5 MB', '本月 = 3.0M + 0.5M → 3.5 MB', '实际 ' + ids.netMonth.textContent);
ok(ids.netBarsDays.children.length === 30, '近 30 天 30 根柱（实际 ' + ids.netBarsDays.children.length + '）');
ok(ids.netBarsMonths.children.length === 12, '近 12 个月 12 根柱');
const firstCol = ids.netBarsDays.children[0];
const firstBar = firstCol.children[0];
ok(!!firstBar.querySelector('.nt-bar-r') && !!firstBar.querySelector('.nt-bar-s'), '柱内含收（accent）与发（good）两段');
ok(firstCol.querySelector('.nt-bar-label').textContent.length === 5, '日柱标签为 MM-dd');
ok(ids.netHistEmpty.hidden === true, '有数据时历史空状态隐藏');
/* 全零历史 → 空状态出现 */
const zeroTotals = { today: { recv: 0, sent: 0 }, month: { recv: 0, sent: 0 },
  days: Array.from({ length: 30 }, () => mkDay('x', 0, 0)),
  months: Array.from({ length: 12 }, () => ({ m: 'y', recv: 0, sent: 0 })) };
P.handle({ type: 'netTotals', totals: zeroTotals });
ok(ids.netHistEmpty.hidden === false, '全零历史显示空状态');
P.handle({ type: 'netTotals', totals: totals1 });

/* ---- 连接/会话视图 ---- */
const conns = [
  { p: 1000, n: 'game', pr: 'TCP', la: '192.168.1.5', lp: 52300, ra: '203.0.113.9', rp: 443, st: 'ESTABLISHED', sv: 'HTTPS', hn: 'cdn.example.com' },
  { p: 4004, n: 'svchost', pr: 'UDP', la: '0.0.0.0', lp: 5353, ra: '*', rp: 0, st: '', sv: 'mDNS', hn: '' }
];
P.handle({ type: 'netSample', sample: { at: 'x', ifs: s1.sample.ifs, conns: conns, connTruncated: false } });
ok(ids.netConnBody.children.length === 2, '两条连接渲染两行', '实际 ' + ids.netConnBody.children.length);
ok(ids.netConnEmpty.hidden === true, '有连接时空状态隐藏');
const row0 = ids.netConnBody.children[0];
ok(row0.children[0].textContent === 'game', '连接行首列是进程名');
ok(row0.children[3].textContent.indexOf('cdn.example.com') >= 0, '开了反查时远程列显示主机名');
ok(row0.children[3].textContent.indexOf('203.0.113.9') >= 0, '远程列同时保留 IP');
const row1 = ids.netConnBody.children[1];
ok(row1.children[3].textContent === '—', 'UDP 远程列显示 —（无对端概念）');
ok(row1.children[4].textContent === 'mDNS', '服务推断列输出 mDNS');
const before = ids.netConnBody.children[0];
P.handle({ type: 'netSample', sample: { at: 'y', ifs: s1.sample.ifs, conns: conns, connTruncated: false } });
ok(ids.netConnBody.children[0] === before, '连接未变化时不重建 DOM');
P.handle({ type: 'netSample', sample: { at: 'z', ifs: s1.sample.ifs, conns: [], connTruncated: false } });
ok(ids.netConnEmpty.hidden === false && ids.netConnBody.children.length === 0, '无连接时显示空状态');
P.handle({ type: 'netSample', sample: { at: 'w', ifs: s1.sample.ifs, conns: conns, connTruncated: false } });

/* ---- 语言切换刷新不崩且重画 ---- */
P.handle({ type: 'netSample', sample: s1.sample });
let threw = false;
try { P.refresh(); } catch (e) { threw = true; }
ok(!threw, '语言切换 refresh() 不抛异常');

/* ---- 静态守卫 ---- */
const src = fs.readFileSync(path.join(__dirname, '..', 'ui', 'js', 'network.js'), 'utf8');
const code = src.split('\n').filter((l) => !/^\s*\/\//.test(l) && !/^\s*\*/.test(l)).join('\n');
ok(!/setInterval\s*\(/.test(code), '不用 setInterval（刷新由宿主推送驱动）');
ok(!/fetch\(|XMLHttpRequest/.test(code), '不发任何网络请求');

console.log('\n结果：' + pass + ' 通过 / ' + fail + ' 失败');
process.exit(fail ? 1 : 0);
