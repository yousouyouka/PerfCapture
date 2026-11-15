/* 主题切换 */

/* ── 主题 ── */
function applyTheme(mode) {
  state.themeMode = mode;
  const light = mode === 'light' ||
    (mode === 'system' && (!window.matchMedia || !window.matchMedia('(prefers-color-scheme: dark)').matches));
  document.documentElement.dataset.theme = light ? 'light' : 'dark';
  const themeBtn = $('#btnTheme');
  if (themeBtn) themeBtn.textContent = t('theme.' + (mode || 'system'), '跟随系统');
  if (window.__syncSettingsUI) window.__syncSettingsUI(mode);
  if (state.report) renderReport(state.report);
}

