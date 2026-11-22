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

  /* ── 01 概览：卡片 + 一句话总评 + 评估 ---- */
  html += rpSec('01', 'report.s1', '概览');
  html += '<div class="rp-grid">';
  html += tile(t('metric.avgFps', '平均帧率'), r.avg_fps, 'FPS', 1);
  // 1% Low 右侧直接显示它占平均帧率的百分比（同字号同颜色）；判定改由引擎按"落回频率"给
  html += tile(t('metric.p1low', '1% Low'), r.fps_1pct_low, 'FPS', 1,
    r.fps_1pct_low_pct != null ? r.fps_1pct_low_pct + '%' : '');
  if (r.display_latency_avg_ms != null) html += tile(t('metric.displayLatency', '上屏延迟'), r.display_latency_avg_ms, 'ms', 1);
  // PC 延迟 = 平均帧时间 + 上屏延迟（估算值，不是独立测量）→ 放回概览，名字里就带「估算」
  if (r.pc_latency_avg_ms != null) html += tile(t('metric.pcLatency', 'PC 延迟（估算）'), r.pc_latency_avg_ms, 'ms', 1);
  if (r.avg_frametime_ms != null) html += tile(t('metric.avgFrametime', '平均帧时间'), r.avg_frametime_ms, 'ms', 2);
  if (r.frametime_p95_ms != null) html += tile(t('metric.p95Frametime', 'P95 帧时间'), r.frametime_p95_ms, 'ms', 2);
  if (r.gpu_util_avg_pct != null) html += tile(t('metric.gpuUtil', 'GPU 占用'), r.gpu_util_avg_pct, '%', 0);
  if (r.gpu_temp_max_c != null) html += tile(t('metric.gpuTemp', 'GPU 温度'), r.gpu_temp_max_c, '°C', 0);
  if (r.vram_max_mb != null) html += tile(t('metric.vramPeak', '显存峰值'), r.vram_max_mb, 'MB', 0);
  if (r.ram_max_mb != null) html += tile(t('metric.ramPeak', '内存峰值'), r.ram_max_mb, 'MB', 0);
  html += '</div>';

  /* 一句话总评：只用引擎给的诊断结论，没有诊断就不写（不硬猜） */
  const sum = rpSummary(r);
  if (sum) html += `<div class="rp-summary ${sum.level}">${escapeHtml(sum.text)}</div>`;

  /* 口径说明：帧率含生成帧 —— 放在概览里，避免高 FPS 被误读成原生渲染 */
  html += `<div class="rp-note">${escapeHtml(t('report.fpsNote', ''))}</div>`;

  if (r.verdicts && r.verdicts.length) {
    html += `<div class="rp-section">${escapeHtml(t('report.section.eval', '评估'))}</div>`;
    for (const v of r.verdicts) {
      const cls = v[0] === 'warn' ? 'warn' : v[0] === 'bad' ? 'bad' : 'good';
      html += `<div class="rp-verdict ${cls}"><i></i><span>${escapeHtml(verdictText(v))}</span></div>`;
    }
  }

  /* ── 02 性能曲线：帧率/帧时间 + 负载 + 温度/功耗 ---- */
  const chart = r.chart, trend = r.trend;
  const hasMs = !!(chart && Array.isArray(chart.ms) && chart.ms.length > 2);
  const hasAvg = !!(hasMs && Array.isArray(chart.avg) && chart.avg.length > 2);
  const trendBlocks = [];
  if (trend) {
    if (Array.isArray(trend.cpu)) trendBlocks.push(['chartCpu', 'report.chart.titleCpu', 'CPU 负载（%）', trend.cpu, 'pct', 100, '%']);
    if (Array.isArray(trend.gpu)) trendBlocks.push(['chartGpu', 'report.chart.titleGpu', 'GPU 负载（%）', trend.gpu, 'pct', 100, '%']);
    if (Array.isArray(trend.temp)) trendBlocks.push(['chartTemp', 'report.chart.titleTemp', 'GPU 温度（°C）', trend.temp, 'abs', null, '°C']);
    if (Array.isArray(trend.power)) trendBlocks.push(['chartPower', 'report.chart.titlePower', 'GPU 功耗（W）', trend.power, 'abs', null, 'W']);
  }
  const live = trendBlocks.filter((b) => b[3].filter((v) => v != null).length > 1);
  if (hasMs || live.length) {
    html += rpSec('02', 'report.s2', '性能曲线');
    if (hasAvg) {
      html += chartBlock('chartFps', t('report.chart.titleFps', '帧率（FPS）'), chartCaption(chart, 'fps'));
    }
    if (hasMs) {
      html += chartBlock('chartMs', t('report.chart.titleMs', '每帧毫秒（ms）'), chartCaption(chart, 'ms'));
      if (!hasAvg) {
        html += `<div class="rp-chart-note">${escapeHtml(t('report.chart.noAvg', '这份报告由旧版本采集，缺少平均帧时间曲线，只显示每帧毫秒。'))}</div>`;
      }
    }
    const capTrend = fillParams(t('report.chart.capTrend',
      '按时间等分 {n} 段，段内取平均；某段没有样本就断开（不补值、不插值）'), { n: (trend && trend.bins) || '—' });
    live.forEach(([id, key, dflt, , , , unit]) => {
      html += chartBlock(id, t(key, dflt), capTrend, unit);
    });
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
  // 逐秒口径不再叫「1% Low」：它只是参考序列，不参与判定，也不与上面的 1% Low 并列
  if (r.fps_01pct_low != null) rows.push([t('metric.p01low', '0.1% 低帧率'), `${r.fps_01pct_low} FPS`]);
  if (r.stutter && r.stutter.count != null) {
    rows.push([t('metric.stutterRow', '卡顿（>50ms 合并计段）'),
      `${r.stutter.count} 段 / 累计 ${r.stutter.total_ms} ms / 最长 ${r.stutter.worst_ms} ms / 严重 ${r.stutter.severe} 帧`]);
  }
  if (r.fps_1pct_low_time != null) rows.push([t('metric.lowPerSec', '逐秒最低帧率（最差 1% 的秒）'), `${r.fps_1pct_low_time} FPS（占平均 ${r.fps_1pct_low_time_pct} %）`]);
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

  /* ---- 03–07：按指标字典分板块（每块只出一次，不重复） ---- */
  const doc = window.PerfMetricsDoc;
  const haveDict = !!(doc && Array.isArray(doc.modules) && Array.isArray(doc.metrics));

  const sec03 = haveDict ? renderMetricModules(r, ['cpu', 'gpu']) : '';
  if (sec03) html += rpSec('03', 'report.s3', 'CPU / GPU 状态') + sec03;

  const sec04 = haveDict ? renderMetricModules(r, ['memory']) : '';
  if (sec04) html += rpSec('04', 'report.s4', '内存资源') + sec04;

  const diagHtml = renderDiagnosis(r);
  const sec05 = haveDict ? renderMetricModules(r, ['bottleneck']) : '';
  if (diagHtml || sec05) html += rpSec('05', 'report.s5', '瓶颈诊断') + diagHtml + sec05;

  const sec06 = haveDict ? renderMetricModules(r, ['perf', 'thermal']) : '';
  if (sec06) html += rpSec('06', 'report.s6', '完整明细') + sec06;
  if (!haveDict && rows.length) {
    /* 没有字典（上一代的报告 / 字典文件没打包进去）时，06 退回原来的平铺明细 */
    html += rpSec('06', 'report.s6', '完整明细');
    html += `<div class="rp-rows">`;
    html += rows.map(([k, v]) => `<div class="row"><span class="k">${escapeHtml(k)}</span><span class="v">${escapeHtml(v)}</span></div>`).join('');
    html += '</div>';
  }

  const sec07 = haveDict ? renderMetricModules(r, ['environment']) : '';
  if (sec07) html += rpSec('07', 'report.s7', '测试环境') + sec07;

  /* 帧生成：设置状态和运行时检测是两件事，这里明说，避免「开着又未加载」的矛盾观感 */
  if (featureRaw(r, 'feature.dlss.framegen') != null || featureRaw(r, 'feature.framegenMode') != null) {
    html += `<div class="rp-note">${escapeHtml(t('report.fgNote', ''))}</div>`;
  }

  box.innerHTML = html;

  /* 图表要在 DOM 就位之后再画 */
  const cm = chartMetaFrom(r);           // 悬浮提示算时间轴要用
  if (hasAvg) drawChart('chartFps', chart.avg, 'fps', null, cm);
  if (hasMs) drawChart('chartMs', chart.ms, 'ms', chart.limit, cm);
  /* 趋势图也要能悬浮：时间轴按「第几段 / 总段数 × 采集秒数」换算 */
  const trendMeta = { trend: true, bins: Number(trend && trend.bins) || 0, secs: Number(r.captured_seconds) || 0 };
  live.forEach(([id, , , series, mode, lim, unit]) => {
    drawChart(id, series, mode, lim, trendMeta, unit);
  });
}
/* ─────────── B3：01–07 章节骨架用的小工具 ─────────── */
/** 章节标题：编号 + 名称（名称走 i18n，缺键回退中文） */
function rpSec(num, key, dflt) {
  return `<div class="rp-s"><span class="n">${escapeHtml(num)}</span>${escapeHtml(t(key, dflt))}</div>`;
}
/** 一张图的壳子：标题 + 画布 + 说明（结构沿用旧报告的 rp-chart-block） */
function chartBlock(id, title, cap, unit) {
  // 标题里已经带单位（如「GPU 温度（°C）」），不再重复挂一个单位标签
  return `<div class="rp-chart-block">` +
         `<div class="rp-chart-title">${escapeHtml(title)}</div>` +
         `<div class="rp-chart"><canvas id="${id}"></canvas>` +
         `<div class="cap">${escapeHtml(cap)}</div></div></div>`;
}
/** 一句话总评：只用引擎给的诊断结论，没有诊断就不写（不硬猜） */
function rpSummary(r) {
  const d = r.diagnosis;
  if (!d || !d.primary) return null;
  const text = t('diag.primary.' + d.primary, '');
  if (!text) return null;
  return { level: d.level === 'warn' ? 'warn' : 'good', text };
}
/** 诊断项的中文名：优先按指标 id 从字典取，字典缺了就用引擎给的 name */
function diagLabel(item) {
  const doc = window.PerfMetricsDoc;
  const id = item && item.metric;
  if (doc && Array.isArray(doc.metrics)) {
    const m = doc.metrics.find((x) => x && x.id === id);
    if (m) return docLabel(m);
  }
  return (item && item.name) || id || '';
}
/** 05 瓶颈诊断：结论 + 依据指标 + 同时值得注意的项（全部来自引擎实测） */
function renderDiagnosis(r) {
  const d = r.diagnosis;
  if (!d || !d.primary) return '';
  const level = d.level === 'warn' ? 'warn' : 'good';
  const title = t('diag.primary.' + d.primary, d.primary);
  const why = t('diag.why.' + d.primary, '');
  // 补充说明：解释「整机 CPU 不忙怎么会是瓶颈」这类反直觉数字，模板与参数都由引擎给
  const noteKey = d.note_key ? String(d.note_key) : '';
  const diagNote = noteKey ? fillParams(t('diag.note.' + noteKey, ''), d.note_params || {}) : '';
  let h = `<div class="rp-diag ${level}"><div class="h">${escapeHtml(title)}</div>` +
          (why ? `<div class="w">${escapeHtml(why)}</div>` : '') +
          (diagNote ? `<div class="w note">${escapeHtml(diagNote)}</div>` : '') + '</div>';
  const ev = Array.isArray(d.evidence) ? d.evidence : [];
  if (ev.length) {
    h += `<div class="rp-section">${escapeHtml(t('diag.evidence', '依据指标（全部来自本次采集）'))}</div>` +
         '<div class="rp-rows rp-diagrows">' +
         ev.map((e) => `<div class="row" data-metric="${escapeHtml(String((e && e.metric) || ''))}">` +
           `<span class="k">${escapeHtml(diagLabel(e))}</span>` +
           `<span class="v">${escapeHtml(String((e && e.value) || ''))}</span></div>`).join('') +
         '</div>';
  }
  const fd = Array.isArray(d.findings) ? d.findings : [];
  if (fd.length) {
    h += `<div class="rp-section">${escapeHtml(t('diag.findings', '同时值得注意'))}</div>` +
         '<div class="rp-rows rp-diagrows">' +
         fd.map((f) => `<div class="row is-finding" data-finding="${escapeHtml(String((f && f.id) || ''))}">` +
           `<span class="k">${escapeHtml(t('diag.finding.' + ((f && f.id) || ''), (f && f.name) || ''))}</span>` +
           `<span class="v">${escapeHtml(String((f && f.value) || ''))}</span></div>`).join('') +
         '</div>';
  }
  return h;
}
/* ─────────── B2：指标字典驱动的 7 个板块 ───────────
   doc = window.PerfMetricsDoc（宿主随 init 下发，源自 capture-metrics.json）。
   status=na 的指标显示「—」+「暂不可用」徽标，并在下一行写出原因：
   规则是采不到就说采不到，绝不用 0 或估算值冒充。 */
function docLang() {
  const l = (typeof LANG === 'string' && LANG) || 'zh-CN';
  if (l.indexOf('en') === 0) return { name: 'nameEn', reason: 'en' };
  if (l.indexOf('ja') === 0) return { name: 'nameJa', reason: 'ja' };
  return { name: 'nameZh', reason: 'zh' };
}
function docLabel(o) {
  const lg = docLang();
  return o[lg.name] || o.nameZh || o.id || '';
}
function docReason(doc, key) {
  const lg = docLang();
  const o = doc && doc.reasons ? doc.reasons[key] : null;
  if (!o) return '';
  return o[lg.reason] || o.zh || '';
}
function numText(v, unit, digits) {
  if (v == null || v === '') return null;
  const num = Number(v);
  if (!isFinite(num)) return null;
  return num.toFixed(digits == null ? 1 : digits) + (unit ? ' ' + unit : '');
}
/** 取引擎给的原始特征值（'value.loaded' / 'value.notLoaded' …），不做翻译 */
function featureRaw(r, key) {
  const f = (r.features || []).find((x) => x && x[0] === key);
  return f ? String(f[1]) : null;
}
/** 运行时检测状态：已检测到 / 未检测到 —— 与「游戏内设置」是两回事，别混着写 */
function runtimeState(r, key) {
  const raw = featureRaw(r, key);
  if (raw == null) return null;
  if (raw === 'value.loaded') return t('value.detected', '已检测到');
  if (raw === 'value.notLoaded') return t('value.notDetected', '未检测到');
  if (raw === 'value.notEnabled') return t('value.notEnabled', '未检测到启用');
  if (raw === 'value.notSelected') return t('value.notSelected', '未选择');
  return trKey(raw);
}
/** 当前选中的超分模式（引擎按游戏配置判定，四种互斥）：'dlss'|'fsr'|'xess'|'tsr'|'' */
function upscalerMode(r) {
  const f = (r.features || []).find((x) => x && x[0] === 'feature.upscalerActive');
  const v = f ? String(f[1]) : '';
  const k = v.toLowerCase();
  return (k === 'dlss' || k === 'fsr' || k === 'xess' || k === 'tsr') ? k : '';
}
/** 只显示「当前选中模式」那一行：其余模式不占位，避免又变成「三个都勾上」的错觉 */
function modeRow(r, mode) {
  if (upscalerMode(r) !== mode) return null;
  return featureText(r, 'feature.upscale.' + mode);
}
function featureText(r, key) {
  const f = (r.features || []).find((x) => x && x[0] === key);
  return f ? trKey(f[1]) : null;
}
/** 游戏内档位：直接给原始编码（不猜含义），读不到就说「无法确认档位」而不是「暂不可用」 */
function presetCode(r, key) {
  const raw = featureRaw(r, key);
  if (raw != null && /^\d+$/.test(String(raw))) {
    return fillParams(t('report.presetCode', '编码 {code}（含义未确认）'), { code: raw });
  }
  return t('report.presetUnknown', '无法确认档位');
}
/** CPU 温度/降频的汇总块（v2.1.11）：老报告没有这个字段，返回 null 而不是 0 */
function cpuThermal(r) {
  return (r && r.cpu_thermal && typeof r.cpu_thermal === 'object') ? r.cpu_thermal : null;
}
/** CPU 降频：只描述「Windows 日志记录到固件限速」，不写原因 */
function cpuThrottleText(r) {
  const ct = cpuThermal(r);
  if (!ct || ct.throttle_ok === false) return null;
  const n = Number(ct.throttle_count) || 0;
  if (n <= 0) return t('report.cpuThrottleOff', '未记录到固件限速');
  let s = fillParams(t('report.cpuThrottleOn', '已记录 {n} 条固件限速'), { n: n });
  const cores = Number(ct.throttle_cores) || 0;
  const maxS = ct.throttle_max_s;
  if (cores > 0) s += fillParams(t('report.cpuThrottleCores', '，涉及 {c} 个逻辑处理器'), { c: cores });
  if (maxS != null) s += fillParams(t('report.cpuThrottleMax', '，最长一次 {s} 秒'), { s: maxS });
  return s;
}
/** nvidia-smi 这一路是否真的采到了（否则不能说「未触发」，只能说没有数据） */
function nvsmiOk(r) {
  return r.gpu_temp_max_c != null || r.gpu_clock_avg_mhz != null ||
         r.gpu_power_avg_w != null || r.gpu_fan_avg_pct != null;
}
/** 降频原因按「状态」读：采样里出现过就报占比，没出现明确说未触发 */
function throttleState(r, key) {
  if (!nvsmiOk(r)) return null;
  const v = r.throttle ? r.throttle[key] : null;
  if (v != null && Number(v) > 0) {
    return fillParams(t('report.throttleOn', '触发 · 采样中 {p}% 时间'), { p: Number(v) });
  }
  return t('report.throttleOff', '未触发');
}
const METRIC_TEXT = {
  'perf.avgFps': (r) => numText(r.avg_fps, 'FPS', 1),
  'perf.p1Low': (r) => {
    const s = numText(r.fps_1pct_low, 'FPS', 1);
    return s && r.fps_1pct_low_pct != null ? s + '（' + r.fps_1pct_low_pct + '%）' : s;
  },
  'perf.p01Low': (r) => numText(r.fps_01pct_low, 'FPS', 1),
  'perf.minFps': (r) => numText(r.fps_min, 'FPS', 1),
  'perf.maxFps': (r) => numText(r.max_fps, 'FPS', 1),
  'perf.avgFt': (r) => numText(r.avg_frametime_ms, 'ms', 2),
  'perf.p95Ft': (r) => numText(r.frametime_p95_ms, 'ms', 2),
  'perf.p99Ft': (r) => numText(r.frametime_p99_ms, 'ms', 2),
  'perf.stutterCount': (r) => (r.stutter ? r.stutter.count + ' 段' : null),
  'perf.stutterDuration': (r) => (r.stutter ? numText(r.stutter.total_ms, 'ms', 1) : null),
  'perf.stutterWorst': (r) => (r.stutter ? numText(r.stutter.worst_ms, 'ms', 1) : null),
  'perf.displayLatency': (r) => numText(r.display_latency_avg_ms, 'ms', 2),
  'perf.displayLatencyP95': (r) => numText(r.display_latency_p95_ms, 'ms', 2),
  'perf.pcLatency': (r) => numText(r.pc_latency_avg_ms, 'ms', 2),
  'perf.jitter': (r) => numText(r.frametime_jitter_pct, '%', 1),
  'cpu.total': (r) => numText(r.cpu_util_avg_pct, '%', 1),
  'cpu.process': (r) => numText(r.cpu_extra && r.cpu_extra.proc_cpu_avg_pct, '%', 1),
  'cpu.coreMax': (r) => numText(r.cpu_max_core_peak_pct, '%', 1),
  'cpu.clock': (r) => numText(r.cpu_clock_avg_mhz, 'MHz', 0),
  'cpu.temp': (r) => {
    const ct = cpuThermal(r);
    return ct ? numText(ct.temp_max_c, '°C', 0) : null;
  },
  'cpu.throttle': (r) => cpuThrottleText(r),
  'cpu.power': (r) => numText(r.cpu_extra && r.cpu_extra.pkg_power_avg_w, 'W', 1),
  'gpu.util': (r) => numText(r.gpu_util_avg_pct, '%', 0),
  'gpu.temp': (r) => numText(r.gpu_temp_max_c, '°C', 0),
  'gpu.clock': (r) => numText(r.gpu_clock_avg_mhz, 'MHz', 0),
  'gpu.power': (r) => numText(r.gpu_power_avg_w, 'W', 1),
  'gpu.vramUsed': (r) => numText(r.gpu_mem_total_avg_mb, 'MB', 0),
  'gpu.memClock': (r) => numText(r.gpu_mem_clock_avg_mhz, 'MHz', 0),
  'gpu.fan': (r) => numText(r.gpu_fan_avg_pct, '%', 0),
  'gpu.throttle': (r) => {
    if (!r.throttle) return null;
    const ks = Object.keys(r.throttle);
    if (!ks.length) return null;
    return ks.map((k) => t('metric.throttle.' + k, k) + ' ' + r.throttle[k] + '%').join(' · ');
  },
  'mem.processRam': (r) => numText(r.ram_max_mb, 'MB', 0),
  'mem.systemRam': (r) => numText(r.memory && r.memory.sys_ram_avg_pct, '%', 1),
  'mem.processVram': (r) => numText(r.vram_max_mb, 'MB', 0),
  'mem.systemVram': (r) => {
    const used = r.gpu_mem_total_avg_mb, total = r.vram_total_mb;
    if (used == null) return null;
    if (total) return numText(used, 'MB', 0) + '（' + Math.round((used / total) * 100) + '%）';
    return numText(used, 'MB', 0);
  },
  'mem.availableRam': (r) => numText(r.memory && r.memory.sys_ram_min_avail_mb, 'MB', 0),
  'mem.sharedVram': (r) => numText(r.memory && r.memory.shared_vram_max_mb, 'MB', 0),
  'mem.commit': (r) => numText(r.memory && r.memory.sys_commit_max_mb, 'MB', 0),
  'thermal.gpuPowerAvg': (r) => numText(r.gpu_power_avg_w, 'W', 1),
  'thermal.cpuPowerAvg': (r) => numText(r.cpu_extra && r.cpu_extra.pkg_power_avg_w, 'W', 1),
  'thermal.cpuPowerPeak': (r) => numText(r.cpu_extra && r.cpu_extra.pkg_power_max_w, 'W', 1),
  'thermal.gpuPowerPeak': (r) => numText(r.gpu_power_max_w, 'W', 1),
  'thermal.gpuThermalLimit': (r) => throttleState(r, 'sw_thermal'),
  'thermal.gpuPowerLimit': (r) => throttleState(r, 'sw_power_cap'),
  'thermal.gpuThermalThrottle': (r) => throttleState(r, 'hw_thermal'),
  'thermal.cpuThermalThrottle': (r) => cpuThrottleText(r),
  'bottleneck.gpuBusy': (r) => numText(r.bottleneck && r.bottleneck.gpu_busy_pct, '%', 1),
  'bottleneck.cpuFrameTime': (r) => numText(r.bottleneck && r.bottleneck.cpu_frame_ms, 'ms', 2),
  'bottleneck.gpuRenderTime': (r) => numText(r.bottleneck && r.bottleneck.gpu_render_ms, 'ms', 2),
  'bottleneck.gpuWait': (r) => numText(r.bottleneck && r.bottleneck.gpu_wait_ms, 'ms', 2),
  'bottleneck.frameGen': (r) => runtimeState(r, 'feature.dlss.framegen'),
  'env.cpuModel': (r) => (r.environment && r.environment.cpu_model) || null,
  'env.gpuModel': (r) => (r.environment && r.environment.gpu_model) || null,
  'env.ramType': (r) => (r.environment && r.environment.ram_type) || null,
  'env.resolution': (r) => {
    const res = r.resolution ? String(r.resolution).replace('x', '×') : null;
    const wm = r.window_mode || null;
    if (!res && !wm) return null;
    return [res, wm].filter(Boolean).join(' / ');
  },
  /* 游戏内档位：直接给原始编码（不猜含义），读不到就说「无法确认档位」而不是「暂不可用」 */
  'env.upscalerPreset': (r) => presetCode(r, 'feature.upscalerLevel'),
  /* 供电侧（07 测试环境）：台机没电池时 battery 行自动不显示；缺字段一律返回 null 让行消失，
     但「0 次电源中断」「无异常」是真实值，必须显示出来，不能被当成空值吞掉。 */
  'env.powerSource': (r) => {
    const e = r.environment || {};
    const name = { ac: t('value.powerAc', '交流电'), battery: t('value.powerBattery', '电池'), mixed: t('value.powerMixed', '交流电与电池混用') }[e.power_source];
    if (!name) return null;
    if (e.ac_off_pct > 0 && e.ac_off_pct < 100) return name + '（' + t('value.batteryShare', '电池占比') + ' ' + e.ac_off_pct + '%）';
    return name;
  },
  'env.gpuPowerLimit': (r) => {
    const e = r.environment || {};
    if (e.gpu_limit_max_w == null) return null;
    const a = numText(e.gpu_limit_min_w, 'W', 1), b = numText(e.gpu_limit_max_w, 'W', 1);
    return a === b ? b : a + ' – ' + b;
  },
  'env.batteryLevel': (r) => {
    const e = r.environment || {};
    if (!e.battery_present || e.battery_min_pct == null) return null;
    return e.battery_min_pct + ' – ' + e.battery_max_pct + ' %';
  },
  'env.powerEvents': (r) => {
    const e = r.environment || {};
    if (e.power_events == null) return null;
    return e.power_events === 0 ? '0 ' + t('value.times', '次') : e.power_events + ' ' + t('value.times', '次');
  },
  'env.powerHealth': (r) => {
    const e = r.environment || {};
    if (!e.power_health) return null;
    return e.power_health === 'ok' ? t('value.normal', '无异常') : (e.power_health_detail || t('value.hasIssue', '有记录'));
  },
  'env.dlssPreset': (r) => presetCode(r, 'feature.dlssMode'),
  'env.fgPreset': (r) => presetCode(r, 'feature.framegenModeLevel'),
  'env.foreground': (r) => numText(r.foreground_pct, '%', 0),
  /* 帧数据源（2.1.10）：同一次采集只有一个来源。旧报告没有该字段时不显示这一行，
     不拿 PresentMon 冒充。扩展源只显示 id + 已标注，不猜它的内部实现。 */
  'env.fpsSource': (r) => {
    const s = (r.environment && r.environment.fps_source) || r.fps_source;
    if (!s) return null;
    if (s === 'presentmon') return t('value.fpsPresentmon', 'PresentMon ETW（零注入基线）');
    return fillParams(t('value.fpsExtension', '{id}（扩展数据源）'), { id: s });
  },
  'env.presentApi': (r) => (r.environment && r.environment.present_api) || r.api || null,
  'env.presentMode': (r) => (r.environment && r.environment.present_mode) || r.present_mode || null,
  'env.upscaler': (r) => {
    // 模块枚举失败（反作弊挡住）且没读到配置 → 只说这次没拿到，不硬猜
    if (featureText(r, 'feature.upscalers') != null && !upscalerMode(r)) return null;
    // 引擎按游戏配置判定「当前选中的是哪一种」——四种模式互斥，不是「加载了哪些库」
    const code = featureRaw(r, 'feature.upscalerCode') || featureRaw(r, 'feature.upscalerLevel');
    const mode = upscalerMode(r);
    const name = mode === 'dlss' ? 'DLSS' : mode === 'fsr' ? 'FSR' : mode === 'xess' ? 'XeSS' : mode === 'tsr' ? 'TSR' : '';
    if (name) return code ? `${name}（编码 ${code}）` : name;
    if (code) return fillParams(t('report.upscalerUnknown', '无法确认档位（编码 {code}）'), { code });
    return null;
  },
  /* 以下四种模式行：只有「当前选中」的那一行才出现。
     以前不看模式、只看 dll 是否加载，结果 DLSS / FSR / XeSS 全部显示已加载 —— 那是错的。 */
  'env.dlss': (r) => modeRow(r, 'dlss'),
  'env.dlssFg': (r) => (upscalerMode(r) === 'dlss' ? runtimeState(r, 'feature.dlss.framegen') : null),
  'env.dlssRayRecon': (r) => (upscalerMode(r) === 'dlss' ? featureText(r, 'feature.dlss.rayReconstruction') : null),
  'env.fsr': (r) => modeRow(r, 'fsr'),
  'env.xess': (r) => modeRow(r, 'xess'),
  'env.reflex': (r) => {
    // 引擎给的是游戏配置里的原始编码；本版不确定编码含义 → 报「已启用（编码 X，含义未确认）」，不裸给数字
    const raw = featureRaw(r, 'feature.reflex');
    if (raw == null) return null;
    if (/^\d+$/.test(raw)) {
      if (raw === '0') return t('value.off', '关');
      return fillParams(t('value.reflexSet', '已启用（编码 {code}，含义未确认）'), { code: raw });
    }
    return trKey(raw);
  },
  'env.frameGenInGame': (r) => featureText(r, 'feature.framegenMode')
};

/** 这个指标是不是「用户把开关关掉了」：opt 里列出的开关**全部关闭**才算未采集；
    任一开着就交给数据本身决定（可能采到，也可能运行时失败 → 走暂不可用/不显示）。 */
function metricOff(r, x) {
  const c = r && r.collected;
  if (!c || !x || !x.opt) return false;
  const opts = Array.isArray(x.opt) ? x.opt : [x.opt];
  const keys = opts.filter(Boolean);
  return keys.length > 0 && keys.every((k) => c[k] === false);
}
/* 开关开着、但引擎这次确实没采到时的原因（例如目标进程没出现在显卡计数器实例里）。
   返回 '' 表示「不是这种情况」；返回字符串则按「暂不可用」渲染并显示该原因。
   目的：不让一行数据因为「这次没采到」就悄悄消失——用户有权知道为什么没有。 */
function runtimeNaWhy(r, x) {
  if (!r || !x) return '';
  if (x.id === 'mem.sharedVram' && r.memory && r.memory.shared_vram_state === 'noAdapterInstance') {
    return t('report.naWhy.noAdapterInstance',
      '目标游戏未出现在显卡计数器实例中，本次没有采到共享内存数值（可能是驱动未暴露该计数器，或该进程不走 DXGI 呈现）。');
  }
  /* CPU 功耗：开关开着但这台机器没有 Energy Meter 计数器 —— 必须出「暂不可用」+ 原因，
     既不能藏行，也不能拿 0 W 或估算值顶上。 */
  if ((x.id === 'cpu.power' || x.id === 'thermal.cpuPowerAvg' || x.id === 'thermal.cpuPowerPeak') &&
      r.cpu_extra && r.cpu_extra.pkg_power_state === 'unavailable') {
    return t('report.naWhy.noEnergyMeter',
      '这台机器没有向 Windows 提供 CPU 能量计数器（Energy Meter），本次没有采到功耗数值；这里不会用 0 W 或估算值代替。');
  }
  /* CPU 温度：只有联想固件通道；其它品牌如实不可用，不用主板热区或估算值顶替。
     老报告没有 cpu_thermal 字段 → 返回空，交给正常渲染（有值才有行）。 */
  const ct = cpuThermal(r);
  /* 「未采集」≠「暂不可用」：用户在采集项里关掉时，原因是「你关的」，不是「这台机器没有」。
     两者共用一条文案会让用户以为机器不支持，必须分项判断（温度与降频是两个独立开关）。 */
  const skippedText = t('report.naWhy.skipped', '采集项里关闭了这一项，本次没有采集；这不代表这台机器不支持。');
  if (x.id === 'cpu.temp' && ct && ct.temp_state === 'skipped') return skippedText;
  if ((x.id === 'cpu.throttle' || x.id === 'thermal.cpuThermalThrottle') && ct && ct.throttle_state === 'skipped') {
    return skippedText;
  }
  if (x.id === 'cpu.temp' && ct && ct.temp_state && ct.temp_state !== 'ok') {
    return t('report.naWhy.cpuTemp',
      '这台机器没有可用的固件温度通道（目前仅联想机型支持）。这里不会用估算值或主板热区温度替代。');
  }
  if ((x.id === 'cpu.throttle' || x.id === 'thermal.cpuThermalThrottle') && ct && ct.throttle_ok === false) {
    return t('report.naWhy.cpuThrottle',
      'Windows 系统日志不可读，本次无法判断是否发生固件限速；不会用频率或温度去猜测原因。');
  }
  /* 平台覆盖（规则文档 §1）：表外组合必须明确说「不支持」，不能因为值为空就把整行藏掉。 */
  const env = r.environment || {};
  if ((x.module === 'gpu' || String(x.id || '').indexOf('thermal.gpu') === 0) &&
      env.gpu_vendor && env.gpu_vendor !== 'nvidia') {
    return t('report.naWhy.gpuVendor',
      'GPU 指标目前只支持 NVIDIA 显卡；这台机器的显卡不在覆盖范围内，因此没有数值，也不用估算值代替。');
  }
  if (x.module === 'cpu' && env.cpu_vendor && env.cpu_vendor !== 'intel' && env.cpu_vendor !== 'amd') {
    return t('report.naWhy.cpuVendor',
      'CPU 指标目前只支持 Intel / AMD 处理器；这台机器的处理器不在覆盖范围内，因此没有数值。');
  }
  return '';
}

/** 按字典顺序渲染 7 个板块；字典缺失时返回 ''，交给调用方回退平铺明细 */
function renderMetricModules(r, only) {
  const doc = window.PerfMetricsDoc;
  if (!doc || !Array.isArray(doc.modules) || !Array.isArray(doc.metrics)) return '';
  // only：只渲染这些板块（03/04/05/06/07 各取自己那几块，同一指标不会出现两次）
  const want = Array.isArray(only) && only.length ? new Set(only) : null;
  let html = '';
  doc.modules.forEach((m) => {
    if (want && !want.has(m.id)) return;
    const list = doc.metrics.filter((x) => x && x.module === m.id);
    if (!list.length) return;
    let body = '';
    list.forEach((x) => {
      const label = escapeHtml(docLabel(x));
      /* 三态：未采集（用户关掉了开关）/ 暂不可用（采不到）/ 有值。
         「未采集」必须和「暂不可用」分开——前者是用户的选择，后者是能力限制。 */
      if (metricOff(r, x)) {
        body += `<div class="row is-off" data-metric="${escapeHtml(x.id)}">` +
                `<span class="k">${label}<span class="rp-off-badge">${escapeHtml(t('report.off', '未采集'))}</span></span>` +
                `<span class="v na">—</span></div>`;
        body += `<div class="rp-na-why">` + escapeHtml(t('report.offShort', '对应的采集项已关闭，本次没有采')) + '</div>';
        return;
      }
      if (x.status === 'na') {
        const why = docReason(doc, x.reason);
        body += `<div class="row is-na" data-metric="${escapeHtml(x.id)}"` +
                (why ? ` title="${escapeHtml(why)}"` : '') + `>` +
                `<span class="k">${label}<span class="rp-na-badge">${escapeHtml(t('report.na', '暂不可用'))}</span></span>` +
                `<span class="v na">—</span></div>`;
        // 默认只出短句，底层原因放进 title 提示（普通玩家不需要每个字段旁边都写一遍实现细节）
        body += `<div class="rp-na-why"` + (why ? ` title="${escapeHtml(why)}"` : '') + `>` +
                escapeHtml(t('report.naShort', '当前采集方式无法可靠读取')) + '</div>';
        return;
      }
      const unWhy = runtimeNaWhy(r, x);
      if (unWhy) {
        body += `<div class="row is-na" data-metric="${escapeHtml(x.id)}" title="${escapeHtml(unWhy)}">` +
                `<span class="k">${label}<span class="rp-na-badge">${escapeHtml(t('report.na', '暂不可用'))}</span></span>` +
                `<span class="v na">—</span></div>`;
        body += `<div class="rp-na-why" title="${escapeHtml(unWhy)}">${escapeHtml(unWhy)}</div>`;
        return;
      }
      const fn = METRIC_TEXT[x.id];
      const val = fn ? fn(r) : null;
      if (val == null) return;   // 开关开着但没采到：不占位（na 才有原因可说）
      body += `<div class="row" data-metric="${escapeHtml(x.id)}"><span class="k">${label}</span><span class="v">${escapeHtml(val)}</span></div>`;
    });
    if (!body) return;
    html += `<div class="rp-section">${escapeHtml(docLabel(m))}</div>` +
            `<div class="rp-rows rp-module" data-module="${escapeHtml(m.id)}">${body}</div>`;
  });
  return html;
}

/** 把上限抬到好读的整数（帧率图用） */
function niceCeil(v) {
  if (!isFinite(v) || v <= 0) return 60;
  const step = v > 400 ? 100 : v > 200 ? 50 : v > 100 ? 20 : v > 60 ? 10 : 5;
  return Math.ceil(v / step) * step;
}

/** 趋势图的纵轴：
    · 百分比（cpu/gpu 负载）从 0 起 —— 百分比本身有绝对含义；
    · 绝对值（温度/功耗）用数据窗口 —— 45→46 °C 的波动放在 0–60 轴上就是一条平线，
      看着像「没画」。窗口上下界都标在图上，读者能看出量程，不会把平线读成大起伏。 */
function trendAxis(finite, isPct) {
  const mx = Math.max(...finite), mn = Math.min(...finite);
  if (isPct) return { base: 0, limit: Math.min(100, Math.max(10, niceCeil(Math.max(mx * 1.25, mx + 5)))) };
  const pad = Math.max((mx - mn) * 0.3, 0.5);
  const base = Math.max(0, mn - pad);
  return { base, limit: Math.max(base + 1, mx + pad) };
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

function drawChart(canvasId, series, mode, limitHint, meta, unit) {
  chartStore.set(canvasId, { series, mode, limitHint, meta: meta || {}, unit: unit || '' });
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
  /* mode：fps（帧率，数据是每桶平均帧时间）/ ms（帧时间）/ pct（0–100 百分比）/ abs（带单位绝对值）。
     序列里允许 null（该时间桶没有样本）—— 图上断开，不当成 0。 */
  const isFps = st.mode === 'fps';
  const isFrame = isFps || st.mode === 'ms';        // 帧率/帧时间：有 60 FPS · 16.7 ms 基准线
  const isTrend = st.mode === 'pct' || st.mode === 'abs';
  // 负载/温度/功耗这类趋势图也吃悬浮（和帧率图一样会出十字线 + 数值），只是提示内容不同
  const isHoverable = isFrame || isTrend;
  const raw = st.series.map((x) => (x == null || x === '' ? null : Number(x)));
  // 帧率图传入的是「每桶平均帧时间」，换算 1000/ms 才是真实帧率水平；
  // 每帧毫秒图传入的是「每桶最慢帧」，用引擎给的统一上限
  const vals = raw.map((v) => (v == null || !isFinite(v) ? null : (isFps ? (v > 0 ? 1000 / v : 0) : v)));
  const finite = vals.filter((v) => v != null);
  if (!finite.length) return;
  /* 纵轴：帧率/帧时间用引擎给的统一上限（要能容下最慢一帧）；
     负载/温度/功耗按数据取轴 —— 固定 0–100 会把 13% 的 CPU 曲线压成贴底一条线，
     固定 0–60 会把 45→46 °C 压成一条平线，用户看到的就是「这张图没画」。 */
  let axisBase = 0, limit;
  if (isTrend) {
    const ax = trendAxis(finite, st.mode === 'pct');
    axisBase = ax.base; limit = ax.limit;
  } else {
    limit = st.limitHint != null ? Number(st.limitHint) : niceCeil(Math.max(...finite) * 1.1);
  }
  const axisSpan = Math.max(1e-6, limit - axisBase);
  const pad = 6;
  const plotW = w - pad * 2, plotH = h - pad * 2;
  const pt = (i, v) => [pad + (plotW * i) / Math.max(1, vals.length - 1),
    pad + plotH * (1 - (Math.min(v, limit) - axisBase) / axisSpan)];
  // 连续段：null 把曲线切成若干段，每段单独画（单点段画一个圆点，免得看不见）
  const runs = [];
  let curRun = null;
  vals.forEach((v, i) => {
    if (v == null) { curRun = null; return; }
    if (!curRun) { curRun = []; runs.push(curRun); }
    curRun.push(i);
  });

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

  // 基准线只对帧率/帧时间有意义（60 FPS 与 16.7 ms 等价）；百分比与绝对值图不画
  if (isFrame) {
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
  }

  // 面积：每段单独闭合到基线（null 处断开，不跨缺口连线）
  const grad = g.createLinearGradient(0, pad, 0, pad + plotH);
  grad.addColorStop(0, hexA(colors.accent, 0.30));
  grad.addColorStop(1, hexA(colors.accent, 0));
  g.fillStyle = grad;
  runs.forEach((run) => {
    if (run.length < 2) return;
    g.beginPath();
    run.forEach((i, k) => { const [x, y] = pt(i, vals[i]); k ? g.lineTo(x, y) : g.moveTo(x, y); });
    const [xl] = pt(run[run.length - 1], 0), [xf] = pt(run[0], 0);
    g.lineTo(xl, pad + plotH);
    g.lineTo(xf, pad + plotH);
    g.closePath();
    g.fill();
  });

  // 折线
  g.strokeStyle = colors.accent;
  g.lineWidth = 1.4;
  g.lineJoin = 'round';
  runs.forEach((run) => {
    if (run.length === 1) {
      const [x, y] = pt(run[0], vals[run[0]]);
      g.beginPath();
      g.arc(x, y, 1.6, 0, Math.PI * 2);
      g.fillStyle = colors.accent;
      g.fill();
      return;
    }
    g.beginPath();
    run.forEach((i, k) => { const [x, y] = pt(i, vals[i]); k ? g.lineTo(x, y) : g.moveTo(x, y); });
    g.stroke();
  });

  // 纵轴上下界都标出来：趋势图量程可能不是从 0 起（温度/功耗按数据取窗口），不标会误导
  const axisNum = (v) => (isTrend && Math.abs(v) < 100 ? v.toFixed(1) : `${Math.round(v)}`);
  const uTxt = st.unit ? ' ' + st.unit : '';
  const topLabel = isFps ? `${Math.round(limit)} FPS`
    : (st.mode === 'ms' ? `${limit.toFixed(1)} ms`
      : `${axisNum(limit)}${uTxt}`);
  g.fillStyle = colors.faint;
  g.font = `${Math.round(10 * dpr) / dpr}px 'PerfFont', sans-serif`;
  g.textAlign = 'right';
  g.fillText(topLabel, w - 2, pad + 9);
  if (isTrend && axisBase > 0) g.fillText(`${axisNum(axisBase)}${uTxt}`, w - 2, pad + plotH - 2);

  st.base = base;               // 底图缓存（离屏 canvas），悬浮时贴回来

  st.colors = colors;
  st.geom = { w, h, dpr, pad, plotW, plotH, vals, limit, axisBase, isFps, pt };
  paintChartBase(cv, st);
  if (isHoverable) bindChartHover(cv, id);   // 帧率/帧时间/负载/温度/功耗都能悬浮
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

  // 提示框：帧率/帧时间图给时间 + 帧率 + 帧时间；负载/温度/功耗图给时间 + 该段平均值
  const isTrend = !geo.isFps && !(st.mode === 'ms');
  const secs = isTrend
    ? (meta.secs && meta.bins ? (i * meta.secs) / Math.max(1, meta.bins) : 0)
    : (meta.per && meta.avgFps ? (i * meta.per) / meta.avgFps : 0);
  const unitTxt = st.unit ? ' ' + st.unit : '';
  const lines = isTrend ? [
    [t('chart.hover.time', '时间'), `${secs.toFixed(1)} s`],
    [t('chart.hover.segAvg', '这一段平均'), `${v.toFixed(1)}${unitTxt}`],
  ] : [
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
