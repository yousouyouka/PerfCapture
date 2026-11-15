/* 实时监控 · 进度条视图（1.5.0 批次 A）
   数据来自宿主 35-Metrics.ps1：'metricsCaps'（能力表）+ 'metricSample'（每秒一条）。
   本批只渲染当前值 + 进度条；环形缓冲先留在前端 history 里，批次 B 用来画折线。

   约定：采不到的字段宿主传 null，这里显示「—」，绝不画成 0。 */
(function initRealtime() {
  const cpuBox = document.getElementById('rtCpuRows');
  const gpuBox = document.getElementById('rtGpuRows');
  const page = document.querySelector('.page[data-page=realtime]');
  if (!cpuBox || !gpuBox || !page) return;

  const tx = (key, fallback) => (typeof t === 'function' ? t(key, fallback) : fallback);
  const clamp = (v) => (v < 0 ? 0 : v > 100 ? 100 : v);

  const state = {
    caps: null,
    sample: null,
    paused: false,
    running: false,
    history: [],
    cells: []
  };

  // ---------- 字段表：一条 = 一行 ----------
  // valueOf 取原始值；maxOf 取进度条上限；caps 是能力表里对应的键（false = 这台机器没有）
  const FIELDS = [
    { col: 'cpu', key: 'cpu.util', label: 'realtime.row.util', unit: '%', digits: 0,
      maxOf: () => 100, valueOf: (s) => s.cpu, warn: 80, bad: 95, caps: 'cpu' },
    { col: 'cpu', key: 'cpu.clock', label: 'realtime.row.clock', unit: 'GHz', digits: 2,
      scale: 1000, maxOf: (c) => (c && c.cpuBaseMhz ? c.cpuBaseMhz : 5000), valueOf: (s) => s.cpuMhz, caps: 'cpuMhz' },
    { col: 'cpu', key: 'cpu.temp', label: 'realtime.row.temp', unit: '°C', digits: 0,
      maxOf: () => 100, valueOf: () => null, placeholder: 'realtime.naSensor' },
    { col: 'cpu', key: 'cpu.fan', label: 'realtime.row.cpuFan', unit: 'rpm', digits: 0,
      maxOf: () => 3000, valueOf: () => null, placeholder: 'realtime.naSensor' },

    { col: 'gpu', key: 'gpu.util', label: 'realtime.row.util', unit: '%', digits: 0,
      maxOf: () => 100, valueOf: (s) => s.gpu, warn: 80, bad: 95, caps: 'gpu' },
    { col: 'gpu', key: 'gpu.clock', label: 'realtime.row.clock', unit: 'MHz', digits: 0,
      maxOf: (c) => (c && c.gpuClockMax ? c.gpuClockMax : 3000), valueOf: (s) => s.gpuClock, caps: 'gpuClock' },
    { col: 'gpu', key: 'gpu.memclock', label: 'realtime.row.memclock', unit: 'MHz', digits: 0,
      maxOf: (c) => (c && c.gpuMemClockMax ? c.gpuMemClockMax : 10000), valueOf: (s) => s.gpuMemClock, caps: 'gpuMemClock' },
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

  function build() {
    const cpuTitle = document.getElementById('rtCpuName');
    const gpuTitle = document.getElementById('rtGpuName');
    if (cpuTitle) cpuTitle.textContent = state.caps && state.caps.cpuName ? state.caps.cpuName : '';
    if (gpuTitle) gpuTitle.textContent = state.caps && state.caps.gpuName ? state.caps.gpuName : '';

    cpuBox.innerHTML = '';
    gpuBox.innerHTML = '';
    state.cells = FIELDS.map((f) => {
      const row = el('div', 'rt-row');
      row.dataset.metric = f.key;
      const label = el('span', 'rt-label', tx(f.label, f.label));
      const track = el('span', 'rt-track');
      const fill = el('span', 'rt-fill');
      track.appendChild(fill);
      const value = el('span', 'rt-value');
      row.appendChild(label);
      row.appendChild(track);
      row.appendChild(value);
      (f.col === 'cpu' ? cpuBox : gpuBox).appendChild(row);
      return { f, row, fill, value };
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
    state.cells.forEach(({ f, row, fill, value }) => {
      let v = null;
      if (s && typeof f.valueOf === 'function') {
        try { v = f.valueOf(s); } catch (e) { v = null; }
      }
      const known = caps[f.caps];
      const available = v !== null && v !== undefined && known !== false && !f.placeholder;

      row.classList.toggle('is-na', !available);
      if (!available) {
        fill.style.width = '0%';
        fill.dataset.level = 'ok';
        value.textContent = '—';
        row.title = tx(f.placeholder || 'realtime.naHint', '');
        return;
      }
      row.title = '';
      const max = Math.max(1, Number(f.maxOf(caps, s)) || 1);
      const pct = clamp((v / max) * 100);
      fill.style.width = pct.toFixed(1) + '%';
      fill.dataset.level = levelOf(f, v, max);
      const shown = f.scale ? v / f.scale : v;
      let text = shown.toFixed(f.digits || 0) + ' ' + f.unit;
      if (typeof f.pairOf === 'function') {
        const total = f.pairOf(s);
        text = Math.round(v) + ' / ' + Math.round(total) + ' ' + f.unit;
      }
      value.textContent = text;
    });
  }

  // ---------- 采样开关（进页面才采，离开就停，别空转） ----------
  function isVisible() { return page && !page.hidden; }

  // 徽标三态 + 启动中：只有真收到样本才显示「采样中」
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
    // 还没收到第一条样本：显示「启动中」，别谎报「采样中」
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
      if (first) build(); else { paint(); }
      if (msg.type === 'metricsCaps') setRunning(!!msg.running);
    }
    if (msg.type === 'metricSample' && msg.sample) {
      state.sample = msg.sample;
      state.history.push(msg.sample);
      while (state.history.length > ((state.caps && state.caps.ringSize) || 120)) state.history.shift();
      if (!state.cells.length) build(); else paint();
      setRunning(true);
    }
  }

  window.PerfRealtime = {
    handle,
    refresh: () => { build(); },
    state
  };
  window.__refreshRealtime = () => { build(); };

  build();
  if (isVisible()) startSampling(); else setRunning(false);
})();
