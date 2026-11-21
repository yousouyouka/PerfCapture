/* 实时监控（1.5.0）· 三种视图：进度条 / 曲线 / 混合
   数据来自宿主 35-Metrics.ps1：'metricsCaps'（能力表）+ 'metricSample'（每秒一条）。
   采不到的字段宿主传 null，这里显示「—」，绝不画成 0。
   视图选择存 localStorage，语言切换后由 __refreshRealtime 重画。 */
(function initRealtime() {
  const cpuBox = document.getElementById('rtCpuRows');
  const gpuBox = document.getElementById('rtGpuRows');
  const fpsBox = document.getElementById('rtFpsRows');
  const page = document.querySelector('.page[data-page=realtime]');
  if (!cpuBox || !gpuBox || !fpsBox || !page) return;

  const tx = (key, fallback) => (typeof t === 'function' ? t(key, fallback) : fallback);
  const fill = (tpl, params) => Object.keys(params).reduce((s, k) => s.split('{' + k + '}').join(params[k]), tpl);
  const clamp = (v) => (v < 0 ? 0 : v > 100 ? 100 : v);
  const VIEW_KEY = 'perf.realtime.view';
  let WINDOW = 60;               // 曲线显示最近 N 个采样点；收到 caps 后按 ringSize/2 自适应（4 Hz 下 = 240 点 ≈ 1 分钟）

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
    // 曲线/混合视图暂时隐藏（代码保留）：存过这两个值也一律回落到进度条
    if (v === 'bars') state.view = v;
    else if (v === 'chart' || v === 'mix') { state.view = 'bars'; localStorage.setItem(VIEW_KEY, 'bars'); }
  } catch (e) { }

  // ---------- 字段表 ----------
  // maxOf: 条形/曲线上限；valueOf: 取原始值；caps: 能力表键（false=这台机器没有）；tip: 口径说明
  const FIELDS = [
    // 游戏帧率（PresentMon burst：2 秒窗口，进程退出后解析）——独立成一板，不再混进 CPU 列。
    // 没选中进程 / 未提权 / 游戏不出帧时宿主给 null → 显示「—」。
    { col: 'fps', key: 'fps', label: 'realtime.row.fps', unit: 'FPS', digits: 1,
      maxOf: (c) => (c && c.fpsMax ? c.fpsMax : 240), valueOf: (s) => s.fps, caps: 'fps',
      tip: 'realtime.tip.fps' },

    // 以下遥测：每次采样一条（CPU / GPU / 内存），由宿主 35-Metrics.ps1 提供。
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
      valueOf: (s) => s.vramUsed, pairOf: (s) => s.vramTotal, caps: 'vram' },
    // 内存占用：宿主采样里一直有 ramUsed/ramTotal，之前没上屏
    { col: 'mem', key: 'ram', label: 'realtime.row.ram', unit: '%', digits: 0,
      maxOf: () => 100, tip: 'realtime.tip.ram', caps: 'ram',
      valueOf: (s) => (s && s.ramTotal ? Math.round((s.ramUsed / s.ramTotal) * 1000) / 10 : null) }
  ];

  /* 指标勾选（批次 B）：按组渲染勾选框，选择存 localStorage，页面与浮窗共用同一份 */
  const METRICS_KEY = 'perf.realtime.metrics';
  const GROUP_ORDER = ['fps', 'cpu', 'gpu', 'mem'];
  const groupOf = (f) => (f.key === 'fps' ? 'fps' : f.col === 'cpu' ? 'cpu' : f.col === 'gpu' ? 'gpu' : 'mem');
  const allKeys = FIELDS.map((f) => f.key);
  const readSelection = () => {
    try {
      const raw = localStorage.getItem(METRICS_KEY);
      if (!raw) return allKeys.slice();
      const arr = JSON.parse(raw);
      if (!Array.isArray(arr)) return allKeys.slice();
      const keep = arr.filter((k) => allKeys.indexOf(k) >= 0);
      return keep.length ? keep : allKeys.slice();
    } catch (e) { return allKeys.slice(); }
  };
  const selected = { keys: readSelection() };
  const saveSelection = () => {
    try { localStorage.setItem(METRICS_KEY, JSON.stringify(selected.keys)); } catch (e) { }
  };
  /* 浮窗只按「指标族」显示（FPS / CPU / GPU / 内存），这里把细项折算成族 */
  const familiesForOverlay = () => {
    const set = {};
    FIELDS.forEach((f) => { if (selected.keys.indexOf(f.key) >= 0) set[groupOf(f)] = true; });
    return GROUP_ORDER.filter((g) => set[g]);
  };

  /* ---------- 指标勾选（批次 B）----------
     按「帧率 / CPU / GPU / 内存」四族分组渲染勾选框：
       · 页面按细项过滤（取消勾选就少一行）
       · 浮窗按族跟随（这一族里任意一项勾着那族就显示），这里 dispatch 给下面的浮窗设置板块
       · 选择存 localStorage，页面与浮窗共用同一份 */
  const GROUP_NAME = {
    fps: ['realtime.group.fps', '帧率'],
    cpu: ['realtime.group.cpu', 'CPU'],
    gpu: ['realtime.group.gpu', 'GPU'],
    mem: ['realtime.group.mem', '内存']
  };
  let hintTimer = 0;

  /* 至少留一项：全取消时还原勾选并短提示 */
  function flashMetricsHint() {
    const hint = document.getElementById('rtMetricsHint');
    if (!hint) return;
    if (hint.getAttribute('data-orig') == null) hint.setAttribute('data-orig', hint.textContent);
    hint.textContent = tx('realtime.metrics.last', '至少要保留一项指标');
    hint.dataset.warn = '1';
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => {
      hint.dataset.warn = '';
      hint.textContent = hint.getAttribute('data-orig') || '';
    }, 1800);
  }

  function announceMetrics() {
    try {
      document.dispatchEvent(new CustomEvent('perf:metrics', { detail: { metrics: familiesForOverlay() } }));
    } catch (e) { }
  }

  function renderMetricsChoices() {
    const box = document.getElementById('rtMetrics');
    if (!box) return;
    box.innerHTML = '';
    GROUP_ORDER.forEach((g) => {
      const list = FIELDS.filter((f) => groupOf(f) === g);
      if (!list.length) return;
      const group = el('div', 'rt-metric-group');
      const name = GROUP_NAME[g] || [g, g];
      group.appendChild(el('span', 'rt-metric-name', tx(name[0], name[1])));
      const items = el('span', 'rt-metric-items');
      list.forEach((f) => {
        const lab = el('label', 'rt-chk');
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.value = f.key;
        cb.checked = selected.keys.indexOf(f.key) >= 0;
        cb.addEventListener('change', () => {
          if (cb.checked) {
            if (selected.keys.indexOf(f.key) < 0) selected.keys.push(f.key);
          } else {
            const next = selected.keys.filter((k) => k !== f.key);
            if (!next.length) { cb.checked = true; flashMetricsHint(); return; }
            selected.keys = next;
          }
          saveSelection();
          build();
          announceMetrics();
        });
        lab.appendChild(cb);
        lab.appendChild(el('span', null, tx(f.label, f.label)));
        items.appendChild(lab);
      });
      group.appendChild(items);
      box.appendChild(group);
    });
  }

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
    fpsBox.innerHTML = '';
    document.querySelectorAll('.rt-views button').forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.view === state.view));
    });

    state.cells = FIELDS.filter((f) => selected.keys.indexOf(f.key) >= 0).map((f) => {
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
      // 内存行归到 CPU 列（系统类指标），避免再加一列
      // 帧率独立成板，不归入 CPU / GPU 列
      if (f.col === 'fps') fpsBox.appendChild(row);
      else if (f.col === 'gpu') gpuBox.appendChild(row);
      else cpuBox.appendChild(row);
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
      const tEl = document.getElementById('rtFpsTarget');
      if (tEl) {
        const tn = msg.caps.fpsTarget || '';
        tEl.textContent = tn ? tn : tx('realtime.fpsTargetNone', '未锁定（跟随前台应用）');
      }
      if (!msg.caps.fps) {
        const b2 = document.getElementById('btnOverlay');
        if (b2) b2.title = tx('realtime.fpsUnavailable', '当前抓不到帧：可在设置页看日志里的失败原因');
      }
      if (msg.type === 'metricsCaps') setRunning(!!msg.running);
    }
    if (msg.type === 'overlayState') {
      const b = document.getElementById('btnOverlay');
      if (b) {
        b.setAttribute('aria-pressed', String(!!msg.visible));
        b.textContent = msg.visible ? tx('realtime.overlayOff', '关闭浮窗') : tx('realtime.overlayOn', '开启浮窗');
      }
      if (window.PerfOverlayUi && msg.overlay) window.PerfOverlayUi.sync(msg.overlay);
      return;
    }
    if (msg.type === 'metricSample' && msg.sample) {
      /* FPS 现场：出问题时把原因挂到帧率板副标题上，别让人对着一个旧数字猜 */
      const noteEl = document.getElementById('rtFpsNote');
      if (noteEl) {
        const bad = msg.sample.fpsErr;
        if (bad) {
          noteEl.textContent = '⚠ ' + String(bad).slice(0, 60);
          noteEl.title = bad;
          noteEl.dataset.warn = '1';
        } else {
          noteEl.textContent = tx('realtime.fpsNote', 'PresentMon · 2 秒窗口');
          noteEl.title = '';
          noteEl.dataset.warn = '';
        }
      }
      state.sample = msg.sample;
      state.history.push(msg.sample);
      const cap = (state.caps && state.caps.ringSize) || 120;
      // 推送频率变了（2.0.25 起 4 Hz），窗口点数要跟着走，否则曲线只剩十几秒
      const win = Math.max(60, Math.round(cap / 2));
      if (win !== WINDOW) WINDOW = win;
      while (state.history.length > Math.max(cap, WINDOW)) state.history.shift();
      if (!state.cells.length) build(); else paint();
      setRunning(true);
    }
  }

  const overlayBtn = document.getElementById('btnOverlay');
  if (overlayBtn) {
    overlayBtn.addEventListener('click', () => { if (typeof send === 'function') send({ cmd: 'overlayToggle' }); });
  }

  window.PerfRealtime = { handle, refresh: () => { build(); }, families: familiesForOverlay, metrics: selected, state };
  window.__refreshRealtime = () => { renderMetricsChoices(); build(); };

  renderMetricsChoices();
  if (isVisible()) startSampling(); else setRunning(false);
})();

/* ── 顶部两块板块（可收起）+ 浮窗设置（批次 A）──
   浮窗参数统一存宿主配置 overlay.*（浮窗本体与界面共用一套）；改一项就下发 overlayConfig，
   宿主应用后回 overlayState，界面再回填，保证拖窗后坐标也会同步。 */
(function initRealtimeBoards() {
  const tx = (k, fb) => (typeof t === 'function' ? t(k, fb) : fb);
  const byId = (id) => document.getElementById(id);

  /* 1) 折叠：状态存 localStorage，默认「监控设置」展开、「浮窗设置」收起 */
  document.querySelectorAll('.rt-board-head').forEach((head) => {
    const body = head.parentElement.querySelector('.rt-board-body');
    if (!body) return;
    const key = 'perf.realtime.board.' + head.dataset.board;
    let open = head.getAttribute('aria-expanded') === 'true';
    try {
      const v = localStorage.getItem(key);
      if (v === '1') open = true; else if (v === '0') open = false;
    } catch (e) { }
    const apply = () => { head.setAttribute('aria-expanded', String(open)); body.hidden = !open; };
    apply();
    head.addEventListener('click', () => {
      open = !open; apply();
      try { localStorage.setItem(key, open ? '1' : '0'); } catch (e) { }
    });
  });

  /* 2) 浮窗设置 */
  const ANCHORS = ['tl', 't', 'tr', 'l', 'c', 'r', 'bl', 'b', 'br'];
  const SIZES = ['small', 'normal', 'large'];
  const COLORS = ['white', 'green', 'red', 'blue'];
  const LAYOUTS = ['stacked', 'linear'];
  /* 宿主没下发清单时的兜底（正常由 overlayState.itemKeys / itemLocked 下发） */
  const FALLBACK_ITEMS = ['fps', 'fpslow', 'rlat', 'pcl', 'gpuutil', 'gputemp', 'gpuclock', 'gpupower',
    'gpufan', 'vramclk', 'gpuvolt', 'cpuutil', 'cpuclock', 'cpupower', 'cputemp', 'ram'];
  const FALLBACK_LOCKED = ['gpuvolt', 'cputemp'];
  const KEYS = [];
  for (let c = 65; c <= 90; c++) KEYS.push(String.fromCharCode(c));
  for (let f = 1; f <= 12; f++) KEYS.push('F' + f);

  /* 浮窗显示项：逐项勾选，独立于页面「监控设置」的族勾选（两套各管各的） */
  let itemKeys = FALLBACK_ITEMS.slice();
  /* 本机拿不到、界面上灰掉的项（宿主下发 itemLocked） */
  let lockedKeys = FALLBACK_LOCKED.slice();

  let cfg = {
    anchor: 'tr', px: 100, py: 0, x: -1, y: -1,
    opacity: 0, fontSize: 'normal', fontColor: 'white', layout: 'linear',
    locked: false,
    hotkey: { ctrl: true, alt: true, shift: false, key: 'M' },
    items: ['fps', 'gpuutil', 'gputemp', 'gpupower', 'ram'],
    visible: false
  };
  let syncing = false;
  let timer = 0;


  /* 勾选变了：直接改 cfg 并立刻下发（勾完就该看到浮窗变，不等防抖） */
  /* 2.0.18：浮窗显示项改成独立的一份，不再跟随页面「监控设置」的族勾选。
     否则在页面上关掉一项，会把浮窗里整族一起关掉，与「逐项自由开关」冲突。 */
  let itemsHintTimer = 0;
  function flashItemsHint() {
    const hint = byId('ovItemsHint');
    if (!hint) return;
    if (hint.getAttribute('data-orig') == null) hint.setAttribute('data-orig', hint.textContent);
    hint.textContent = tx('realtime.set.itemsLast', '至少要保留一项');
    hint.dataset.warn = '1';
    clearTimeout(itemsHintTimer);
    itemsHintTimer = setTimeout(() => {
      hint.dataset.warn = '';
      hint.textContent = hint.getAttribute('data-orig') || '';
    }, 1800);
  }

  const lbl = (prefix, v, fb) => tx(prefix + '.' + v, fb);
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const int = (v, fb) => { const n = parseInt(v, 10); return isNaN(n) ? fb : n; };

  const keySel = byId('ovHotKey');
  if (keySel) {
    KEYS.forEach((k) => { const o = document.createElement('option'); o.value = k; o.textContent = k; keySel.appendChild(o); });
  }
  /* 显示内容：按宿主下发的 itemKeys 渲染逐项勾选（名字走 i18n，缺键回退键名） */
  function renderItemChoices(keys) {
    const box = byId('ovItems');
    if (!box) return;
    itemKeys = (Array.isArray(keys) && keys.length) ? keys.slice() : FALLBACK_ITEMS.slice();
    box.innerHTML = '';
    itemKeys.forEach((k) => {
      const isLocked = lockedKeys.indexOf(k) >= 0;
      const lab = document.createElement('label');
      lab.className = 'rt-chk';
      if (isLocked) lab.classList.add('is-locked');
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.value = k;
      /* 本机采不到的项：灰掉、不可勾选（不是勾上再显示 N/A） */
      cb.disabled = isLocked;
      cb.checked = !isLocked && (cfg.items || []).indexOf(k) >= 0;
      if (isLocked) lab.title = tx('realtime.set.itemLocked', '本机采不到这一项，不能勾选');
      cb.addEventListener('change', () => {
        const cur = (cfg.items || []).slice();
        const i = cur.indexOf(k);
        if (cb.checked) { if (i < 0) cur.push(k); }
        else if (i >= 0) { cur.splice(i, 1); }
        /* 不许全关：浮窗会变成一块空白，比不显示更糟 */
        if (!cur.length) { cb.checked = true; flashItemsHint(); return; }
        /* 按 itemKeys 的顺序归一，避免勾选顺序影响浮窗里的排列 */
        cfg.items = itemKeys.filter((x) => cur.indexOf(x) >= 0);
        push(0);
      });
      const span = document.createElement('span');
      /* 挂 data-i18n：切语言时由 applyI18n 统一换掉，否则这里会停在旧语言 */
      span.dataset.i18n = 'overlay.item.' + k;
      span.textContent = tx('overlay.item.' + k, k);
      lab.append(cb, span);
      box.appendChild(lab);
    });
  }

  function paintItems() {
    const box = byId('ovItems');
    if (!box) return;
    const sel = cfg.items || [];
    box.querySelectorAll('input[type=checkbox]').forEach((cb) => {
      cb.checked = sel.indexOf(cb.value) >= 0;
    });
  }

  function paint() {
    syncing = true;
    const set = (id, v) => { const el = byId(id); if (el) el.textContent = v; };
    set('ovAnchor', lbl('realtime.anchor', cfg.anchor, cfg.anchor));
    set('ovLayout', lbl('realtime.layout', cfg.layout, '线性'));
    set('ovFontSize', lbl('realtime.size', cfg.fontSize, '标准'));
    set('ovFontColor', lbl('realtime.color', cfg.fontColor, '白色'));
    const px = byId('ovPosX'); if (px) px.value = cfg.px;
    const pxn = byId('ovPosXNum'); if (pxn) pxn.value = cfg.px;
    const py = byId('ovPosY'); if (py) py.value = cfg.py;
    const pyn = byId('ovPosYNum'); if (pyn) pyn.value = cfg.py;
    const op = byId('ovOpacity'); if (op) op.value = cfg.opacity;
    const opn = byId('ovOpacityNum'); if (opn) opn.value = cfg.opacity;
    const xEl = byId('ovPx'); if (xEl) xEl.value = cfg.x >= 0 ? cfg.x : '';
    const yEl = byId('ovPy'); if (yEl) yEl.value = cfg.y >= 0 ? cfg.y : '';
    const hc = byId('ovHotCtrl'); if (hc) hc.checked = !!cfg.hotkey.ctrl;
    const ha = byId('ovHotAlt'); if (ha) ha.checked = !!cfg.hotkey.alt;
    const hs = byId('ovHotShift'); if (hs) hs.checked = !!cfg.hotkey.shift;
    const lk = byId('ovLockDrag'); if (lk) lk.checked = !!cfg.locked;
    if (keySel) keySel.value = cfg.hotkey.key || 'M';
    const btn = byId('btnOverlay');
    if (btn) btn.textContent = cfg.visible ? tx('realtime.overlayOff', '关闭浮窗') : tx('realtime.overlayOn', '开启浮窗');
    paintItems();
    syncing = false;
  }

  function push(delay) {
    if (syncing) return;
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (typeof send === 'function') send({ cmd: 'overlayConfig', overlay: cfg });
    }, delay == null ? 120 : delay);
  }

  /* 位置/不透明度：滑杆与数字框双向联动 */
  function bindPair(sliderId, numId, lo, hi, field, after) {
    const s = byId(sliderId);
    const n = byId(numId);
    const commit = (raw) => {
      cfg[field] = clamp(int(raw, cfg[field]), lo, hi);
      if (after) after();
      paint(); push();
    };
    if (s) s.addEventListener('input', () => commit(s.value));
    if (n) n.addEventListener('change', () => commit(n.value));
  }
  bindPair('ovPosX', 'ovPosXNum', 0, 100, 'px');
  bindPair('ovPosY', 'ovPosYNum', 0, 100, 'py');
  bindPair('ovOpacity', 'ovOpacityNum', 0, 100, 'opacity');

  /* 直接指定坐标（像素）：写进去就等于「自定义」位置 */
  [['ovPx', 'x'], ['ovPy', 'y']].forEach(([id, field]) => {
    const el = byId(id);
    if (!el) return;
    el.addEventListener('change', () => {
      const v = int(el.value, -1);
      cfg[field] = v >= 0 ? v : -1;
      if (cfg.x >= 0 && cfg.y >= 0) cfg.anchor = 'custom';
      paint(); push();
    });
  });

  /* 步进器：位置预设 / 布局 / 字号 / 颜色 */
  document.querySelectorAll('.rt-step').forEach((btn) => {
    btn.addEventListener('click', () => {
      const dir = parseInt(btn.dataset.dir, 10) || 1;
      const step = btn.dataset.step;
      const cycle = (arr, cur) => arr[(arr.indexOf(cur) + dir + arr.length) % arr.length];
      if (step === 'anchor') {
        cfg.anchor = cycle(ANCHORS, cfg.anchor);
        if (cfg.anchor !== 'custom') {
          const a = cfg.anchor;
          cfg.px = a.indexOf('l') >= 0 ? 0 : a.indexOf('r') >= 0 ? 100 : 50;
          cfg.py = a.indexOf('t') >= 0 ? 0 : a.indexOf('b') >= 0 ? 100 : 50;
        }
      } else if (step === 'layout') cfg.layout = cycle(LAYOUTS, cfg.layout);
      else if (step === 'fontSize') cfg.fontSize = cycle(SIZES, cfg.fontSize);
      else if (step === 'fontColor') cfg.fontColor = cycle(COLORS, cfg.fontColor);
      else return;
      paint(); push();
    });
  });

  /* 热键 */
  ['ovHotCtrl', 'ovHotAlt', 'ovHotShift'].forEach((id, i) => {
    const el = byId(id);
    if (!el) return;
    el.addEventListener('change', () => {
      const k = ['ctrl', 'alt', 'shift'][i];
      cfg.hotkey[k] = el.checked;
      if (!cfg.hotkey.ctrl && !cfg.hotkey.alt && !cfg.hotkey.shift) cfg.hotkey.ctrl = true;
      paint(); push();
    });
  });
  if (keySel) keySel.addEventListener('change', () => { cfg.hotkey.key = keySel.value || 'M'; push(); });

  /* 拖动锁：勾上就立刻生效（0 延迟），不必等防抖——用户勾完马上会去试能不能拖 */
  const lockDragEl = byId('ovLockDrag');
  if (lockDragEl) {
    lockDragEl.addEventListener('change', () => { cfg.locked = !!lockDragEl.checked; push(0); });
  }

  /* 宿主回报后回填（拖动改变 x/y 也会走到这里） */
  window.PerfOverlayUi = {
    sync(o) {
      if (!o) return;
      cfg = {
        anchor: o.anchor || 'custom',
        px: int(o.px, 50), py: int(o.py, 50),
        x: int(o.x, -1), y: int(o.y, -1),
        opacity: int(o.opacity, 0),
        fontSize: o.fontSize || 'normal',
        fontColor: o.fontColor || 'white',
        layout: o.layout || 'linear',
        locked: !!o.locked,
        hotkey: o.hotkey || { ctrl: true, alt: true, shift: false, key: 'M' },
        items: (o.items && o.items.length) ? o.items.filter((k) => lockedKeys.indexOf(k) < 0) : ['fps', 'gpuutil', 'gputemp', 'gpupower', 'ram'],
        visible: !!o.visible
      };
      /* 宿主下发的项清单变了才重建勾选框（避免每次回填都把焦点/滚动位置重置） */
      const keys = (o.itemKeys && o.itemKeys.length) ? o.itemKeys.slice() : FALLBACK_ITEMS.slice();
      const locks = (o.itemLocked && o.itemLocked.length) ? o.itemLocked.slice() : FALLBACK_LOCKED.slice();
      const locksChanged = locks.join(',') !== lockedKeys.join(',');
      lockedKeys = locks;
      if (keys.join(',') !== itemKeys.join(',') || locksChanged) renderItemChoices(keys);
      else paintItems();
      paint();
    }
  };

  renderItemChoices(itemKeys);
  /* ---------- 目标进程选择（实时监控）----------
     不选 = 跟随当前前台窗口；选了就固定采那个进程。
     列表来自 bridge 的 procs 消息（宿主 Get-ProcessChoices），这里只读事件，不碰 state。 */
  (function initTargetPicker() {
    const sel = document.getElementById('rtTarget');
    if (!sel) return;
    let procs = [];
    let curPid = 0;

    const fill = () => {
      const keep = curPid;
      sel.innerHTML = '';
      const auto = document.createElement('option');
      auto.value = '0';
      auto.textContent = tx('realtime.target.auto', '自动（跟随前台窗口）');
      sel.appendChild(auto);
      procs.forEach((p) => {
        const o = document.createElement('option');
        o.value = String(p.pid);
        o.textContent = p.text || (p.name + ' (' + p.pid + ')');
        sel.appendChild(o);
      });
      sel.value = String(keep);
    };

    const apply = () => {
      const pid = parseInt(sel.value, 10) || 0;
      curPid = pid;
      const p = procs.find((x) => x.pid === pid);
      if (typeof send === 'function') send({ cmd: 'metricsTarget', pid: pid, name: p ? p.name : '' });
    };

    sel.addEventListener('change', apply);

    /* 刷新按钮：让宿主重新枚举进程（走已有的 refreshProcs），回包会派发 perf:procs */
    const btn = document.getElementById('btnTargetRefresh');
    if (btn) {
      let busy = 0;
      btn.addEventListener('click', () => {
        if (busy) return;
        busy = setTimeout(() => { busy = 0; btn.disabled = false; }, 700);
        btn.disabled = true;
        if (typeof send === 'function') send({ cmd: 'refreshProcs' });
      });
    }
    document.addEventListener('perf:procs', (e) => {
      procs = (e && e.detail && Array.isArray(e.detail.procs)) ? e.detail.procs : [];
      fill();
    });
    fill();
  })();

  paint();
})();
