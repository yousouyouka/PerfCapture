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

  // 供 applyTheme / setLanguage 反向同步按钮高亮
  window.__syncSettingsUI = function (themeMode, lang) {
    if (themeMode) syncThemeButtons(themeMode);
    if (lang) syncLangButtons(lang);
  };
})();
