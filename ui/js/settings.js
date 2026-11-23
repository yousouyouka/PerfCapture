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

/* ── 全局热键（2.2.1）：放在采集设置里，可自定义键位 ──
   状态以宿主为准：注册成功与否由宿主回传，前端不自己猜。
   默认关闭；开启但未设置时宿主使用默认组合键（开始 Ctrl+Alt+F9 / 停止 Ctrl+Alt+F10）。 */
(function initHotkeys() {
  const chk = document.getElementById('chkHotkeys');
  const failTxt = document.getElementById('hkFailText');
  const rows = [
    { side: 'start', ctrl: 'hkStartCtrl', alt: 'hkStartAlt', shift: 'hkStartShift', key: 'hkStartKey' },
    { side: 'stop', ctrl: 'hkStopCtrl', alt: 'hkStopAlt', shift: 'hkStopShift', key: 'hkStopKey' }
  ];
  const KEYS = ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'];

  // 键位下拉框：F1–F12（避开与输入法/组合键冲突的组合，见 2.1.16 规则）
  rows.forEach((r) => {
    const sel = document.getElementById(r.key);
    if (!sel || sel.options.length) return;
    KEYS.forEach((k) => {
      const o = document.createElement('option');
      o.value = k; o.textContent = k;
      sel.appendChild(o);
    });
  });

  function readSide(r) {
    return {
      ctrl: document.getElementById(r.ctrl).checked,
      alt: document.getElementById(r.alt).checked,
      shift: document.getElementById(r.shift).checked,
      key: document.getElementById(r.key).value || 'F9'
    };
  }
  function writeSide(r, c) {
    if (!c) return;
    document.getElementById(r.ctrl).checked = !!c.ctrl;
    document.getElementById(r.alt).checked = !!c.alt;
    document.getElementById(r.shift).checked = !!c.shift;
    const sel = document.getElementById(r.key);
    const k = String(c.key || '').toUpperCase();
    if (sel && KEYS.includes(k)) sel.value = k;
  }

  /* init 下发 s.hotkeys（enabled + start/stop 的 ctrl/alt/shift/key） */
  function apply(hk) {
    if (!hk) return;
    if (chk && hk.enabled != null) chk.checked = !!hk.enabled;
    rows.forEach((r) => writeSide(r, hk[r.side]));
  }

  function update(msg) {
    /* 宿主回执（注册成功/失败）——旧消息只有展示文本，仅用于失败提示 */
    if (!msg || !failTxt) return;
    if (msg.ok === false && msg.fail) {
      failTxt.hidden = false;
      failTxt.textContent = msg.fail;
    } else if (msg.ok === true) {
      /* 冲突解决后要把红字清掉，不能让它一直挂着 */
      failTxt.hidden = true;
      failTxt.textContent = '';
    }
  }

  function push() {
    if (typeof send !== 'function') return;
    send({
      cmd: 'setHotkeys',
      enabled: !!(chk && chk.checked),
      start: readSide(rows[0]),
      stop: readSide(rows[1])
    });
  }

  window.PerfHotkeysUI = { update, apply, request: () => { if (typeof send === 'function') send({ cmd: 'getHotkeys' }); } };

  const inputs = ['chkHotkeys', 'hkStartCtrl', 'hkStartAlt', 'hkStartShift', 'hkStartKey',
    'hkStopCtrl', 'hkStopAlt', 'hkStopShift', 'hkStopKey'];
  inputs.forEach((id) => {
    const el = document.getElementById(id);
    if (el) el.addEventListener('change', push);
  });
})();
