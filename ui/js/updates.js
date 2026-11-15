/* 更新公告：照 TextAxis 的 updates 页组织
   版本条（主.次 + 发布日期）/ 分类筛选（= 改动方向）/ 左侧日期栏（年月分组 → 月日，发布日带版本徽标）/ 条目。
   分类不再是侧边栏功能区：新功能 / 界面优化 / 交互体验 / 问题修复 / 采集与判定 / 图表与报告 /
   安装与分发 / 兼容与性能 / 问卷调查。只换字体与配色（tokens），版块与尺寸按 TextAxis。 */

const UPDATES_ALL = '__all__';

(function initUpdates() {
  const entries = Array.isArray(window.PerfUpdates) ? window.PerfUpdates : [];
  const versions = Array.isArray(window.PerfUpdateVersions) ? window.PerfUpdateVersions : [];
  if (!entries.length) return;

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };
  const tx = (key, fallback) => (typeof t === 'function' ? t(key, fallback) : fallback);
  const fill = (tpl, params) => Object.keys(params).reduce((s, k) => s.split('{' + k + '}').join(params[k]), tpl);

  const box = document.getElementById('updatesEntries');
  const versionsBox = document.getElementById('updatesVersions');
  const datesBox = document.getElementById('updatesDates');
  const filtersBox = document.getElementById('updatesFilters');
  const areasBox = document.getElementById('updatesAreas');
  const scroller = document.getElementById('updatesScroll');
  const currentBox = document.getElementById('updatesCurrent');
  if (!box || !versionsBox || !datesBox || !filtersBox || !areasBox || !scroller) return;

  const ymd = (d) => d.split('-').join('.');
  const majorMinor = (v) => String(v).split('.').slice(0, 2).join('.');

  // 分类（改动方向）：顺序由数据里的 PerfUpdateCategories 决定，展示名走 i18n 的 updates.cat.*
  function categories() {
    const list = Array.isArray(window.PerfUpdateCategories) ? window.PerfUpdateCategories : [];
    return list.map((k) => ({ key: k, label: tx('updates.cat.' + k, k) }));
  }
  function catLabel(key) {
    const hit = categories().find((c) => c.key === key);
    return hit ? hit.label : key;
  }

  // 板块（性能采集 / 实时监控 / 其他）：顺序由 PerfUpdateAreas 决定，展示名走 updates.area.*
  function areaOptions() {
    const list = Array.isArray(window.PerfUpdateAreas) ? window.PerfUpdateAreas : [];
    return list.map((k) => ({ key: k, label: tx('updates.area.' + k, k) }));
  }

  let activeCat = UPDATES_ALL;
  let activeArea = UPDATES_ALL;
  let sections = [];

  function releaseOfDate(date) {
    const hit = versions.find((v) => v.date === date);
    return hit ? hit.version : '';
  }

  function jump(date) {
    const target = box.querySelector('[data-date="' + date + '"]');
    if (!target) return;
    // 直接算目标在滚动容器里的位置再赋值（不依赖 scroll-behavior，点一下就到，不会停在半路）
    const offset = target.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
    scroller.scrollTop = Math.max(0, offset - 8);
    syncScroll();
  }

  // 左侧日期栏：年月大分支 → 月日小分支（发布日右侧带 v1.x 徽标）
  function renderDates(list) {
    datesBox.innerHTML = '';
    let group = '';
    // 同一天有多条改动时，日期栏只留一行（版本徽标按版本线给）
    const seen = new Set();
    list.filter((e) => { if (seen.has(e.date)) return false; seen.add(e.date); return true; }).forEach((e) => {
      const ym = e.date.slice(0, 4) + '-' + e.date.slice(5, 7);
      if (ym !== group) {
        group = ym;
        const wrap = el('div', 'date-month');
        wrap.appendChild(el('h3', '', fill(tx('updates.monthLabel', '{y} 年 {m} 月'), {
          y: e.date.slice(0, 4), m: String(Number(e.date.slice(5, 7)))
        })));
        const grid = el('div', 'date-grid');
        wrap.appendChild(grid);
        datesBox.appendChild(wrap);
        datesBox.dataset.lastGrid = String(datesBox.children.length - 1);
      }
      const grid = datesBox.children[datesBox.children.length - 1].querySelector('.date-grid');
      const link = el('button', 'date-link');
      link.type = 'button';
      link.dataset.date = e.date;
      link.appendChild(el('span', 'date-day', fill(tx('updates.dayLabel', '{m} 月 {d} 日'), {
        m: String(Number(e.date.slice(5, 7))), d: String(Number(e.date.slice(8, 10)))
      })));
      const rel = releaseOfDate(e.date);
      if (rel) link.appendChild(el('span', 'date-release', 'v' + rel));
      link.addEventListener('click', () => jump(e.date));
      grid.appendChild(link);
    });
  }

  // 板块筛选（性能采集 / 实时监控 / 其他）：只用于筛选，条目不显示板块标签
  function renderAreaOptions() {
    areasBox.innerHTML = '';
    areasBox.appendChild(el('span', 'updates-filter-label', tx('updates.filterArea', '板块')));
    const all = el('button', '', tx('updates.allAreas', '全部板块'));
    all.type = 'button';
    all.setAttribute('aria-pressed', String(activeArea === UPDATES_ALL));
    all.addEventListener('click', () => { activeArea = UPDATES_ALL; render(); });
    areasBox.appendChild(all);
    areaOptions().forEach((a) => {
      const b = el('button', '', a.label);
      b.type = 'button';
      b.setAttribute('aria-pressed', String(activeArea === a.key));
      b.addEventListener('click', () => { activeArea = a.key; render(); });
      areasBox.appendChild(b);
    });
  }

  // 分类筛选：全部更新 + 改动方向（顺序与名称由 PerfUpdateCategories + i18n 决定）
  // 与上面的板块筛选同时生效，两个条件取交集
  function renderFilters() {
    filtersBox.innerHTML = '';
    filtersBox.appendChild(el('span', 'updates-filter-label', tx('updates.filterKind', '分类')));
    const all = el('button', '', tx('updates.all', '全部更新'));
    all.type = 'button';
    all.setAttribute('aria-pressed', String(activeCat === UPDATES_ALL));
    all.addEventListener('click', () => { activeCat = UPDATES_ALL; render(); });
    filtersBox.appendChild(all);
    categories().forEach((a) => {
      const b = el('button', '', a.label);
      b.type = 'button';
      b.setAttribute('aria-pressed', String(activeCat === a.key));
      b.addEventListener('click', () => { activeCat = a.key; render(); });
      filtersBox.appendChild(b);
    });
  }

  // 版本条：只显示「主.次」+ 发布日期
  function renderVersions() {
    versionsBox.innerHTML = '';
    versions.forEach((v) => {
      const b = el('button', 'version-link');
      b.type = 'button';
      b.dataset.version = v.version;
      b.dataset.date = v.date;
      b.setAttribute('aria-pressed', 'false');
      b.appendChild(el('span', 'version-number', v.version));
      b.appendChild(el('span', 'version-date', ymd(v.date)));
      b.addEventListener('click', () => {
        const hit = entries.find((e) => majorMinor(e.version) === v.version);
        if (hit) jump(hit.date);
      });
      versionsBox.appendChild(b);
    });
  }

  function render() {
    renderAreaOptions();
    renderFilters();
    box.innerHTML = '';
    sections = [];
    // 两个筛选同时生效：分类 ∩ 板块（板块是 items[2]，缺省按 other）
    const shown = entries
      .map((e) => Object.assign({}, e, {
        items: e.items.filter((it) =>
          (activeCat === UPDATES_ALL || it[0] === activeCat) &&
          (activeArea === UPDATES_ALL || (it[2] || 'other') === activeArea))
      }))
      .filter((e) => e.items.length);
    renderDates(shown);

    if (!shown.length) {
      box.appendChild(el('div', 'updates-empty', tx('updates.empty', '该分类下暂无记录')));
      return;
    }

    const newest = shown[0].version;
    shown.forEach((e) => {
      const sec = el('section', 'update-entry');
      sec.id = 'update-' + e.date + '-' + e.version;
      sec.dataset.date = e.date;
      sec.dataset.majorMinor = majorMinor(e.version);

      const head = el('div', 'update-heading');
      const time = el('time', '', ymd(e.date));
      time.dateTime = e.date;
      head.appendChild(time);
      const vbadge = el('span', 'version-badge release', 'v' + e.version);
      head.appendChild(vbadge);
      if (e.version === newest) head.appendChild(el('span', 'latest', tx('updates.latest', '最新')));
      sec.appendChild(head);
      sec.appendChild(el('h2', '', e.title));

      const ul = el('ul');
      e.items.forEach((it) => {
        const li = el('li');
        li.appendChild(el('span', 'category', catLabel(it[0])));
        li.appendChild(el('p', 'update-copy', it[1]));
        ul.appendChild(li);
      });
      sec.appendChild(ul);
      box.appendChild(sec);
      sections.push(sec);
    });
    syncScroll();
  }

  // 滚动联动：高亮当前条目对应的日期与版本线
  function syncScroll() {
    if (!sections.length) return;
    const top = scroller.getBoundingClientRect().top + 24;
    let current = sections[0];
    for (const s of sections) {
      if (s.getBoundingClientRect().top <= top) current = s; else break;
    }
    const date = current.dataset.date;
    const minor = current.dataset.majorMinor;
    datesBox.querySelectorAll('.date-link').forEach((a) => {
      a.classList.toggle('active', a.dataset.date === date);
    });
    versionsBox.querySelectorAll('.version-link').forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.version === minor));
    });
  }

  const newestMinor = versions.length ? versions[0].version : majorMinor(entries[0].version);
  if (currentBox) currentBox.textContent = 'v' + newestMinor;
  renderVersions();
  render();
  scroller.addEventListener('scroll', syncScroll, { passive: true });

  // 语言切换后重画（筛选项来自 i18n 的 updates.cat.*，必须按新语言重读）
  window.__refreshUpdates = render;
})();
