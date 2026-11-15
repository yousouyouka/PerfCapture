/* 实时监控（1.5.0）· 三种视图：进度条 / 曲线 / 混合
   数据来自宿主 35-Metrics.ps1：'metricsCaps'（能力表）+ 'metricSample'（每秒一条）。
   采不到的字段宿主传 null，这里显示「—」，绝不画成 0。
   视图选择存 localStorage，语言切换后由 __refreshRealtime 重画。 */
(function initRealtime() {
  const cpuBox = document.getElementById('rtCpuRows');
  const gpuBox = document.getElementById('rtGpuRows');
  const page = document.querySelector('.page[data-page=realtime]');
  if (!cpuBox || !gpuBox || !page) return;

  const tx = (key, fallback) => (typeof t === 'function' ? t(key, fallback) : fallback);
  const fill = (tpl, params) => Object.keys(params).reduce((s, k) => s.split('{' + k + '}').join(params[k]), tpl);
  const clamp = (v) => (v < 0 ? 0 : v > 100 ? 100 : v);
  const VIEW_KEY = 'perf.realtime.view';
  const WINDOW = 60;             // 曲线显示最近 60 点（约 1 分钟）

  const state = {
    caps: null,
    sample: null,
    paused: false,
    running: false,
    view: 'bars',
    history: [],
    cells: []
  };
  try {
    const v = localStorage.getItem(VIEW_KEY);
    if (v === 'bars' || v === 'chart' || v === 'mix') state.view = v;
  } catch (e) { }

  // ---------- 字段表 ----------
  // maxOf: 条形/曲线上限；valueOf: 取原始值；caps: 能力表键（false=这台机器没有）；tip: 口径说明
  const FIELDS = [
    // 游戏帧率来自 PresentMon 增量统计（ETW 零注入），目标是采集页选中的进程；
    // 没选中进程 / 没提权 / 游戏不出帧时为 null → 显示「—」。
    { col: 'cpu', key: 'fps', label: 'realtime.row.fps', unit: 'FPS', digits: 1,
      maxOf: () => 240, valueOf: (s) => s.fps, caps: 'fps', tip: 'realtime.tip.fps' },
    { col: 'cpu', key: 'cpu.util', label: 'realtime.row.util', unit: '%', digits: 0,
      maxOf: () => 100, valueOf: (s) => s.cpu, warn: 80, bad: 95, caps: 'cpu' },
    { col: 'cpu', key: 'cpu.clock', label: 'realtime.row.clock', unit: 'GHz', digits: 2,
      scale: 1000, maxOf: (c) => (c && c.cpuBarMax ? c.cpuBarMax : (c && c.cpuBaseMhz ? c.cpuBaseMhz * 1.5 : 5000)),
      valueOf: (s) => s.cpuMhz, caps: 'cpuMhz', tip: 'realtime.tip.cpuClock' },
    { col: 'cpu', key: 'cpu.maxclock', label: 'realtime.row.maxclock', unit: 'GHz', digits: 2,
      scale: 1000, maxOf: (c) => (c && c.cpuBarMax ? c.cpuBarMax : (c && c.cpuBaseMhz ? c.cpuBaseMhz * 1.5 : 5000)),
      valueOf: (s) => s.cpuMhzMax, caps: 'cpuMhzMax', tip: 'realtime.tip.maxClock' },
    { col: 'cpu', key: 'cpu.temp', label: 'realtime.row.temp', unit: '°C', digits: 0,
      maxOf: () => 100, valueOf: () => null, placeholder: 'realtime.naSensor' },
    { col: 'cpu', key: 'cpu.fan', label: 'realtime.row.cpuFan', unit: 'rpm', digits: 0,
      maxOf: () => 3000, valueOf: () => null, placeholder: 'realtime.naSensor' },

    { col: 'gpu', key: 'gpu.util', label: 'realtime.row.util', unit: '%', digits: 0,
      maxOf: () => 100, valueOf: (s) => s.gpu, warn: 80, bad: 95, caps: 'gpu' },
    { col: 'gpu', key: 'gpu.clock', label: 'realtime.row.clock', unit: 'MHz', digits: 0,
      maxOf: (c) => (c && c.gpuClockMax ? c.gpuClockMax : 3000), valueOf: (s) => s.gpuClock,
      caps: 'gpuClock', tip: 'realtime.tip.gpuClock' },
    { col: 'gpu', key: 'gpu.memclock', label: 'realtime.row.memclock', unit: 'MHz', digits: 0,
      maxOf: (c) => (c && c.gpuMemClockMax ? c.gpuMemClockMax : 10000), valueOf: (s) => s.gpuMemClock,
      caps: 'gpuMemClock', tip: 'realtime.tip.memClock' },
    { col: 'gpu', key: 'gpu.temp', label: 'realtime.row.temp', unit: '°C', digits: 0,
      maxOf: () => 100, valueOf: (s) => s.gpuTemp, warn: 75, bad: 87, caps: 'gpuTemp' },
    { col: 'gpu', key: 'gpu.fan', label: 'realtime.row.fan', unit: '%', digits: 0,
      maxOf: () => 100, valueOf: (s) => s.gpuFan, caps: 'gpuFan' },
    { col: 'gpu', key: 'gpu.power', label: 'realtime.row.power', unit: 'W', digits: 1,
      maxOf: (c) => (c && c.gpuPowerMax ? c.gpuPowerMax : 150), valueOf: (s) => s.gpuPower, caps: 'gpuPower' },
    { col: 'gpu', key: 'gpu.vram', label: 'realtime.row.vram', unit: 'MB', digits: 0,
      maxOf: (c, s) => (s && s.vramTotal ? s.vramTotal : (c && c.vramTotal ? c.vramTotal : 1)),
      valueOf: (s) => s.vramUsed, pairOf: (s) => s.vramTotal, caps: 'vram' }
  ];

  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  // ---------- 悬停读数（曲线/混合视图）----------
  const tipEl = el('div', 'rt-readout');
  tipEl.hidden = true;
  page.appendChild(tipEl);

  function showReadout(f, ev) {
    const hist = state.history;
    if (!hist.length) return;
    const target = ev.currentTarget;
    const box = target.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (ev.clientX - box.left) / box.width));
    const slice = hist.slice(-WINDOW);
    const idx = Math.min(slice.length - 1, Math.round(ratio * (slice.length - 1)));
    const s = slice[idx];
    const v = s && f.valueOf ? f.valueOf(s) : null;
    if (v == null) return;
    const shown = f.scale ? v / f.scale : v;
    const unit = f.unit;
    tipEl.textContent = fill(tx('realtime.readout', '{time}  {value}'), {
      time: (s.at || '').slice(11, 19),
      value: shown.toFixed(f.digits || 0) + ' ' + unit
    });
    const rect = page.getBoundingClientRect();
    tipEl.style.left = Math.round(ev.clientX - rect.left + 10) + 'px';
    tipEl.style.top = Math.round(ev.clientY - rect.top + 12) + 'px';
    tipEl.hidden = false;
  }
  function hideReadout() { tipEl.hidden = true; }

  // ---------- 渲染 ----------
  function svgPath(values, max) {
    if (!values.length) return '';
    const n = Math.max(1, values.length - 1);
    let d = '';
    values.forEach((v, i) => {
      const x = (i / n) * 100;
      const y = 28 - clamp((v / max) * 100) / 100 * 26 - 1;
      d += (i ? ' L' : 'M') + x.toFixed(2) + ' ' + y.toFixed(2);
    });
    return d;
  }

  function build() {
    const cpuTitle = document.getElementById('rtCpuName');
    const gpuTitle = document.getElementById('rtGpuName');
    if (cpuTitle) cpuTitle.textContent = state.caps && state.caps.cpuName ? state.caps.cpuName : '';
    if (gpuTitle) gpuTitle.textContent = state.caps && state.caps.gpuName ? state.caps.gpuName : '';

    cpuBox.innerHTML = '';
    gpuBox.innerHTML = '';
    document.querySelectorAll('.rt-views button').forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.view === state.view));
    });

    state.cells = FIELDS.map((f) => {
      const row = el('div', 'rt-row');
      row.dataset.metric = f.key;
      row.dataset.view = state.view;
      const label = el('span', 'rt-label', tx(f.label, f.label));
      const visual = el('span', 'rt-visual');
      const bar = el('span', 'rt-track');
      const barFill = el('span', 'rt-fill');
      bar.appendChild(barFill);
      const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('class', 'rt-spark');
      svg.setAttribute('viewBox', '0 0 100 28');
      svg.setAttribute('preserveAspectRatio', 'none');
      const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('class', 'rt-spark-line');
      svg.appendChild(path);
      visual.appendChild(bar);
      visual.appendChild(svg);
      const value = el('span', 'rt-value');
      row.appendChild(label);
      row.appendChild(visual);
      row.appendChild(value);
      if (state.view !== 'bars') {
        visual.addEventListener('mousemove', (ev) => showReadout(f, ev));
        visual.addEventListener('mouseleave', hideReadout);
      }
      (f.col === 'cpu' ? cpuBox : gpuBox).appendChild(row);
      return { f, row, barFill, path, value };
    });
    paint();
  }

  function levelOf(f, v, max) {
    if (f.warn == null) return 'ok';
    const pct = (v / max) * 100;
    if (pct >= (f.bad != null ? f.bad : 100)) return 'bad';
    if (pct >= f.warn) return 'warn';
    return 'ok';
  }

  function paint() {
    const caps = state.caps || {};
    const s = state.sample;
    const slice = state.history.slice(-WINDOW);
    state.cells.forEach(({ f, row, barFill, path, value }) => {
      let v = null;
      if (s && typeof f.valueOf === 'function') {
        try { v = f.valueOf(s); } catch (e) { v = null; }
      }
      const known = caps[f.caps];
      const available = v !== null && v !== undefined && known !== false && !f.placeholder;

      row.classList.toggle('is-na', !available);
      if (!available) {
        barFill.style.width = '0%';
        barFill.dataset.level = 'ok';
        path.setAttribute('d', '');
        value.textContent = '—';
        row.title = tx(f.placeholder || 'realtime.naHint', '');
        return;
      }
      row.title = f.tip ? tx(f.tip, '') : '';
      const max = Math.max(1, Number(f.maxOf(caps, s)) || 1);
      barFill.style.width = clamp((v / max) * 100).toFixed(1) + '%';
      barFill.dataset.level = levelOf(f, v, max);

      if (state.view !== 'bars') {
        const vals = slice
          .map((sm) => { try { return f.valueOf(sm); } catch (e) { return null; } })
          .map((x) => (x == null ? null : x))
          .filter((x) => x !== null);
        path.setAttribute('d', svgPath(vals, max));
        path.dataset.level = levelOf(f, v, max);
      }

      const shown = f.scale ? v / f.scale : v;
      let text = shown.toFixed(f.digits || 0) + ' ' + f.unit;
      if (typeof f.pairOf === 'function') {
        text = Math.round(v) + ' / ' + Math.round(f.pairOf(s)) + ' ' + f.unit;
      }
      value.textContent = text;
    });
  }

  // ---------- 采样开关 ----------
  function isVisible() { return page && !page.hidden; }

  function setBadge(stateName, text) {
    const badge = document.getElementById('rtState');
    const label = document.getElementById('rtStateText');
    if (badge) badge.dataset.state = stateName;
    if (label) label.textContent = text;
    const btn = document.getElementById('rtToggle');
    if (btn) btn.textContent = state.paused ? tx('realtime.resume', '继续') : tx('realtime.pause', '暂停');
  }

  function setRunning(on) {
    state.running = !!on;
    if (state.paused) { setBadge('paused', tx('realtime.statePaused', '已暂停')); return; }
    setBadge(on ? 'on' : 'off', on ? tx('realtime.stateOn', '采样中') : tx('realtime.stateOff', '未采样'));
  }

  function startSampling() {
    state.paused = false;
    if (typeof send === 'function') send({ cmd: 'metricsStart' });
    setBadge('wait', tx('realtime.stateWait', '启动中'));
  }
  function stopSampling() {
    if (typeof send === 'function') send({ cmd: 'metricsStop' });
    setRunning(false);
  }

  const toggle = document.getElementById('rtToggle');
  if (toggle) {
    toggle.addEventListener('click', () => {
      if (state.paused) { startSampling(); return; }
      state.paused = true;
      stopSampling();
      setRunning(false);
    });
  }

  // 视图切换
  document.querySelectorAll('.rt-views button').forEach((b) => {
    b.addEventListener('click', () => {
      const v = b.dataset.view;
      if (v === state.view) return;
      state.view = v;
      try { localStorage.setItem(VIEW_KEY, v); } catch (e) { }
      build();
    });
  });

  const observer = new MutationObserver(() => {
    if (isVisible()) { if (!state.paused) startSampling(); }
    else if (state.running) stopSampling();
  });
  observer.observe(page, { attributes: true, attributeFilter: ['hidden'] });

  // ---------- 宿主消息 ----------
  function handle(msg) {
    if (!msg) return;
    if (msg.caps) {
      const first = !state.caps;
      state.caps = msg.caps;
      if (first) build(); else paint();
      if (msg.type === 'metricsCaps') setRunning(!!msg.running);
    }
    if (msg.type === 'overlayState') {
      const b = document.getElementById('btnOverlay');
      if (b) b.setAttribute('aria-pressed', String(!!msg.visible));
      return;
    }
    if (msg.type === 'metricSample' && msg.sample) {
      state.sample = msg.sample;
      state.history.push(msg.sample);
      const cap = (state.caps && state.caps.ringSize) || 120;
      while (state.history.length > Math.max(cap, WINDOW)) state.history.shift();
      if (!state.cells.length) build(); else paint();
      setRunning(true);
    }
  }

  const overlayBtn = document.getElementById('btnOverlay');
  if (overlayBtn) {
    overlayBtn.addEventListener('click', () => { if (typeof send === 'function') send({ cmd: 'overlayToggle' }); });
  }

  window.PerfRealtime = { handle, refresh: () => { build(); }, state };
  window.__refreshRealtime = () => { build(); };

  build();
  if (isVisible()) startSampling(); else setRunning(false);
})();
