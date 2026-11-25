'use strict';
/* 网络页（2.1.18 · 流量监控阶段 1）
   口径：L1 接口总量 —— 每块网卡计数器（Get-NetAdapterStatistics）1 Hz 差分。
   数据全部来自宿主 netSample 推送（1 Hz），页面无 setInterval；进出页面自动启停。
   采不到的一律显示「—」，绝不把缺失画成 0（曲线里的 0 仅作绘图连续性）。 */
(function () {
  const WIN = 120;                 // 1 Hz × 120 点 ≈ 2 分钟
  const state = {
    running: false,
    lastSample: null,
    history: new Map(),            // ifIndex -> { recv: [], sent: [] }
    rows: new Map(),               // ifIndex -> { card, recvV, sentV, totV, pathR, pathS, statusEl }
    /* 2.2.6 连接视图：筛选条件与最近一次快照都留在页面状态里（1 Hz 刷新不重置） */
    conns: [],
    connTruncated: false,
    filters: { q: '', proto: '', svc: '' },
    svcSig: ''
  };

  function $(id) { return document.getElementById(id); }
  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  /* 速率格式化：bytes/s → 人类可读；null → 「—」 */
  function fmtRate(bps) {
    if (bps == null) return '—';
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    let n = bps, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
    return (i === 0 ? String(Math.round(n)) : n.toFixed(1)) + ' ' + units[i];
  }
  /* 累计字节数：util.js 的 fmtBytes 输出「1.5 KB」，null → 「—」 */
  function fmtTotal(b) {
    if (b == null) return '—';
    const s = (typeof fmtBytes === 'function') ? fmtBytes(b) : '';
    return s || '0 B';
  }

  /* SVG 折线：viewBox 0 0 100 28，与 realtime 同款 */
  function svgPath(values, max) {
    if (!values.length || !(max > 0)) return '';
    const pts = [];
    for (let i = 0; i < values.length; i++) {
      const v = values[i] == null ? 0 : values[i];
      if (v > max) { /* 截顶不外溢 */ }
      const x = (values.length === 1) ? 0 : (100 * i / (values.length - 1));
      const y = 26 - Math.min(v, max) / max * 24;
      pts.push(x.toFixed(2) + ',' + y.toFixed(2));
    }
    return 'M' + pts.join('L');
  }

  function ensureRow(ifi) {
    let row = state.rows.get(ifi.ifIndex);
    if (row) return row;
    const card = el('div', 'nt-card');
    const head = el('div', 'nt-head');
    const name = el('span', 'nt-name', ifi.name || ('if' + ifi.ifIndex));
    head.appendChild(name);
    const chip = el('span', 'nt-chip', '');
    chip.dataset.kind = ifi.kind || 'other';
    head.appendChild(chip);
    const status = el('span', 'nt-status', '');
    head.appendChild(status);
    const link = el('span', 'nt-link', ifi.linkSpeed || '');
    head.appendChild(link);
    head.appendChild(el('em', 'nt-src', 'L1'));
    card.appendChild(head);

    const rates = el('div', 'nt-rates');
    const rRecv = el('div', 'nt-rate nt-rate-recv');
    rRecv.appendChild(el('span', 'nt-dir', '↓'));
    const recvV = el('span', 'nt-v', '—');
    rRecv.appendChild(recvV);
    rates.appendChild(rRecv);
    const rSent = el('div', 'nt-rate nt-rate-sent');
    rSent.appendChild(el('span', 'nt-dir', '↑'));
    const sentV = el('span', 'nt-v', '—');
    rSent.appendChild(sentV);
    rates.appendChild(rSent);
    card.appendChild(rates);

    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('class', 'nt-spark');
    svg.setAttribute('viewBox', '0 0 100 28');
    svg.setAttribute('preserveAspectRatio', 'none');
    const pathR = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    pathR.setAttribute('class', 'nt-line nt-line-recv');
    const pathS = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    pathS.setAttribute('class', 'nt-line nt-line-sent');
    svg.appendChild(pathR); svg.appendChild(pathS);
    card.appendChild(svg);

    const totV = el('div', 'nt-totals', '');
    card.appendChild(totV);

    row = { card, chip, status, link, recvV, sentV, totV, pathR, pathS };
    state.rows.set(ifi.ifIndex, row);
    const box = $('netIfs');
    if (box) box.appendChild(card);
    return row;
  }

  function paintChip(chip, kind) {
    const key = 'net.kind.' + (kind || 'other');
    chip.textContent = t(key, kind);
  }
  function paintStatus(el2, status) {
    const key = 'net.status.' + (status || 'unknown');
    el2.textContent = t(key, status);
    el2.dataset.on = (status === 'Up') ? '1' : '0';
  }

  function renderSample(sample) {
    if (!sample || !sample.ifs) return;
    state.lastSample = sample;
    const ifs = Array.prototype.slice.call(sample.ifs);
    const empty = $('netEmpty');
    if (!ifs.length) {
      for (const [, row] of Array.from(state.rows)) row.card.remove();
      state.rows.clear(); state.history.clear();
      if (empty) empty.hidden = false;
      paintTotals(null, null, 0);
      return;
    }
    if (empty) empty.hidden = true;

    /* 稳定排序：有速率的在前，按吞吐降序 */
    const act = (x) => ((x.recvBps || 0) + (x.sentBps || 0));
    const ranked = ifs.map((x, i) => ({ x, i }))
      .sort((a, b) => act(b.x) - act(a.x) || a.i - b.i);

    const seen = new Set();
    for (const { x } of ranked) {
      seen.add(x.ifIndex);
      let h = state.history.get(x.ifIndex);
      if (!h) { h = { recv: [], sent: [] }; state.history.set(x.ifIndex, h); }
      h.recv.push(x.recvBps); h.sent.push(x.sentBps);
      if (h.recv.length > WIN) h.recv.shift();
      if (h.sent.length > WIN) h.sent.shift();

      const row = ensureRow(x);
      paintChip(row.chip, x.kind);
      paintStatus(row.status, x.status);
      row.recvV.textContent = fmtRate(x.recvBps);
      row.sentV.textContent = fmtRate(x.sentBps);
      if (x.linkSpeed) {
        row.link.textContent = x.linkSpeed;
        row.link.hidden = false;
      }
      row.totV.textContent = t('net.totals', '累计 ↓{r} · ↑{s} · 自计数器重置以来')
        .replace('{r}', fmtTotal(x.recvTotal)).replace('{s}', fmtTotal(x.sentTotal));
      const max = Math.max(1, ...h.recv.filter((v) => v != null), ...h.sent.filter((v) => v != null));
      row.pathR.setAttribute('d', svgPath(h.recv, max));
      row.pathS.setAttribute('d', svgPath(h.sent, max));
    }
    /* 接口消失：行与历史一并清掉 */
    for (const [idx, row] of Array.from(state.rows)) {
      if (!seen.has(idx)) { row.card.remove(); state.rows.delete(idx); state.history.delete(idx); }
    }
    /* 头部合计：只算物理接口（Wi-Fi / 以太网），口径见口径说明 */
    let rSum = null, sSum = null, tR = 0, tS = 0, phys = 0;
    for (const x of ifs) {
      if (x.kind !== 'wifi' && x.kind !== 'ethernet') continue;
      phys++;
      if (x.recvBps != null) rSum = (rSum || 0) + x.recvBps;
      if (x.sentBps != null) sSum = (sSum || 0) + x.sentBps;
      if (x.recvTotal != null) tR += x.recvTotal;
      if (x.sentTotal != null) tS += x.sentTotal;
    }
    paintTotals(rSum, sSum, phys, tR, tS);
  }

  function paintTotals(rSum, sSum, phys, tR, tS) {
    const rv = $('netTotalRecv'), sv = $('netTotalSent'), scope = $('netTotalScope');
    const tv = $('netTotalAcc');
    if (rv) rv.textContent = fmtRate(rSum == null ? null : rSum);
    if (sv) sv.textContent = fmtRate(sSum == null ? null : sSum);
    if (scope) scope.textContent = t('net.totalScope', '物理接口合计') + (phys ? ' · ' + phys : '');
    if (tv) tv.textContent = t('net.totalAcc', '本次累计 ↓{r} · ↑{s}')
      .replace('{r}', fmtTotal(tR == null ? null : tR)).replace('{s}', fmtTotal(tS == null ? null : tS));
  }

  function setRunning(on) {
    state.running = !!on;
    const chip = $('netState'), txt = $('netStateText');
    if (chip) chip.dataset.state = on ? 'on' : 'off';
    if (txt) txt.textContent = t(on ? 'net.stateOn' : 'net.stateOff', on ? '采样中' : '未采样');
  }

  function handle(msg) {
    if (!msg || !msg.type) return;
    if (msg.type === 'netSample') {
      if (msg.caps && typeof msg.caps.running === 'boolean') setRunning(msg.caps.running);
      renderSample(msg.sample);
      renderConns(msg.sample && msg.sample.conns, !!(msg.sample && msg.sample.connTruncated));
    } else if (msg.type === 'netCaps') {
      if (msg.caps && typeof msg.caps.running === 'boolean') setRunning(msg.caps.running);
    } else if (msg.type === 'netTotals') {
      renderTotals(msg.totals);
    }
  }

  /* ---- 持久化汇总：今日 / 本月 + 近 30 天 / 近 12 个月柱状图 ---- */
  let lastTotals = null;
  function renderTotals(t) {
    if (!t) return;
    lastTotals = t;
    const tv = $('netToday'), mv = $('netMonth');
    const tSum = (t.today ? (t.today.recv || 0) + (t.today.sent || 0) : null);
    const mSum = (t.month ? (t.month.recv || 0) + (t.month.sent || 0) : null);
    if (tv) {
      tv.textContent = fmtTotal(tSum);
      tv.title = (t.today ? '↓ ' + fmtTotal(t.today.recv) + ' · ↑ ' + fmtTotal(t.today.sent) : '');
    }
    if (mv) {
      mv.textContent = fmtTotal(mSum);
      mv.title = (t.month ? '↓ ' + fmtTotal(t.month.recv) + ' · ↑ ' + fmtTotal(t.month.sent) : '');
    }
    renderBars($('netBarsDays'), t.days, true);
    renderBars($('netBarsMonths'), t.months, false);
    const any = (t.days || []).some((x) => (x.recv || 0) + (x.sent || 0) > 0) ||
                (t.months || []).some((x) => (x.recv || 0) + (x.sent || 0) > 0);
    const he = $('netHistEmpty');
    if (he) he.hidden = any;
  }

  function renderBars(box, arr, isDays) {
    if (!box) return;
    while (box.firstChild) box.removeChild(box.firstChild);
    if (!arr || !arr.length) return;
    const max = Math.max(1, ...arr.map((x) => (x.recv || 0) + (x.sent || 0)));
    for (const x of arr) {
      const bar = el('div', 'nt-bar');
      const label = isDays ? String(x.d || '').slice(5) : String(x.m || '');
      bar.title = label + '\n↓ ' + fmtTotal(x.recv) + ' · ↑ ' + fmtTotal(x.sent);
      const r = el('span', 'nt-bar-r');
      r.style.height = Math.round((x.recv || 0) / max * 100) + '%';
      const s = el('span', 'nt-bar-s');
      s.style.height = Math.round((x.sent || 0) / max * 100) + '%';
      bar.appendChild(r); bar.appendChild(s);
      const wrap = el('div', 'nt-bar-col');
      wrap.appendChild(bar);
      wrap.appendChild(el('span', 'nt-bar-label', label));
      box.appendChild(wrap);
    }
  }

  /* ---- 历史导出（2.2.8 · 批次 B）：近 30 天按日 × 接口明细 ----
     数据来自宿主 netTotals.ifDays（date → ifIndex → {r,s}，与 days.json 日节点同构）+ meta（接口名/种类）。
     CSV 固定四列：日期、接口、收字节、发字节；JSON 与 days.json 同构，外部脚本可直接吃。
     导出走 Blob + <a download>，不经过宿主、不产生任何网络请求。 */
  function exportRows() {
    const t0 = lastTotals;
    if (!t0 || !t0.ifDays) return [];
    const meta = t0.meta || {};
    const rows = [];
    const dates = Object.keys(t0.ifDays).sort();
    for (const d of dates) {
      const node = t0.ifDays[d] || {};
      const idxArr = Object.keys(node).sort((a, b) => (Number(a) || 0) - (Number(b) || 0));
      for (const idx of idxArr) {
        const cell = node[idx] || {};
        const mi = meta[idx] || {};
        rows.push({
          d: d, idx: idx,
          name: String(mi.name || ('if' + idx)),
          recv: Number(cell.r || 0),
          sent: Number(cell.s || 0)
        });
      }
    }
    return rows;
  }

  function csvCell(v) {
    const s = String(v == null ? '' : v);
    return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }
  function buildCsv(rows) {
    const lines = ['date,interface,recv_bytes,sent_bytes'];
    for (const r of rows) lines.push([csvCell(r.d), csvCell(r.name), r.recv, r.sent].join(','));
    return lines.join('\r\n') + '\r\n';
  }
  function buildJson(rows) {
    const doc = { __meta: {} };
    const meta = (lastTotals && lastTotals.meta) || {};
    for (const idx of Object.keys(meta).sort((a, b) => (Number(a) || 0) - (Number(b) || 0))) {
      doc.__meta[idx] = { name: String(meta[idx].name || ''), kind: String(meta[idx].kind || 'other') };
    }
    for (const r of rows) {
      if (!doc[r.d]) doc[r.d] = {};
      doc[r.d][r.idx] = { r: r.recv, s: r.sent };
    }
    return JSON.stringify(doc, null, 2) + '\n';
  }

  function stamp() {
    const d = new Date();
    const p = (n) => (n < 10 ? '0' + n : String(n));
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
  }
  function download(name, text, mime) {
    try {
      const blob = new Blob([text], { type: mime });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = name; a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      /* 立即 revoke 会让部分引擎下载中断，留 2 秒再收尾 */
      setTimeout(() => { try { a.remove(); URL.revokeObjectURL(url); } catch (e) { } }, 2000);
      return true;
    } catch (e) { return false; }
  }
  function setExportNote(txt) {
    const n = $('netExportNote');
    if (n) n.textContent = txt || '';
  }
  /* sink 仅供探针注入（默认真下载），真实点击路径不受影响 */
  function doExport(kind, sink) {
    const rows = exportRows();
    if (!rows.length) { setExportNote(t('net.exportNoteEmpty', '暂无可导出的历史数据')); return false; }
    const days = new Set(rows.map((r) => r.d)).size;
    const ifs = new Set(rows.map((r) => r.idx)).size;
    const write = (typeof sink === 'function') ? sink : download;
    let ok;
    if (kind === 'json') {
      ok = write('PerfCapture-net-' + stamp() + '.json', buildJson(rows), 'application/json;charset=utf-8');
    } else {
      /* UTF-8 BOM：Excel 打开中文 / 日文接口名不乱码 */
      ok = write('PerfCapture-net-' + stamp() + '.csv', '\ufeff' + buildCsv(rows), 'text/csv;charset=utf-8');
    }
    if (!ok) { setExportNote(t('net.exportNoteFail', '导出失败，请重试')); return false; }
    setExportNote(t('net.exportNoteDone', '已导出 {n} 天 · {m} 个接口')
      .replace('{n}', String(days)).replace('{m}', String(ifs)));
    return true;
  }
  function initExportTools() {
    const c = $('netExportCsv'), j = $('netExportJson');
    if (c && c.addEventListener) c.addEventListener('click', () => doExport('csv'));
    if (j && j.addEventListener) j.addEventListener('click', () => doExport('json'));
  }
  initExportTools();

  /* 进出页面自动启停（与 realtime.js 同款 MutationObserver） */
  const page = document.querySelector('.page[data-page="network"]');
  function startSampling() { if (typeof send === 'function') send({ cmd: 'netStart' }); }
  function stopSampling() { if (typeof send === 'function') send({ cmd: 'netStop' }); }
  if (page && typeof MutationObserver === 'function') {
    const observer = new MutationObserver(() => {
      if (page.hidden) stopSampling(); else startSampling();
    });
    observer.observe(page, { attributes: true, attributeFilter: ['hidden'] });
  }

  /* ---- 连接/会话视图（L3 口径：只列「现在谁连着谁」，不计字节）----
     2.2.6 过滤与搜索：只过滤渲染层（state.conns → render），
     不碰 1 Hz 采样与宿主协议；条件保存在 state.filters，刷新不会把输入清掉。 */
  let lastConnKey = '';
  const CONN_MAX = 60;

  function connMatches(c) {
    const f = state.filters;
    if (f.proto && String(c.pr || '').toUpperCase() !== f.proto) return false;
    if (f.svc && String(c.sv || '') !== f.svc) return false;
    if (!f.q) return true;
    const hay = [
      c.n, c.pr, c.sv, c.hn, c.la, c.ra,
      (c.la != null ? String(c.la) + ':' + String(c.lp == null ? '' : c.lp) : ''),
      (c.ra != null ? String(c.ra) + ':' + String(c.rp == null ? '' : c.rp) : ''),
      String(c.lp == null ? '' : c.lp), String(c.rp == null ? '' : c.rp),
      'pid ' + String(c.p == null ? '' : c.p)
    ].join(' ').toLowerCase();
    return hay.indexOf(f.q) >= 0;
  }

  /* 服务下拉：按当前快照里真实出现过的标签生成；重建时保留用户选择 */
  function updateConnServices(list) {
    const sel = $('netConnSvc');
    if (!sel) return;
    const set = new Set();
    for (const c of list) { if (c.sv) set.add(String(c.sv)); }
    const arr = Array.from(set).sort();
    const sig = arr.join('\u0001');
    if (sig === state.svcSig) return;
    state.svcSig = sig;
    const keep = state.filters.svc;
    while (sel.firstChild) sel.removeChild(sel.firstChild);
    const all = document.createElement('option');
    all.value = '';
    all.textContent = t('net.connSvcAll', '全部服务');
    sel.appendChild(all);
    for (const s of arr) {
      const o = document.createElement('option');
      o.value = s;
      o.textContent = s;
      sel.appendChild(o);
    }
    if (keep && arr.indexOf(keep) >= 0) {
      sel.value = keep;
    } else if (keep) {
      state.filters.svc = '';
      sel.value = '';
      lastConnKey = '';
    }
  }

  function renderConns(conns, truncated) {
    const body = $('netConnBody'), empty = $('netConnEmpty'), hint = $('netConnHint');
    const noMatch = $('netConnNoMatch');
    if (!body) return;
    const list = Array.isArray(conns) ? conns : [];
    state.conns = list;
    state.connTruncated = !!truncated;
    updateConnServices(list);
    if (!list.length) {
      while (body.firstChild) body.removeChild(body.firstChild);
      if (empty) empty.hidden = false;
      if (noMatch) noMatch.hidden = true;
      if (hint) hint.textContent = '';
      lastConnKey = '';
      return;
    }
    if (empty) empty.hidden = true;
    const active = !!(state.filters.q || state.filters.proto || state.filters.svc);
    const filtered = active ? list.filter(connMatches) : list;
    /* 稳定排序：TCP 在前，按远程端口分组无意义，保持采样顺序即可 */
    const key = [state.filters.q, state.filters.proto, state.filters.svc, truncated ? '1' : '0',
      list.map((c) => [c.pr, c.p, c.lp, c.ra, c.rp, c.st, c.hn || '', c.n || '', c.sv || ''].join('|')).join('\n')
    ].join('\u0001');
    if (key === lastConnKey) return;
    lastConnKey = key;
    while (body.firstChild) body.removeChild(body.firstChild);
    const shown = filtered.slice(0, CONN_MAX);
    for (const c of shown) {
      const tr = el('tr', 'nt-conn-row');
      const name = String(c.n || '') || ('PID ' + c.p);
      tr.appendChild(el('td', '', name));
      tr.appendChild(el('td', 'nt-conn-proto', String(c.pr || '')));
      tr.appendChild(el('td', '', `${String(c.la || '')}:${c.lp != null ? c.lp : ''}`));
      const remote = (c.pr === 'UDP') ? '—' : (c.hn ? `${String(c.ra)} (${String(c.hn)})` : String(c.ra || '—'));
      tr.appendChild(el('td', '', remote));
      tr.appendChild(el('td', 'nt-conn-svc', String(c.sv || '')));
      body.appendChild(tr);
    }
    if (noMatch) noMatch.hidden = filtered.length > 0;
    if (hint) {
      if (active) {
        hint.textContent = t('net.connFiltered', '筛选后 {n} / 共 {m} 条')
          .replace('{n}', String(filtered.length)).replace('{m}', String(list.length));
      } else {
        const extra = list.length - shown.length;
        hint.textContent = (truncated || extra > 0)
          ? t('net.connTrunc', '快照最多 100 条，这里显示前 ' + shown.length + ' 条')
          : t('net.connCount', '{n} 条').replace('{n}', String(list.length));
      }
    }
  }

  /* 供输入框 / 分段按钮 / 服务下拉与探针调用 */
  function applyConnFilters(q, proto, svc) {
    state.filters.q = String(q == null ? '' : q).trim().toLowerCase();
    state.filters.proto = String(proto == null ? '' : proto).toUpperCase();
    state.filters.svc = String(svc == null ? '' : svc);
    lastConnKey = '';
    if (state.conns.length) renderConns(state.conns, state.connTruncated);
  }

  function initConnTools() {
    const q = $('netConnSearch'), pb = $('netConnProto'), sv = $('netConnSvc');
    if (q && q.addEventListener) {
      q.addEventListener('input', () => applyConnFilters(q.value, state.filters.proto, state.filters.svc));
    }
    if (pb && pb.addEventListener) {
      pb.addEventListener('click', (ev) => {
        const b = (ev.target && ev.target.closest) ? ev.target.closest('[data-proto]') : null;
        if (!b) return;
        const proto = b.getAttribute('data-proto') || '';
        if (pb.querySelectorAll) {
          Array.prototype.forEach.call(pb.querySelectorAll('[data-proto]'), (x) => {
            const on = (x === b);
            if (x.classList) x.classList.toggle('is-on', on);
            x.setAttribute('aria-pressed', on ? 'true' : 'false');
          });
        }
        applyConnFilters(state.filters.q, proto, state.filters.svc);
      });
    }
    if (sv && sv.addEventListener) {
      sv.addEventListener('change', () => applyConnFilters(state.filters.q, state.filters.proto, sv.value));
    }
  }
  initConnTools();

  /* 语言切换后重画 JS 生成的文案 */
  function refresh() {
    setRunning(state.running);
    /* JS 生成的服务下拉不依赖完整样本：先单独重建，避免某次重绘异常把它留在旧语言 */
    state.svcSig = '';
    updateConnServices(state.conns || []);
    try { if (state.lastSample) renderSample(state.lastSample); } catch (e) { }
    if (lastTotals) { try { renderTotals(lastTotals); } catch (e2) { } }
    setExportNote('');
  }

  window.PerfNetwork = {
    handle: handle, refresh: refresh, state: state, applyConnFilters: applyConnFilters,
    exportRows: exportRows, buildCsv: buildCsv, buildJson: buildJson, doExport: doExport
  };
})();
