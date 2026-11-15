/* 问卷调查：纯前端渲染（本轮无后端提交）
   数据在 ui/js/survey-data.js 的 window.PerfSurveys；语言切换后由 __refreshSurvey 重画。
   排版：页头（eyebrow / 标题 + 进行中计数 / 说明）→ 卡片列表（标题 + 状态徽标 → 说明 → 题量 ·
   预计时长 · 日期 → 「开始填写」）；没有数据时显示「暂无问卷」。 */

(function initSurvey() {
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };
  const tx = (key, fallback) => (typeof t === 'function' ? t(key, fallback) : fallback);
  const fill = (tpl, params) => Object.keys(params).reduce((s, k) => s.split('{' + k + '}').join(params[k]), tpl);

  const list = document.getElementById('surveyList');
  const countEl = document.getElementById('surveyCount');
  if (!list) return;

  const items = () => (Array.isArray(window.PerfSurveys) ? window.PerfSurveys : []);

  // 一张问卷卡片：本轮只定样式与字段布局，不做填写页
  function card(s) {
    const art = el('article', 'survey-card');
    if (s.id) art.dataset.survey = s.id;

    const closed = s.status === 'closed';
    const head = el('div', 'survey-card-head');
    head.appendChild(el('h2', '', s.title || ''));
    head.appendChild(el('span', 'survey-status ' + (closed ? 'is-closed' : 'is-open'),
      tx(closed ? 'survey.status.closed' : 'survey.status.open', closed ? '已结束' : '进行中')));
    art.appendChild(head);

    if (s.desc) art.appendChild(el('p', 'survey-desc', s.desc));

    const meta = el('div', 'survey-meta');
    if (s.questions) meta.appendChild(el('span', '', fill(tx('survey.metaQuestions', '{n} 道题'), { n: s.questions })));
    if (s.minutes) meta.appendChild(el('span', '', fill(tx('survey.metaMinutes', '约 {m} 分钟'), { m: s.minutes })));
    if (s.date) meta.appendChild(el('span', '', s.date));
    if (meta.children.length) art.appendChild(meta);

    const actions = el('div', 'survey-actions');
    const go = el('button', 'btn btn-primary', tx('survey.open', '开始填写'));
    go.type = 'button';
    // 没有链接 = 还没开放：按钮可见但禁用；接后端后填 url 或换成提交流程
    if (!s.url) {
      go.disabled = true;
      go.title = tx('survey.notReady', '暂未开放');
    } else {
      go.addEventListener('click', () => { try { window.open(s.url, '_blank'); } catch (e) { } });
    }
    actions.appendChild(go);
    art.appendChild(actions);
    return art;
  }

  function render() {
    const all = items();
    list.innerHTML = '';
    const open = all.filter((s) => s.status !== 'closed').length;
    if (countEl) countEl.textContent = fill(tx('survey.count', '{n} 份进行中'), { n: open });

    if (!all.length) {
      const empty = el('div', 'survey-empty');
      empty.appendChild(el('strong', '', tx('survey.emptyTitle', '暂无问卷')));
      empty.appendChild(el('p', '', tx('survey.emptyHint', '有新问卷时，这里会出现入口。')));
      list.appendChild(empty);
      return;
    }
    all.forEach((s) => list.appendChild(card(s)));
  }

  render();
  window.__refreshSurvey = render;
})();
