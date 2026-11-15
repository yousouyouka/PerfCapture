/* 侧边栏：页面切换 + 折叠状态持久化
   折叠状态属于纯界面偏好，存 localStorage（WebView2 的 user data folder 会保留）。 */

const SIDEBAR_KEY = 'perf.sidebar.collapsed';

function showPage(name) {
  const items = document.querySelectorAll('.nav-item');
  const pages = document.querySelectorAll('.page');
  let matched = false;
  items.forEach((b) => {
    const on = b.dataset.page === name;
    b.classList.toggle('is-active', on);
    if (on) matched = true;
  });
  if (!matched) name = 'capture';
  pages.forEach((p) => { p.hidden = p.dataset.page !== name; });
}

function setSidebarCollapsed(collapsed) {
  const app = document.getElementById('app');
  if (!app) return;
  app.classList.toggle('is-collapsed', !!collapsed);
  try { localStorage.setItem(SIDEBAR_KEY, collapsed ? '1' : '0'); } catch (e) { /* 隐私模式忽略 */ }
}

(function initSidebar() {
  document.querySelectorAll('.nav-item').forEach((btn) => {
    btn.addEventListener('click', () => showPage(btn.dataset.page));
  });

  const toggle = document.getElementById('sidebarToggle');
  if (toggle) {
    toggle.addEventListener('click', () => {
      const app = document.getElementById('app');
      setSidebarCollapsed(!app.classList.contains('is-collapsed'));
    });
  }

  let collapsed = false;
  try { collapsed = localStorage.getItem(SIDEBAR_KEY) === '1'; } catch (e) { }
  if (collapsed) {
    const app = document.getElementById('app');
    if (app) app.classList.add('is-collapsed');
  }
})();
