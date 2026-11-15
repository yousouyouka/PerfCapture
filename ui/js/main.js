/* 事件绑定与启动 */

/* ── 事件绑定 ── */
/* 主题切换已移到设置页；顶栏不再有全局设置入口 */

$('#btnProc').addEventListener('click', (e) => {
  const anchor = e.currentTarget;
  // 同一个按钮再点一次 = 收起；这条必须放在"列表为空就刷新"之前
  if (popup.classList.contains('open') && popupAnchor === anchor) { closePopup(); return; }
  if (!state.procs.length) { send({ cmd: 'refreshProcs' }); return; }
  const active = state.procs.findIndex(p => p.pid === state.selectedPid);
  openPopup(anchor, state.procs, (it) => {
    state.selectedPid = it.pid;
    state.selectedName = it.name;
    state.selectedText = it.text;
    $('#procText').textContent = it.text;
    addLog('> 目标进程: ' + it.name + ' (PID ' + it.pid + ')', 'ln-accent');
  }, active);
});

$('#btnRefresh').addEventListener('click', () => {
  send({ cmd: 'refreshProcs' });
  addLog('> 刷新进程列表', 'ln-accent');
});

$('#btnStart').addEventListener('click', () => {
  if (state.busy) return;
  const seconds = parseInt($('#seconds').value, 10);
  if (!Number.isFinite(seconds) || seconds < 10 || seconds > 1800) {
    setStatus(t('status.badSeconds', '采集秒数需在 10 – 1800 之间'));
    $('#seconds').focus();
    return;
  }
  if (!state.selectedPid) { setStatus(t('status.pickProcess', '请先选择目标进程')); return; }
  if (!state.selectedText) return;

  const skip = $$('.collect-grid input').filter(el => !el.checked).map(el => el.dataset.skip).join(',');
  const warmup = (typeof currentWarmup === 'function') ? currentWarmup() : 0;
  saveSettings();
  setBusy(true);
  setProgress(0);
  termLines.length = 0;
  termEl.innerHTML = '';
  addLog('> 开始采集', 'ln-accent');
  addLog('  目标: ' + state.selectedText);
  addLog('  时长: ' + seconds + ' 秒' + ($('#chkMin').checked ? '，倒计时 5 秒' : ''));
  addLog('  跳过: ' + (skip || '无'));
  if (warmup > 0) addLog('  预热丢弃: 开头 ' + warmup + ' 秒不参与统计');
  send({
    cmd: 'start',
    pid: state.selectedPid,
    name: state.selectedName || '',
    seconds,
    skip,
    warmup,
    minimize: $('#chkMin').checked,
    sound: $('#chkSound').checked,
    theme: state.themeMode,
  });
});

$('#btnExport').addEventListener('click', () => {
  if (!state.report) return;               // 没有报告时按钮本就 disabled，这里再兜一层
  send({ cmd: 'exportHtml', html: buildExportHtml() });
});

/* 导出长图：只把请求丢给宿主。**不要自己切导出视图** —— 宿主会先弹保存对话框，
   用户确认路径后才回来调 setExportView(true) 并截图，最后用 pngDone 收尾（见 bridge.js）。
   之前在这里就加 is-exporting，点击瞬间整页会被展开（看起来像窗口被放大），
   要等好几秒截完图才见到对话框。 */
$('#btnExportPng').addEventListener('click', () => {
  if (!state.report || document.documentElement.classList.contains('is-exporting')) return;
  addLog('> 正在生成报告长图…', 'ln-accent');
  send({ cmd: 'exportPng' });
});
$('#btnOpen').addEventListener('click', () => send({ cmd: 'openReports' }));

$('#btnStop').addEventListener('click', () => {
  if (!state.busy) return;
  addLog('> 请求停止采集…', 'ln-accent');
  setStatus(t('status.stopping', '正在停止…'));
  $('#btnStop').disabled = true;
  send({ cmd: 'stop' });
});

function saveSettings() {
  const skip = $$('.collect-grid input').filter(el => !el.checked).map(el => el.dataset.skip).join(',');
  send({
    cmd: 'saveSettings',
    settings: {
      seconds: parseInt($('#seconds').value, 10) || 120,
      minimize: $('#chkMin').checked,
      sound: $('#chkSound').checked,
      skip,
      preset: (typeof activePreset !== 'undefined' && activePreset) ? activePreset : '',
      warmup: (typeof currentWarmup === 'function') ? currentWarmup() : 0,
      theme: state.themeMode,
      language: state.language || LANG,
    },
  });
}
['#seconds', '#chkMin', '#chkSound'].forEach(sel => {
  $(sel).addEventListener('change', () => { if (sel === '#seconds') markPresetCustom(); saveSettings(); });
});
/* 勾选框是运行时渲染的，用事件委托，避免渲染顺序影响绑定 */
$('.collect-grid').addEventListener('change', () => { markPresetCustom(); saveSettings(); });

/* ── 启动 ── */

window.addEventListener('resize', () => {
  redrawCharts();      // 画布尺寸跟着变了，按缓存的系列重画（底图与悬浮几何一起更新）
});
// 深色系统主题跟随
if (window.matchMedia) {
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (state.themeMode === 'system') applyTheme('system');
  });
}

// 语言优先用宿主传来的设置，其次跟随上次保存在本地界面的选择
setLanguage((state.language || 'zh-CN'));
if (window.__syncSettingsUI) window.__syncSettingsUI(state.themeMode, LANG);
applyTranslations();

send({ cmd: 'ready' });
