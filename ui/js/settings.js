/* 设置页：外观（主题）与语言
   这里只改全局设置（theme / language），不碰采集页的任何参数。 */

(function initSettings() {
  const segTheme = document.getElementById('segTheme');
  const segLang = document.getElementById('segLang');

  function syncThemeButtons(mode) {
    if (!segTheme) return;
    segTheme.querySelectorAll('button').forEach((b) => {
      b.classList.toggle('is-active', b.dataset.themeValue === mode);
    });
  }

  function syncLangButtons(lang) {
    if (!segLang) return;
    segLang.querySelectorAll('button').forEach((b) => {
      b.classList.toggle('is-active', b.dataset.lang === lang);
    });
  }

  if (segTheme) {
    segTheme.addEventListener('click', (e) => {
      const btn = e.target.closest('button[data-theme-value]');
      if (!btn) return;
      const mode = btn.dataset.themeValue;
      syncThemeButtons(mode);
      applyTheme(mode);
      if (typeof saveSettings === 'function') saveSettings();
    });
  }

  if (segLang) {
    segLang.addEventListener('click', (e) => {
      const btn = e.target.closest('button[data-lang]');
      if (!btn) return;
      const lang = btn.dataset.lang;
      syncLangButtons(lang);
      setLanguage(lang);
      if (typeof saveSettings === 'function') saveSettings();
    });
  }

  /* 窗口与启动（2.2.2）：关闭到托盘 / 开机自启，切换即保存并即时生效 */
  ['chkCloseToTray', 'chkAutoStart'].forEach((id) => {
    const el = document.getElementById(id);
    if (el) el.addEventListener('change', () => { if (typeof saveSettings === 'function') saveSettings(); });
  });

  // 诊断包：只把命令丢给宿主，宿主弹保存对话框并打包日志 + 环境快照
  const diagBtn = document.getElementById('btnExportDiag');
  if (diagBtn) {
    diagBtn.addEventListener('click', () => {
      diagBtn.disabled = true;
      if (typeof send === 'function') send({ cmd: 'exportDiag' });
      setTimeout(() => { diagBtn.disabled = false; }, 1500);
    });
  }
  // 供 applyTheme / setLanguage 反向同步按钮高亮
  window.__syncSettingsUI = function (themeMode, lang) {
    if (themeMode) syncThemeButtons(themeMode);
    if (lang) syncLangButtons(lang);
  };
})();

/* ── 全局热键（2.2.2）：按钮捕获 ──
   点「开始采集 / 停止采集」按钮进入捕获态，直接按下组合键即完成设置；
   按钮平时显示当前生效的组合键。默认关闭；开启但未设置时宿主用默认键。
   捕获只接受 F1–F12 + Ctrl/Alt/Shift（宿主 VK 表一致），其它键给出明确提示。 */
(function initHotkeys() {
  const chk = document.getElementById('chkHotkeys');
  const failTxt = document.getElementById('hkFailText');
  const hintEl = document.getElementById('hkCaptureHint');
  const btns = {
    start: document.getElementById('hkStartBtn'),
    stop: document.getElementById('hkStopBtn')
  };
  if (!chk || !btns.start || !btns.stop) return;

  const DEFAULTS = {
    enabled: false,
    start: { ctrl: true, alt: true, shift: false, key: 'F9' },
    stop: { ctrl: true, alt: true, shift: false, key: 'F10' }
  };
  let cfg = {
    enabled: DEFAULTS.enabled,
    start: Object.assign({}, DEFAULTS.start),
    stop: Object.assign({}, DEFAULTS.stop)
  };
  let capturing = null;
  const hintDefault = hintEl ? hintEl.textContent : '';

  function label(c) {
    const parts = [];
    if (c.ctrl) parts.push('Ctrl');
    if (c.alt) parts.push('Alt');
    if (c.shift) parts.push('Shift');
    parts.push(String(c.key || 'F9').toUpperCase());
    return parts.join('+');
  }

  function render() {
    btns.start.textContent = label(cfg.start);
    btns.stop.textContent = label(cfg.stop);
    btns.start.classList.toggle('is-off', !cfg.enabled);
    btns.stop.classList.toggle('is-off', !cfg.enabled);
  }

  function hintText(key, fallback) {
    return (typeof t === 'function') ? t(key, fallback) : fallback;
  }

  function setHint(text) {
    if (!hintEl) return;
    /* 恢复默认文案必须走 t()：缓存的是页面初始中文，切到英/日后不能退回去 */
    hintEl.textContent = text || hintText('settings.hotkeySetHint', hintDefault);
  }

  function endCapture() {
    if (capturing && btns[capturing]) btns[capturing].classList.remove('is-capturing');
    capturing = null;
    setHint('');
  }

  function startCapture(side) {
    if (capturing === side) { endCapture(); return; }
    endCapture();
    if (!btns[side]) return;
    capturing = side;
    btns[side].classList.add('is-capturing');
    setHint(hintText('settings.hotkeyPress', '请按下新的组合键…（Esc 取消）'));
  }

  /* init 下发 s.hotkeys（enabled + start/stop 的 ctrl/alt/shift/key） */
  function apply(hk) {
    if (!hk) return;
    cfg.enabled = !!hk.enabled;
    ['start', 'stop'].forEach((side) => {
      const v = hk[side];
      if (!v) return;
      const key = String(v.key || '').toUpperCase();
      if (!/^F([1-9]|1[0-2])$/.test(key)) return;
      cfg[side] = { ctrl: !!v.ctrl, alt: !!v.alt, shift: !!v.shift, key };
    });
    chk.checked = cfg.enabled;
    render();
  }

  function update(msg) {
    /* 宿主回执（注册成功/失败）——失败红字必须能清除，不能一直挂着 */
    if (!msg || !failTxt) return;
    if (msg.ok === false && msg.fail) {
      failTxt.hidden = false;
      failTxt.textContent = msg.fail;
    } else if (msg.ok === true) {
      failTxt.hidden = true;
      failTxt.textContent = '';
    }
  }

  function push() {
    if (typeof send !== 'function') return;
    send({
      cmd: 'setHotkeys',
      enabled: cfg.enabled,
      start: Object.assign({}, cfg.start),
      stop: Object.assign({}, cfg.stop)
    });
  }

  function value() {
    return {
      enabled: cfg.enabled,
      start: Object.assign({}, cfg.start),
      stop: Object.assign({}, cfg.stop)
    };
  }

  window.PerfHotkeysUI = {
    update,
    apply,
    value,
    request: () => { if (typeof send === 'function') send({ cmd: 'getHotkeys' }); }
  };

  btns.start.addEventListener('click', (e) => { e.preventDefault(); startCapture('start'); });
  btns.stop.addEventListener('click', (e) => { e.preventDefault(); startCapture('stop'); });

  document.addEventListener('keydown', (e) => {
    if (!capturing) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.key === 'Escape') { endCapture(); return; }
    const key = String(e.key || '').toUpperCase();
    if (!/^F([1-9]|1[0-2])$/.test(key)) {
      setHint(hintText('settings.hotkeyInvalid', '只支持 F1–F12，可配合 Ctrl / Alt / Shift'));
      return;
    }
    cfg[capturing] = { ctrl: !!e.ctrlKey, alt: !!e.altKey, shift: !!e.shiftKey, key };
    endCapture();
    render();
    push();
  }, true);

  chk.addEventListener('change', () => {
    cfg.enabled = !!chk.checked;
    render();
    push();
  });

  render();
})();
