/* 与宿主通信：postMessage 通道、全局状态、宿主消息分发 */

const bridge = window.chrome && window.chrome.webview ? window.chrome.webview : null;
const send = (msg) => { if (bridge) bridge.postMessage(msg); };

/* ── 状态 ── */
const state = {
  procs: [],
  selectedPid: 0,
  selectedName: '',
  selectedText: '',
  themeMode: 'system',
  language: 'zh-CN',
  busy: false,
  report: null,
};

/* 滚动统一交给浏览器原生处理：
   自己用 rAF 插值会踩两个坑 —— 小增量（触摸板）时 cur + delta*0.24 取整后原地不动，
   表现为「滚不动 / 极慢」；拖动滚动条时 rAF 又会把 scrollTop 拽回旧目标，表现为「拖了没用」。 */
/* ── 与宿主通信 ── */
function handleMessage(msg) {
  if (!msg || !msg.type) return;
  switch (msg.type) {
    case 'init': {
      const s = msg.settings || {};
      if (s.seconds) $('#seconds').value = s.seconds;
      $('#chkMin').checked = s.minimize !== false;
      $('#chkSound').checked = s.sound !== false;

      /* 顺序不能反：先按 capture-options.json 渲染出勾选框，再套用配置里保存的 skip。
         反过来的话，新增或改名的采集项会拿到错误状态。 */
      const cap = msg.options || null;
      /* 指标字典（含「暂不可用」与原因）：报告与详细说明都从这里取，缺了也能跑 */
      if (msg.metrics) window.PerfMetricsDoc = msg.metrics;
      const note = $('.card-note');
      if (cap && cap.hint && note) note.dataset.i18n = cap.hint;
      renderCaptureOptions(cap ? cap.options : null, cap ? cap.presets : null, cap ? cap.groups : null);
      if (typeof s.skip === 'string') {
        const skip = expandSkip(s.skip);   // 旧配置的 gpu / mem 会展开成拆后的四个
        $$('.collect-grid input').forEach(el => { if (!el.disabled) el.checked = !skip.includes(el.dataset.skip); });
      }
      restorePresetState(s.preset || '', Number(s.warmup), s.customBase || 'standard');
      applyTheme(s.theme || 'system');
      if (s.language) { state.language = s.language; setLanguage(s.language); }
      if (window.PerfUpdate) window.PerfUpdate.init(s.updateCheck);
      if (msg.procs) setProcs(msg.procs);
      /* 扩展中心状态随 init 下发；宿主侧是唯一事实来源，前端不再只靠本地镜像 */
      if (msg.extensions && window.PerfExtensionsUI) window.PerfExtensionsUI.apply(msg.extensions, msg.fpsSource);
      applyTranslations();
      break;
    }
    case 'procs': setProcs(msg.procs || []); break;
    case 'status': setStatus(msg.text || ''); break;
    case 'exportable': {
      $('#btnExport').disabled = !msg.value;
      $('#btnExportPng').disabled = !msg.value;
      break;
    }
    case 'pngDone': {
      // 长图导出收尾：退出导出视图，图表按正常栅格重画
      document.documentElement.classList.remove('is-exporting');
      redrawCharts();
      break;
    }
    case 'progress': setProgress(msg.pct || 0); break;
    case 'log': addLog(msg.text || '', msg.cls || ''); break;
    case 'report': renderReport(msg.data); break;
    case 'busy': setBusy(!!msg.value); if (window.PerfUpdate) window.PerfUpdate.busy(!!msg.value); break;
    case 'theme': applyTheme(msg.mode); break;
    case 'update': if (window.PerfUpdate) window.PerfUpdate.handle(msg); break;
    case 'metricSample': if (window.PerfRealtime) window.PerfRealtime.handle(msg); break;
    case 'metricsCaps': if (window.PerfRealtime) window.PerfRealtime.handle(msg); break;
    case 'overlayState': if (window.PerfRealtime) window.PerfRealtime.handle(msg); break;
    case 'extensions': if (window.PerfExtensionsUI) window.PerfExtensionsUI.apply(msg.extensions, msg.fpsSource); break;
    case 'extensionState': if (window.PerfExtensionsUI) window.PerfExtensionsUI.state(msg); break;
    case 'extensionError': if (window.PerfExtensionsUI) window.PerfExtensionsUI.error(msg); break;
    case 'extensionProgress': if (window.PerfExtensionsUI) window.PerfExtensionsUI.progress(msg); break;
    // 2.1.8：手动导入——宿主弹完文件框后把选中的路径回传，前端据此发起导入
    case 'extensionPackagePicked': if (window.PerfExtensionsUI) window.PerfExtensionsUI.picked(msg); break;
    case 'extensionPackagePickCancelled': if (window.PerfExtensionsUI) window.PerfExtensionsUI.pickCancelled(msg); break;
    case 'fpsSource': if (window.PerfExtensionsUI) window.PerfExtensionsUI.apply(null, msg.source); break;
    case 'error': addLog('[错误] ' + msg.text, 'ln-warn'); setStatus(msg.text || '出错'); break;
    default: break;
  }
}

function setProcs(items) {
  state.procs = items || [];
  /* 进程列表变了：通知实时监控页刷新「目标进程」下拉（那边不直接读 state） */
  try { document.dispatchEvent(new CustomEvent('perf:procs', { detail: { procs: state.procs } })); } catch (e) { }
  if (!state.procs.length) {
    $('#procText').textContent = '（没有找到带窗口的进程）';
    return;
  }
  const keep = state.procs.find(p => p.pid === state.selectedPid);
  const pick = keep || state.procs.find(p => /^Endfield/i.test(p.name)) || state.procs[0];
  state.selectedPid = pick.pid;
  state.selectedName = pick.name;
  state.selectedText = pick.text;
  $('#procText').textContent = pick.text;
}

if (bridge) bridge.addEventListener('message', (e) => handleMessage(e.data));
