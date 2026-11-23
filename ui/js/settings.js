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

/* ── 全局热键（2.1.16）──
   状态以宿主为准：注册成功与否由宿主回传，前端不自己猜。
   这里只做「开关」与「显示组合键」，不提供自定义键位——避免用户编出与输入法冲突的组合。 */
(function initHotkeys() {
  const chk = document.getElementById('chkHotkeys');
  const sLab = document.getElementById('hkStartLabel');
  const eLab = document.getElementById('hkStopLabel');
  const failRow = document.getElementById('hkFailRow');
  const failTxt = document.getElementById('hkFailText');

  function update(msg) {
    if (!msg) return;
    if (chk && msg.enabled != null) chk.checked = !!msg.enabled;
    if (sLab && msg.start) sLab.textContent = msg.start;
    if (eLab && msg.stop) eLab.textContent = msg.stop;
    if (failRow && failTxt) {
      const bad = msg.ok === false && msg.fail;
      failRow.hidden = !bad;
      failTxt.textContent = bad ? msg.fail : '';
    }
  }

  window.PerfHotkeysUI = {
    update,
    request: () => { if (typeof send === 'function') send({ cmd: 'getHotkeys' }); },
  };

  if (chk) {
    chk.addEventListener('change', () => {
      if (typeof send === 'function') send({ cmd: 'setHotkeys', enabled: chk.checked });
    });
  }
})();
