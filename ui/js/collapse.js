/* 卡片折叠：标题右侧的箭头按钮收起卡片正文，状态记在 localStorage 里，重启后保持。
   需要折叠的卡片在 HTML 上写 data-collapse="唯一键" 即可，无需改这里的代码。 */

const COLLAPSE_KEY = 'perf.collapsed';

function loadCollapsed() {
  try {
    const v = JSON.parse(localStorage.getItem(COLLAPSE_KEY) || '[]');
    return Array.isArray(v) ? v.map(String) : [];
  } catch (e) {
    return [];
  }
}

function saveCollapsed(list) {
  try { localStorage.setItem(COLLAPSE_KEY, JSON.stringify(list)); } catch (e) { /* 隐私模式等：忽略 */ }
}

function applyCollapse(card, collapsed) {
  card.classList.toggle('is-collapsed', collapsed);
  const btn = card.querySelector('.card-toggle');
  if (btn) btn.setAttribute('aria-expanded', String(!collapsed));
}

function initCollapse() {
  const collapsed = loadCollapsed();
  $$('.card[data-collapse]').forEach((card) => {
    const key = String(card.dataset.collapse);
    applyCollapse(card, collapsed.includes(key));

    const btn = card.querySelector('.card-toggle');
    if (!btn) return;
    btn.addEventListener('click', () => {
      const next = !card.classList.contains('is-collapsed');
      applyCollapse(card, next);
      const list = loadCollapsed().filter(k => k !== key);
      if (next) list.push(key);
      saveCollapsed(list);
    });
  });
}

initCollapse();
