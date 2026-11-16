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
    // 曲线/混合视图暂时隐藏（代码保留）：存过这两个值也一律回落到进度条
    if (v === 'bars') state.view = v;
    else if (v === 'chart' || v === 'mix') { state.view = 'bars'; localStorage.setItem(VIEW_KEY, 'bars'); }
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
  const COLORS = ['white', 'gray', 'green', 'yellow'];
  const LAYOUTS = ['linear'];
  const KEYS = [];
  for (let c = 65; c <= 90; c++) KEYS.push(String.fromCharCode(c));
  for (let f = 1; f <= 12; f++) KEYS.push('F' + f);

  let cfg = {
    anchor: 'tr', px: 100, py: 0, x: -1, y: -1,
    opacity: 90, fontSize: 'normal', fontColor: 'white', layout: 'linear',
    hotkey: { ctrl: true, alt: true, shift: false, key: 'M' },
    visible: false
  };
  let syncing = false;
  let timer = 0;

  const lbl = (prefix, v, fb) => tx(prefix + '.' + v, fb);
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const int = (v, fb) => { const n = parseInt(v, 10); return isNaN(n) ? fb : n; };

  const keySel = byId('ovHotKey');
  if (keySel) {
    KEYS.forEach((k) => { const o = document.createElement('option'); o.value = k; o.textContent = k; keySel.appendChild(o); });
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
    if (keySel) keySel.value = cfg.hotkey.key || 'M';
    const btn = byId('btnOverlay');
    if (btn) btn.textContent = cfg.visible ? tx('realtime.overlayOff', '关闭浮窗') : tx('realtime.overlayOn', '开启浮窗');
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
  bindPair('ovOpacity', 'ovOpacityNum', 20, 100, 'opacity');

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

  /* 宿主回报后回填（拖动改变 x/y 也会走到这里） */
  window.PerfOverlayUi = {
    sync(o) {
      if (!o) return;
      cfg = {
        anchor: o.anchor || 'custom',
        px: int(o.px, 50), py: int(o.py, 50),
        x: int(o.x, -1), y: int(o.y, -1),
        opacity: int(o.opacity, 90),
        fontSize: o.fontSize || 'normal',
        fontColor: o.fontColor || 'white',
        layout: o.layout || 'linear',
        hotkey: o.hotkey || { ctrl: true, alt: true, shift: false, key: 'M' },
        visible: !!o.visible
      };
      paint();
    }
  };

  paint();
})();
