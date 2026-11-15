/* 报告渲染与帧时间曲线 */

/* ── 报告渲染 ── */
/**
 * 指标卡。extra 以与数值同样的字号/颜色接在数值右边（1% Low 用它显示占平均帧率的百分比）。
 */
function tile(k, v, unit, digits, extra) {
  const f = fmt(v, unit, digits);
  const tail = (extra != null && extra !== '') ? `<span class="p">${escapeHtml(String(extra))}</span>` : '';
  return `<div class="rp-tile"><div class="k">${escapeHtml(k)}</div>` +
         `<div class="v">${f.v}${f.unit ? `<small>${f.unit}</small>` : ''}${tail}</div></div>`;
}

function renderReport(r) {
  state.report = r;
  const box = $('#preview');
  if (!r) { box.innerHTML = ''; return; }

  const meta = [];
  if (r.process) meta.push(r.process);
  if (r.resolution) meta.push(String(r.resolution).replace('x', '×'));
  if (r.window_mode) meta.push(r.window_mode);
  if (r.captured_seconds != null) {
    meta.push(fillParams(t('report.meta.frames', '{s} 秒 / {n} 帧'), { s: r.captured_seconds, n: r.frames }));
  }

  let html = `<div class="rp-title">${escapeHtml(t('report.heading', '性能报告'))}</div>`;
  html += `<div class="rp-meta">${escapeHtml(meta.join('  ·  '))}</div>`;

  html += '<div class="rp-grid">';
  html += tile(t('metric.avgFps', '平均帧率'), r.avg_fps, 'FPS', 1);
  // 1% Low 右侧直接显示它占平均帧率的百分比（同字号同颜色）；判定改由引擎按"落回频率"给
  html += tile(t('metric.p1low', '1% Low'), r.fps_1pct_low, 'FPS', 1,
    r.fps_1pct_low_pct != null ? r.fps_1pct_low_pct + '%' : '');
  if (r.display_latency_avg_ms != null) html += tile(t('metric.displayLatency', '上屏延迟'), r.display_latency_avg_ms, 'ms', 1);
  if (r.pc_latency_avg_ms != null) html += tile(t('metric.pcLatency', 'PC 延迟'), r.pc_latency_avg_ms, 'ms', 1);
  if (r.avg_frametime_ms != null) html += tile(t('metric.avgFrametime', '平均帧时间'), r.avg_frametime_ms, 'ms', 2);
  if (r.frametime_p95_ms != null) html += tile(t('metric.p95Frametime', 'P95 帧时间'), r.frametime_p95_ms, 'ms', 2);
  if (r.gpu_util_avg_pct != null) html += tile(t('metric.gpuUtil', 'GPU 占用'), r.gpu_util_avg_pct, '%', 0);
  if (r.gpu_temp_max_c != null) html += tile(t('metric.gpuTemp', 'GPU 温度'), r.gpu_temp_max_c, '°C', 0);
  if (r.vram_max_mb != null) html += tile(t('metric.vramPeak', '显存峰值'), r.vram_max_mb, 'MB', 0);
  if (r.ram_max_mb != null) html += tile(t('metric.ramPeak', '内存峰值'), r.ram_max_mb, 'MB', 0);
  html += '</div>';

  if (r.verdicts && r.verdicts.length) {
    html += `<div class="rp-section">${escapeHtml(t('report.section.eval', '评估'))}</div>`;
    for (const v of r.verdicts) {
      const cls = v[0] === 'warn' ? 'warn' : v[0] === 'bad' ? 'bad' : 'good';
      html += `<div class="rp-verdict ${cls}"><i></i><span>${escapeHtml(verdictText(v))}</span></div>`;
    }
  }

  // 平铺两张图：帧率用「每桶平均帧时间」换算，每帧毫秒用「每桶最慢帧」
  // 旧报告没有 avg 字段，只画每帧毫秒图（避免把"最差帧率"当成帧率曲线误导人）
  if (r.chart && r.chart.ms && r.chart.ms.length > 2) {
    const hasAvg = r.chart.avg && r.chart.avg.length > 2;

    if (hasAvg) {
      html += `<div class="rp-chart-block">` +
              `<div class="rp-chart-title">${escapeHtml(t('report.chart.titleFps', '帧率（FPS）'))}</div>` +
              `<div class="rp-chart"><canvas id="chartFps"></canvas>` +
              `<div class="cap">${escapeHtml(chartCaption(r.chart, 'fps'))}</div></div></div>`;
    }

    html += `<div class="rp-chart-block">` +
            `<div class="rp-chart-title">${escapeHtml(t('report.chart.titleMs', '每帧毫秒（ms）'))}</div>` +
            `<div class="rp-chart"><canvas id="chartMs"></canvas>` +
            `<div class="cap">${escapeHtml(chartCaption(r.chart, 'ms'))}</div></div></div>`;

    if (!hasAvg) {
      html += `<div class="rp-chart-note">${escapeHtml(t('report.chart.noAvg', '这份报告由旧版本采集，缺少平均帧时间曲线，只显示每帧毫秒。'))}</div>`;
    }
  }

  const rows = [];
  if (r.avg_frametime_ms != null) rows.push([t('metric.ftRow', '帧时间 平均 / p95'), `${r.avg_frametime_ms} / ${r.frametime_p95_ms} ms`]);
  if (r.frametime_p999_ms != null) rows.push([t('metric.ftP999Row', '帧时间 中位 / p99.9'), `${r.frametime_median_ms} / ${r.frametime_p999_ms} ms`]);
  if (r.frametime_stddev_ms != null) rows.push([t('metric.jitterRow', '帧时间抖动 标准差 / 变异'), `${r.frametime_stddev_ms} ms / ${r.frametime_jitter_pct} %`]);
  if (r.long_frames) {
    const lf = r.long_frames;
    rows.push([t('metric.longRow', '长帧 >2× / >4× 中位 · >50 / >100 ms'),
      `${lf.over2x} / ${lf.over4x} · ${lf.over50} / ${lf.over100} 帧（${lf.pct_over2x} %）`]);
  }
  if (r.fps_1pct_low_time != null) rows.push([t('metric.lowSecRow', '1% Low（按秒口径）'), `${r.fps_1pct_low_time} FPS（占平均 ${r.fps_1pct_low_time_pct} %）`]);
  if (r.displayed_fps != null) rows.push([t('metric.displayedRow', '上屏节奏 / 重复帧'), `${r.displayed_fps} FPS / ${r.repeat_frames} 帧（${r.repeat_pct} %）`]);
  if (r.sync_interval != null || r.present_flags != null) {
    rows.push([t('metric.syncRow', '同步间隔 / 呈现标志'),
      `SyncInterval ${r.sync_interval ?? '—'} · PresentFlags ${r.present_flags ?? '—'}`]);
  }
  if (r.gpu_clock_avg_mhz != null) {
    rows.push([t('metric.gpuClockRow', 'GPU 频率 平均 / 最高'),
      `${r.gpu_clock_avg_mhz} / ${r.gpu_clock_max_mhz} MHz${r.gpu_clock_hw_max_mhz ? `（上限 ${r.gpu_clock_hw_max_mhz}）` : ''}`]);
  }
  if (r.gpu_power_avg_w != null) rows.push([t('metric.gpuPowerRow', 'GPU 功耗 平均 / 最高'), `${r.gpu_power_avg_w} / ${r.gpu_power_max_w} W`]);
  if (r.gpu_fan_avg_pct != null) rows.push([t('metric.gpuFanRow', 'GPU 风扇 平均'), `${r.gpu_fan_avg_pct} %`]);
  if (r.pcie) rows.push([t('metric.pcieRow', 'PCIe 链路'), String(r.pcie)]);
  if (r.throttle && Object.keys(r.throttle).length) {
    rows.push([t('metric.throttleRow', '降频原因'),
      Object.entries(r.throttle).map(([k, v]) => `${t('metric.throttle.' + k, k)} ${v} %`).join(' · ')]);
  }
  if (r.cpu_util_avg_pct != null) {
    rows.push([t('metric.cpuRow', 'CPU 占用 平均 / 最高'),
      `${r.cpu_util_avg_pct} / ${r.cpu_util_max_pct} %${r.cpu_max_core_avg_pct != null ? `（最高单核 ${r.cpu_max_core_avg_pct} %）` : ''}`]);
  }
  if (r.display_latency_avg_ms != null) rows.push([t('metric.latRow', '上屏延迟 平均 / p95'), `${r.display_latency_avg_ms} / ${r.display_latency_p95_ms} ms`]);
  if (r.pc_latency_avg_ms != null) rows.push([t('metric.pcRow', 'PC 延迟 平均 / p95'), `${r.pc_latency_avg_ms} / ${r.pc_latency_p95_ms} ms`]);
  if (r.gpu_temp_avg_c != null) rows.push([t('metric.gpuTempRow', 'GPU 温度 平均 / 最高'), `${r.gpu_temp_avg_c} / ${r.gpu_temp_max_c} °C`]);
  if (r.vram_avg_mb != null) rows.push([t('metric.vramRow', '显存 平均 / 最高'), `${r.vram_avg_mb} / ${r.vram_max_mb} MB`]);
  if (r.ram_avg_mb != null) rows.push([t('metric.ramRow', '内存 平均 / 最高'), `${r.ram_avg_mb} / ${r.ram_max_mb} MB`]);
  if (r.resolution) rows.push([t('metric.resRow', '分辨率 / 窗口模式'), `${String(r.resolution).replace('x', '×')} / ${r.window_mode || '—'}`]);
  if (r.foreground_pct != null) rows.push([t('metric.fgRow', '游戏前台占比'), `${r.foreground_pct} %`]);
  if (r.features) {
    for (const f of r.features) {
      rows.push([trKey(f[0]), trKey(f[1])]);   // 引擎给的是 key；旧报告是中文原文，原样返回
    }
  }

  if (rows.length) {
    html += `<div class="rp-section">${escapeHtml(t('report.section.details', '详细数据'))}</div><div class="rp-rows">`;
    html += rows.map(([k, v]) => `<div class="row"><span class="k">${escapeHtml(k)}</span><span class="v">${escapeHtml(v)}</span></div>`).join('');
    html += '</div>';
  }

  box.innerHTML = html;

  if (r.chart && r.chart.ms && r.chart.ms.length > 2) {
    const meta = chartMetaFrom(r);           // 悬浮提示算时间轴要用
    if (r.chart.avg && r.chart.avg.length > 2) drawChart('chartFps', r.chart.avg, 'fps', null, meta);
    drawChart('chartMs', r.chart.ms, 'ms', r.chart.limit, meta);
  }
}

/** 把上限抬到好读的整数（帧率图用） */
function niceCeil(v) {
  if (!isFinite(v) || v <= 0) return 60;
  const step = v > 400 ? 100 : v > 200 ? 50 : v > 100 ? 20 : v > 60 ? 10 : 5;
  return Math.ceil(v / step) * step;
}

/** 图表下方说明：采样方式 + 纵轴上限（每帧毫秒图额外说明它不是延迟） */
function chartCaption(chart, mode) {
  const per = chart.per_bin;
  if (mode === 'fps') {
    const raw = (chart.avg && chart.avg.length ? chart.avg : chart.ms).map(Number);
    const lim = niceCeil(Math.max(...raw.map((v) => (v > 0 ? 1000 / v : 0))) * 1.1);
    return fillParams(t('report.chart.capFps', '每 {per} 帧取平均 · 纵轴上限 {limit} FPS'), { per: per, limit: lim });
  }
  let cap = fillParams(t('report.chart.capMs', '每 {per} 帧取最慢 · 纵轴上限 {limit} ms'),
    { per: per, limit: fmt(chart.limit, '', 1).v });
  if (chart.over) cap += fillParams(t('report.chart.capOver', ' · {n} 帧截顶'), { n: chart.over });
  cap += ' · ' + t('report.chart.note', '帧时间是相邻帧的生成间隔，不是延迟');
  return cap;
}

/* ── 图表：底图缓存 + 悬浮层重绘 ──
   底图（网格 / 面积 / 折线 / 上限标签）只在尺寸、数据或主题变化时画一次，缓存到离屏 canvas；
   鼠标移动时先把底图贴回来，再画十字线、标记点与提示框 —— 不用每次 mousemove 重绘整条曲线。 */
const chartStore = new Map();      // canvasId -> { series, mode, limitHint, meta, base, geom, colors }

function drawChart(canvasId, series, mode, limitHint, meta) {
  chartStore.set(canvasId, { series, mode, limitHint, meta: meta || {} });
  renderChart(canvasId);
}

/** 尺寸 / 主题变化后按记录的数据重画全部图表 */
function redrawCharts() {
  chartStore.forEach((_, id) => renderChart(id));
}

/**
 * 切换「导出长图视图」（由宿主通过 ExecuteScriptAsync 调用）。
 * 顺序讲究：宿主要**先弹保存对话框**，用户确认后才切视图——
 * 否则点击导出的瞬间窗口会先被放大成整页，几秒（截图）后才见到对话框。
 * 返回是否已切到目标状态，宿主据此判断能否截图。
 */
function setExportView(on) {
  const el = document.documentElement;
  if (on) el.classList.add('is-exporting'); else el.classList.remove('is-exporting');
  void document.body.offsetHeight;   // 强制一次布局，图表才能拿到导出宽度
  redrawCharts();                    // 宽度变了，按导出栅格重画（截图 2 倍才不糊）
  return el.classList.contains('is-exporting') === !!on;
}

/** 悬浮提示要用的上下文：每桶帧数 + 实际平均帧率（据此换算时间轴） */
function chartMetaFrom(r) {
  const per = r && r.chart ? (Number(r.chart.per_bin) || 0) : 0;
  const secs = Number(r && r.captured_seconds) || 0;
  const frames = Number(r && r.frames) || 0;
  const avgFps = secs > 0 && frames > 0 ? frames / secs : (Number(r && r.avg_fps) || 0);
  return { per, avgFps };
}

function renderChart(id) {
  const st = chartStore.get(id);
  const cv = document.getElementById(id);
  if (!st || !cv) return;
  const w = cv.clientWidth, h = cv.clientHeight;
  if (!w || !h) return;                       // 页面被隐藏时先不画，重新可见后会重画

  // 导出长图时截图会按 2 倍栅格出图，画布也翻倍才不糊
  const exportBoost = document.documentElement.classList.contains('is-exporting') ? 2 : 1;
  const dpr = (window.devicePixelRatio || 1) * exportBoost;
  cv.width = Math.max(1, Math.round(w * dpr));
  cv.height = Math.max(1, Math.round(h * dpr));

  const isFps = st.mode === 'fps';
  const raw = st.series.map(Number);
  // 帧率图传入的是「每桶平均帧时间」，换算 1000/ms 才是真实帧率水平；
  // 每帧毫秒图传入的是「每桶最慢帧」，用引擎给的统一上限
  const vals = isFps ? raw.map((v) => (v > 0 ? 1000 / v : 0)) : raw;
  const limit = isFps
    ? niceCeil(Math.max(...vals) * 1.1)
    : (Number(st.limitHint) || Math.max(...vals) || 16.7);
  const pad = 6;
  const plotW = w - pad * 2, plotH = h - pad * 2;
  const pt = (i, v) => [pad + (plotW * i) / Math.max(1, vals.length - 1), pad + plotH * (1 - Math.min(v, limit) / limit)];

  const css = getComputedStyle(document.documentElement);
  const colors = {
    accent: css.getPropertyValue('--accent').trim() || '#716493',
    line: css.getPropertyValue('--line').trim() || '#e3e0ec',
    lineStrong: css.getPropertyValue('--line-strong').trim() || '#c9c5d6',
    good: css.getPropertyValue('--good').trim() || '#2f8f46',
    faint: css.getPropertyValue('--faint').trim() || '#8b8a99',
    cardSolid: css.getPropertyValue('--card-solid').trim() || '#ffffff',
    strong: css.getPropertyValue('--text-strong').trim() || '#262330',
    muted: css.getPropertyValue('--muted').trim() || '#666278',
  };

  // ── 底图 ──
  const base = document.createElement('canvas');
  base.width = cv.width;
  base.height = cv.height;
  const g = base.getContext('2d');
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  g.clearRect(0, 0, w, h);

  // 网格
  g.strokeStyle = colors.line;
  g.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = pad + (plotH * i) / 4;
    g.beginPath();
    g.moveTo(pad, Math.round(y) + 0.5);
    g.lineTo(pad + plotW, Math.round(y) + 0.5);
    g.stroke();
  }

  // 基准线：帧率模式 60 FPS，帧时间模式 16.7 ms（等价）
  const refVal = isFps ? 60 : 16.7;
  if (limit >= refVal) {
    const y = pad + plotH * (1 - refVal / limit);
    g.save();
    g.strokeStyle = colors.good;
    g.setLineDash([5, 5]);
    g.globalAlpha = 0.7;
    g.beginPath();
    g.moveTo(pad, y);
    g.lineTo(pad + plotW, y);
    g.stroke();
    g.restore();
  }

  // 面积
  g.beginPath();
  vals.forEach((v, i) => { const [x, y] = pt(i, v); i ? g.lineTo(x, y) : g.moveTo(x, y); });
  g.lineTo(pad + plotW, pad + plotH);
  g.lineTo(pad, pad + plotH);
  g.closePath();
  const grad = g.createLinearGradient(0, pad, 0, pad + plotH);
  grad.addColorStop(0, hexA(colors.accent, 0.30));
  grad.addColorStop(1, hexA(colors.accent, 0));
  g.fillStyle = grad;
  g.fill();

  // 折线
  g.beginPath();
  g.strokeStyle = colors.accent;
  g.lineWidth = 1.4;
  g.lineJoin = 'round';
  vals.forEach((v, i) => { const [x, y] = pt(i, v); i ? g.lineTo(x, y) : g.moveTo(x, y); });
  g.stroke();

  // 右上角纵轴上限
  g.fillStyle = colors.faint;
  g.font = `${Math.round(10 * dpr) / dpr}px 'PerfFont', sans-serif`;
  g.textAlign = 'right';
  g.fillText(isFps ? `${Math.round(limit)} FPS` : `${limit.toFixed(1)} ms`, w - 2, pad + 9);

  st.base = base;
  st.colors = colors;
  st.geom = { w, h, dpr, pad, plotW, plotH, vals, limit, isFps, pt };
  paintChartBase(cv, st);
  bindChartHover(cv, id);
}

/** 把缓存的底图贴回可见 canvas（悬浮时反复调用，只有一次 drawImage） */
function paintChartBase(cv, st) {
  const ctx = cv.getContext('2d');
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, cv.width, cv.height);
  ctx.drawImage(st.base, 0, 0);
}

/* 画布跟着它的容器走：窗口缩放、拖分割条、卡片折叠、预览出现滚动条都会改宽度，
   只靠 window.resize 会漏掉后三种，hover 的坐标映射就会错位。 */
let chartObserver = null;
function observeChart(cv) {
  if (typeof ResizeObserver === 'undefined') return;
  if (!chartObserver) {
    chartObserver = new ResizeObserver((entries) => {
      entries.forEach((en) => {
        const c = en.target;
        const st = chartStore.get(c.id);
        if (!st) return;
        const w = c.clientWidth, h = c.clientHeight;
        if (!w || !h) return;
        if (st.geom && Math.abs(st.geom.w - w) < 1 && Math.abs(st.geom.h - h) < 1) return;
        renderChart(c.id);
      });
    });
  }
  chartObserver.observe(cv);
}

function bindChartHover(cv, id) {
  if (cv.dataset.hoverBound) return;
  cv.dataset.hoverBound = '1';
  observeChart(cv);                     // 容器尺寸一变就重画底图，hover 坐标才不会错位
  cv.style.cursor = 'crosshair';
  cv.addEventListener('pointermove', (ev) => hoverChart(cv, id, ev));
  cv.addEventListener('pointerdown', (ev) => hoverChart(cv, id, ev));
  cv.addEventListener('pointerleave', () => {
    const st = chartStore.get(id);
    if (st && st.base) paintChartBase(cv, st);
  });
}

function hoverChart(cv, id, ev) {
  const st = chartStore.get(id);
  if (!st || !st.base) return;
  const geo = st.geom;
  const n = geo.vals.length;
  if (n < 2) return;
  const rect = cv.getBoundingClientRect();
  const x = ev.clientX - rect.left;
  let i = Math.round(((x - geo.pad) / geo.plotW) * (n - 1));
  i = Math.max(0, Math.min(n - 1, i));
  paintChartBase(cv, st);
  drawChartHover(cv, st, i);
}

function drawChartHover(cv, st, i) {
  const geo = st.geom, c = st.colors, meta = st.meta || {};
  const ctx = cv.getContext('2d');
  ctx.setTransform(geo.dpr, 0, 0, geo.dpr, 0, 0);

  const v = geo.vals[i];
  const ms = geo.isFps ? (v > 0 ? 1000 / v : 0) : v;
  const fps = geo.isFps ? v : (v > 0 ? 1000 / v : 0);
  const [px, py] = geo.pt(i, v);

  // 十字线
  ctx.save();
  ctx.strokeStyle = c.faint;
  ctx.globalAlpha = 0.75;
  ctx.setLineDash([3, 3]);
  ctx.beginPath();
  ctx.moveTo(Math.round(px) + 0.5, geo.pad);
  ctx.lineTo(Math.round(px) + 0.5, geo.pad + geo.plotH);
  ctx.stroke();
  ctx.restore();

  // 标记点
  ctx.beginPath();
  ctx.arc(px, py, 3.2, 0, Math.PI * 2);
  ctx.fillStyle = c.accent;
  ctx.fill();
  ctx.lineWidth = 1.4;
  ctx.strokeStyle = c.cardSolid;
  ctx.stroke();

  // 提示框：时间 / 帧率 / 帧时间
  const secs = meta.per && meta.avgFps ? (i * meta.per) / meta.avgFps : 0;
  const lines = [
    [t('chart.hover.time', '时间'), `${secs.toFixed(1)} s`],
    [geo.isFps ? t('chart.hover.fps', '帧率') : t('chart.hover.eqFps', '等效帧率'), `${fps.toFixed(1)} FPS`],
    [geo.isFps ? t('chart.hover.avgFt', '平均帧时间') : t('chart.hover.slowFt', '最慢帧'), `${ms.toFixed(2)} ms`],
  ];

  const fs = 13, lh = 19, padX = 10, padY = 7;      // 字号按实际观感调过：11px 偏小
  ctx.font = `${fs}px 'PerfFont', sans-serif`;
  let boxW = 0;
  for (const [k, val] of lines) {
    boxW = Math.max(boxW, ctx.measureText(k).width + 12 + ctx.measureText(val).width);
  }
  boxW += padX * 2;
  const boxH = lines.length * lh + padY * 2 - 3;

  let bx = px + 12;
  if (bx + boxW > geo.w - 2) bx = px - 12 - boxW;
  bx = Math.max(2, Math.min(geo.w - boxW - 2, bx));
  let by = py - boxH - 10;
  if (by < 2) by = py + 12;
  by = Math.max(2, Math.min(geo.h - boxH - 2, by));

  ctx.beginPath();
  const r = 6;
  ctx.moveTo(bx + r, by);
  ctx.arcTo(bx + boxW, by, bx + boxW, by + boxH, r);
  ctx.arcTo(bx + boxW, by + boxH, bx, by + boxH, r);
  ctx.arcTo(bx, by + boxH, bx, by, r);
  ctx.arcTo(bx, by, bx + boxW, by, r);
  ctx.closePath();
  ctx.fillStyle = c.cardSolid;
  ctx.globalAlpha = 0.97;
  ctx.fill();
  ctx.globalAlpha = 1;
  ctx.lineWidth = 1;
  ctx.strokeStyle = c.lineStrong;
  ctx.stroke();

  ctx.textBaseline = 'middle';
  lines.forEach(([k, val], idx) => {
    const ty = by + padY + lh * idx + lh / 2 - 1;
    ctx.textAlign = 'left';
    ctx.fillStyle = c.muted;
    ctx.fillText(k, bx + padX, ty);
    ctx.textAlign = 'right';
    ctx.fillStyle = c.strong;
    ctx.fillText(val, bx + boxW - padX, ty);
  });
  ctx.textAlign = 'left';
  ctx.textBaseline = 'alphabetic';
}

/* ── 导出：把当前渲染结果包成独立 HTML ──
   用当前语言与当前主题的渲染结果快照，保证导出内容与界面一致；
   字体用系统栈（导出文件要能单独分发，不能依赖 assets 目录）。 */
/* 导出用的背景缓存：原图 3.2 MB 太大不能直接塞进导出文件，
   这里缩到 900px 宽再转 JPEG（约几十 KB），导出文件才能和窗口看起来一样。 */
const exportBgImg = new Image();
exportBgImg.src = '../../assets/background.jpg';
let exportBgUrl = null;
function exportBackground() {
  if (exportBgUrl !== null) return exportBgUrl;
  try {
    if (!exportBgImg.naturalWidth) return null;          // 还没加载好，本次先退回纯色
    const w = 900;
    const h = Math.max(1, Math.round(exportBgImg.naturalHeight * (w / exportBgImg.naturalWidth)));
    const cv = document.createElement('canvas');
    cv.width = w;
    cv.height = h;
    cv.getContext('2d').drawImage(exportBgImg, 0, 0, w, h);
    exportBgUrl = cv.toDataURL('image/jpeg', 0.55);
    return exportBgUrl;
  } catch (e) {
    return null;                                          // 取不到就退回纯色，绝不阻断导出
  }
}

function buildExportHtml() {
  // canvas 的位图不会被 innerHTML 序列化，而且克隆出来的 canvas 是空的，
  // 必须从**原画布**取 toDataURL，再塞进克隆的位置，否则导出的图表是空框。
  const src = $('#preview');
  const live = src.querySelectorAll('canvas');
  const clone = src.cloneNode(true);
  clone.querySelectorAll('canvas').forEach((cv, i) => {
    const from = live[i];
    const img = document.createElement('img');
    img.className = cv.className;
    if (from) {
      img.src = from.toDataURL('image/png');
      img.style.height = from.clientHeight + 'px';        // 按真实画布高度显示，不拉伸
    }
    cv.replaceWith(img);
  });
  const body = clone.innerHTML;
  const dark = document.documentElement.dataset.theme === 'dark';
  const c = dark
    ? { page: '#10131a', card: 'rgba(30, 33, 41, 0.80)', line: '#333842', text: '#e6e8ec', strong: '#f2f4f8', muted: '#a6acb8', accent: '#8672ba', good: '#5cbe78', warn: '#d6ac5c', bad: '#e86e68', overlay: 'rgba(10, 12, 17, 0.72)' }
    : { page: '#e9e8ef', card: 'rgba(255, 255, 255, 0.76)', line: '#e3e0ec', text: '#333649', strong: '#262330', muted: '#666278', accent: '#716493', good: '#2f8f46', warn: '#a86f14', bad: '#cf3b32', overlay: 'rgba(238, 237, 243, 0.66)' };
  const bgUrl = exportBackground();          // 与窗口一致的背景（缩图后内联）
  const title = t('report.heading', '性能报告');
  const css = `
    :root { color-scheme: ${dark ? 'dark' : 'light'}; }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 28px 22px; background-color: ${c.page}; color: ${c.text};
           /* 和窗口一样：背景图 + 主题遮罩；取不到图（还没加载好）就只用纯色 */
           background-image: ${bgUrl ? `linear-gradient(${c.overlay}, ${c.overlay}), url(${bgUrl})` : `linear-gradient(${c.overlay}, ${c.overlay})`};
           background-size: cover, cover; background-position: center, center 45%; background-repeat: no-repeat, no-repeat;
           background-attachment: fixed; min-height: 100vh;
           font-family: 'Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI', sans-serif; font-size: 14px; line-height: 1.55; }
    .wrap { max-width: 1080px; margin: 0 auto; background: ${c.card}; border: 1px solid ${c.line};
            border-radius: 14px 0 14px 0; box-shadow: 0 3px 0 -1px ${c.line}; padding: 22px 24px; }
    .rp-title { font-size: 1.5rem; color: ${c.strong}; margin-bottom: 4px; }
    .rp-meta { color: ${c.muted}; font-size: .8rem; margin-bottom: 16px; }
    .rp-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(140px, 1fr)); gap: 10px; margin-bottom: 18px; }
    .rp-tile { border: 1px solid ${c.line}; border-radius: 10px; padding: 10px 12px; background: transparent; }
    .rp-tile .k { color: ${c.muted}; font-size: .74rem; margin-bottom: 4px; }
    .rp-tile .v { font-size: 1.25rem; color: ${c.strong}; font-variant-numeric: tabular-nums; }
    .rp-tile .v small,
    .rp-tile .v .p { font-size: .62em; color: ${c.muted}; margin-left: 2px; }
    .rp-section { margin: 18px 0 8px; color: ${c.muted}; font-size: .76rem; letter-spacing: .06em; }
    .rp-verdict { display: flex; align-items: flex-start; gap: 8px; padding: 7px 0; border-bottom: 1px dashed ${c.line}; }
    .rp-verdict:last-child { border-bottom: none; }
    .rp-verdict i { width: 7px; height: 7px; border-radius: 50%; margin-top: .5em; flex: 0 0 auto; background: ${c.good}; }
    .rp-verdict.warn i { background: ${c.warn}; }
    .rp-verdict.bad i { background: ${c.bad}; }
    .rp-rows { border: 1px solid ${c.line}; border-radius: 9px; }
    .rp-rows .row { display: flex; justify-content: space-between; gap: 12px; padding: 7px 12px; border-bottom: 1px solid ${c.line}; }
    .rp-rows .row:last-child { border-bottom: none; }
    .rp-rows .row .k { color: ${c.muted}; }
    .rp-rows .row .v { color: ${c.strong}; font-variant-numeric: tabular-nums; }
    .rp-chart { border: 1px solid ${c.line}; border-radius: 9px; padding: 10px; }
    .rp-chart canvas, .rp-chart img { width: 100%; height: 180px; display: block; }
    .rp-chart .cap { color: ${c.muted}; font-size: .72rem; margin-top: 6px; }
    .empty { color: ${c.muted}; }
    @media print { body { padding: 0; background: #fff; } .wrap { border: none; box-shadow: none; } }
  `;
  return `<!DOCTYPE html>
<html lang="${LANG}">
<head>
<meta charset="utf-8">
<title>${escapeHtml(title)}</title>
<style>${css}</style>
</head>
<body><div class="wrap">${body}</div></body>
</html>`;
}
