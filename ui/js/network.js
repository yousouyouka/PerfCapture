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
    } else if (msg.type === 'netCaps') {
      if (msg.caps && typeof msg.caps.running === 'boolean') setRunning(msg.caps.running);
    }
  }

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

  /* 语言切换后重画 JS 生成的文案 */
  function refresh() {
    setRunning(state.running);
    if (state.lastSample) renderSample(state.lastSample);
  }

  window.PerfNetwork = { handle: handle, refresh: refresh, state: state };
})();
