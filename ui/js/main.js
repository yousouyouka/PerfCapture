/* 事件绑定与启动 */

/* ── 事件绑定 ── */
/* 主题切换已移到设置页；顶栏不再有全局设置入口 */


/* ── 每游戏记忆（2.1.16 / F3-2）──
   只记「上次怎么采的」：秒数、勾选项、预热。存 localStorage（界面偏好，与采集数据无关）；
   读不到或结构不对就当没有记录，不抛错、不覆盖用户当前设置。 */
const GAME_PREFS_KEY = 'perf.gamePrefs';
function loadGamePrefs() {
  try {
    const o = JSON.parse(localStorage.getItem(GAME_PREFS_KEY) || '{}');
    return (o && typeof o === 'object') ? o : {};
  } catch (e) { return {}; }
}
function saveGamePref(name, pref) {
  if (!name || !pref) return;
  const all = loadGamePrefs();
  all[name] = pref;
  try { localStorage.setItem(GAME_PREFS_KEY, JSON.stringify(all)); } catch (e) { }
}
/** 把上次该游戏的参数套回界面；没有记录就什么都不做 */
function applyGamePref(name) {
  const pref = name ? loadGamePrefs()[name] : null;
  if (!pref) return;
  if (Number.isFinite(Number(pref.seconds)) && pref.seconds >= 10) $('#seconds').value = pref.seconds;
  if (Array.isArray(pref.checked)) {
    $$('.collect-grid input').forEach((el) => {
      if (!el.disabled) el.checked = pref.checked.indexOf(el.dataset.skip) >= 0;
    });
  }
}
function currentPref() {
  return {
    seconds: parseInt($('#seconds').value, 10) || 180,
    checked: $$('.collect-grid input').filter((el) => el.checked && !el.disabled).map((el) => el.dataset.skip),
  };
}
window.PerfApplyGamePrefs = applyGamePref;
/* 热键动作：宿主只负责报「按了哪个键」，这里复用按钮自己的校验与忙碌判断 */
window.PerfHotkeyAction = function (action) {
  const btn = action === 'stop' ? $('#btnStop') : $('#btnStart');
  if (btn && !btn.disabled && !btn.hidden) { btn.click(); return; }
  if (action === 'stop' && $('#btnStop') && !$('#btnStop').hidden) $('#btnStop').click();
};

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
    applyGamePref(it.name);
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
  saveGamePref(state.selectedName || state.selectedText, currentPref());
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
      seconds: parseInt($('#seconds').value, 10) || 180,
      minimize: $('#chkMin').checked,
      sound: $('#chkSound').checked,
      skip,
      preset: (typeof activePreset !== 'undefined' && activePreset) ? activePreset : '',
      customBase: (typeof currentCustomBase === 'function') ? currentCustomBase() : 'standard',
      warmup: (typeof currentWarmup === 'function') ? currentWarmup() : 0,
      theme: state.themeMode,
      language: state.language || LANG,
      netAlertDayMB: parseInt($('#netAlertDay').value, 10) || 0,
      netAlertMonthMB: parseInt($('#netAlertMonth').value, 10) || 0,
      netKeepDays: parseInt($('#netKeepDays').value, 10) || 400,
      netAlertIfMB: (window.PerfNetwork && window.PerfNetwork.alertIfValue)
        ? window.PerfNetwork.alertIfValue() : {},
      webhook: {
        enabled: !!$('#chkWebhook').checked,
        url: ($('#webhookUrl').value || '').trim(),
        capture: !!$('#chkWebhookCapture').checked,
        netAlert: !!$('#chkWebhookNet').checked,
      },
      netReverseDns: !!$('#chkNetDns').checked,
      closeToTray: !!$('#chkCloseToTray').checked,
      autoStart: !!$('#chkAutoStart').checked,
      hotkeys: (window.PerfHotkeysUI && window.PerfHotkeysUI.value)
        ? window.PerfHotkeysUI.value()
        : {
          enabled: false,
          start: { ctrl: true, alt: true, shift: false, key: 'F9' },
          stop: { ctrl: true, alt: true, shift: false, key: 'F10' }
        }
    },
  });
}
['#seconds', '#chkMin', '#chkSound'].forEach(sel => {
  $(sel).addEventListener('change', () => { if (sel === '#seconds') markPresetCustom(); saveSettings(); });
});
['#netAlertDay', '#netAlertMonth', '#netKeepDays'].forEach(sel => {
  $(sel).addEventListener('change', () => saveSettings());
});
const netDnsEl = $('#chkNetDns');
if (netDnsEl) netDnsEl.addEventListener('change', () => saveSettings());
/* webhook（2.2.11）：开关 / URL / 事件勾选改动即保存；测试按钮走宿主命令 */
['#chkWebhook', '#chkWebhookCapture', '#chkWebhookNet'].forEach(sel => {
  const el = $(sel);
  if (el) el.addEventListener('change', () => saveSettings());
});
const whUrlEl = $('#webhookUrl');
if (whUrlEl) whUrlEl.addEventListener('change', () => saveSettings());
const whTestEl = $('#btnWebhookTest');
if (whTestEl) whTestEl.addEventListener('click', () => {
  const n = $('#webhookNote');
  if (n) { n.textContent = t('settings.webhookSending', '正在发送…'); n.className = 'webhook-note'; }
  send({ cmd: 'testWebhook' });
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
// setLanguage 内部已调用 applyTranslations（并触发各 __refresh 回调），不要再来第二遍
setLanguage((state.language || 'zh-CN'));
if (window.__syncSettingsUI) window.__syncSettingsUI(state.themeMode, LANG);

/* 再采一次：参数与目标都还在界面上，等同于点一次开始（校验与忙碌判断走同一段代码） */
const btnRerun = document.getElementById('btnRerun');
if (btnRerun) btnRerun.addEventListener('click', () => { if (!btnRerun.disabled) $('#btnStart').click(); });

send({ cmd: 'ready' });
