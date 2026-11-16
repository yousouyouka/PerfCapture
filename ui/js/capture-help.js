/* 性能采集 →「详细说明」弹窗（批次 C 建，2.0.6 按评审补齐）
   内容来源：
     · 静态段落走 i18n（capture.help.*）
     · 「板块分别干什么」「各指标怎么统计」读宿主下发的指标字典 window.PerfMetricsDoc
     · 「暂不可用」同样走字典（metrics[].status=na + reasons 三语）
     · 「三个档位」读 capture-options 里已加载的 presets（说明文字走 i18n，参数是实测值） */
(function initCaptureHelp() {
  const byId = (id) => document.getElementById(id);
  const modal = byId('capHelpModal');
  const btnOpen = byId('capBtnHelp') || byId('btnCapHelp');
  const btnClose = byId('capHelpClose');
  const body = byId('capHelpBody');
  if (!modal || !btnOpen) return;

  const tx = (k, fb) => (typeof t === 'function' ? t(k, fb) : fb);
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

  /* 当前语言 → 字典里的 zh/en/ja */
  function langKey() {
    const l = (typeof LANG === 'string' && LANG) || 'zh-CN';
    if (l.indexOf('en') === 0) return 'en';
    if (l.indexOf('ja') === 0) return 'ja';
    return 'zh';
  }
  const pick = (o, keyZh, keyEn, keyJa) => {
    const l = langKey();
    if (l === 'en') return o[keyEn] || o.zh;
    if (l === 'ja') return o[keyJa] || o.zh;
    return o[keyZh] || o.zh;
  };

  const section = (title) => '<h4>' + esc(title) + '</h4>';

  /* ── ③ 三个档位：说明文字照搬原文（i18n 多行文本），参数用已加载的预设 ── */
  function tierHtml() {
    const presets = (typeof capturePresets !== 'undefined' && Array.isArray(capturePresets)) ? capturePresets : [];
    if (!presets.length) return '';
    /* 三档只影响「可选采集」：核心项关不掉、派生项本来就自动算，
       所以这里数的是可关闭的输入框，别把锁定项算进分母 */
    const optInputs = [...document.querySelectorAll('.collect-grid input')].filter(el => !el.disabled);
    const total = optInputs.length;
    const coreCount = document.querySelectorAll('.collect-grid input[data-always="1"]').length;
    const derivedCount = document.querySelectorAll('.collect-grid .check.is-derived').length;
    const expand = (typeof expandSkip === 'function') ? expandSkip : (k) => k;
    let h = '<ul class="cap-help-list cap-help-tiers">';
    presets.forEach((p) => {
      if (!p || !p.id) return;
      const skip = expand(Array.isArray(p.skip) ? p.skip.join(',') : '').filter(Boolean);
      const kept = total > 0 ? Math.max(0, total - skip.length) : null;
      const slots = total + coreCount;                 // 核心项永远算进来
      const got = kept == null ? null : kept + coreCount;
      const lines = String(tx('capture.help.tier.' + p.id, '') || '').split('\n').map((s) => s.trim()).filter(Boolean);
      const goal = (lines.length && lines[0].charAt(0) !== '-') ? lines.shift() : '';
      const bullets = lines.filter((s) => s.charAt(0) === '-').map((s) => s.slice(1).trim());
      const tail = lines.filter((s) => s.charAt(0) !== '-').join(' ');

      h += '<li><div class="cap-help-tier-name">' +
           esc(tx('capture.help.tierTitle.' + p.id, tx(p.label || p.id, String(p.id)))) + '</div>';
      h += '<div class="cap-help-meta">' + esc(fillParams(
        tx('capture.help.tierMeta', '{s} 秒 · 预热 {w} 秒'), { s: p.seconds, w: p.warmup || 0 })) +
        (got != null ? ' · ' + esc(fillParams(tx('capture.help.tierCount', '采集 {n} / {m} 项'), { n: got, m: slots })) : '') +
        (derivedCount > 0 ? ' · ' + esc(fillParams(tx('capture.help.tierDerived', '另 {d} 项自动计算'), { d: derivedCount })) : '') + '</div>';
      if (goal) h += '<div class="cap-help-tier-goal">' + esc(goal) + '</div>';
      if (bullets.length) {
        h += '<ul class="cap-help-tier-list">' + bullets.map((b) => '<li>' + esc(b) + '</li>').join('') + '</ul>';
      }
      if (tail) h += '<div class="cap-help-why">' + esc(tail) + '</div>';
      if (skip.length) {
        const names = skip.map((k) => tx('capture.item.' + k, k)).join(' / ');
        h += '<div class="cap-help-why">' + esc(fillParams(tx('capture.help.tierSkip', '不采：{list}'), { list: names })) + '</div>';
      } else {
        h += '<div class="cap-help-why">' + esc(tx('capture.help.tierAll', '全部采集项都采')) + '</div>';
      }
      h += '</li>';
    });
    h += '</ul>';
    h += '<p class="cap-help-note">' + esc(tx('capture.help.classes', '')) + '</p>';
    h += '<p class="cap-help-note">' + esc(tx('capture.help.tiers', '')) + '</p>';
    return h;
  }

  /* ── ④ 各板块指标与统计方式：直接读字典（名称三语 + stat），不另写一份清单 ── */
  function statsHtml(doc) {
    if (!doc || !Array.isArray(doc.modules) || !Array.isArray(doc.metrics)) return '';
    let h = '';
    doc.modules.forEach((m) => {
      const list = doc.metrics.filter((x) => x && x.module === m.id);
      if (!list.length) return;
      h += '<div class="cap-help-stats-block"><div class="cap-help-stats-mod">' +
           esc(pick(m, 'nameZh', 'nameEn', 'nameJa')) + '</div><ul class="cap-help-stat-list">';
      list.forEach((x) => {
        const nm = pick(x, 'nameZh', 'nameEn', 'nameJa');
        const en = (x.nameEn && langKey() === 'zh') ? '（' + esc(x.nameEn) + '）' : '';
        const st = tx('capture.help.stat.' + (x.stat || 'avg'), x.stat || '');
        const na = x.status === 'na'
          ? '<span class="cap-help-badge">' + esc(tx('capture.help.naBadge', '暂不可用')) + '</span>' : '';
        h += '<li><span class="n">' + esc(nm) + en + '</span><span class="s">' + esc(st) + na + '</span></li>';
      });
      h += '</ul></div>';
    });
    return h;
  }

  function render() {
    if (!body) return;
    const doc = window.PerfMetricsDoc || null;
    let html = '';

    /* ① 这份报告能回答什么（五个问题） */
    html += '<p class="cap-help-lead">' + esc(tx('capture.help.intro', '')) + '</p>';

    /* ② 七个板块分别干什么 */
    if (doc && Array.isArray(doc.modules) && doc.modules.length) {
      html += section(tx('capture.help.modulesTitle', '报告包含这些板块'));
      html += '<ul class="cap-help-list cap-help-modules">';
      doc.modules.forEach((m) => {
        const d = pick(m, 'descZh', 'descEn', 'descJa') || '';
        html += '<li><b>' + esc(pick(m, 'nameZh', 'nameEn', 'nameJa')) + '</b>' +
                (d ? '<div class="cap-help-why">' + esc(d) + '</div>' : '') + '</li>';
      });
      html += '</ul>';
    }

    /* ③ 三个档位怎么选 */
    const tiers = tierHtml();
    if (tiers) {
      html += section(tx('capture.help.tiersTitle', '三个档位怎么选'));
      html += tiers;
    }

    /* ④ 数值怎么读：一段口径说明 + 各板块指标与统计方式 */
    html += section(tx('capture.help.readTitle', '数值怎么读'));
    html += '<p class="cap-help-note">' + esc(tx('capture.help.read', '')) + '</p>';
    const stats = statsHtml(doc);
    if (stats) {
      html += '<div class="cap-help-sub">' + esc(tx('capture.help.statsTitle', '各板块指标与统计方式')) + '</div>';
      html += stats;
    }

    /* ⑤ 为什么有「暂不可用」：逐条写原因，绝不填 0 */
    if (doc && Array.isArray(doc.metrics)) {
      const na = doc.metrics.filter((m) => m && m.status === 'na');
      if (na.length) {
        html += section(tx('capture.help.naTitle', '暂时不可用的指标（以及原因）'));
        html += '<p class="cap-help-note">' + esc(tx('capture.help.naHint', '')) + '</p>';
        html += '<ul class="cap-help-list cap-help-na">';
        na.forEach((m) => {
          const reason = (doc.reasons && doc.reasons[m.reason]) ? pick(doc.reasons[m.reason], 'zh', 'en', 'ja') : '';
          html += '<li><b>' + esc(pick(m, 'nameZh', 'nameEn', 'nameJa')) + '</b>' +
                  '<span class="cap-help-badge">' + esc(tx('capture.help.naBadge', '暂不可用')) + '</span>' +
                  (reason ? '<div class="cap-help-why">' + esc(reason) + '</div>' : '') + '</li>';
        });
        html += '</ul>';
      }
    }

    /* ⑥ 测试时请注意 */
    html += section(tx('capture.help.tipsTitle', '测试时请注意'));
    html += '<p class="cap-help-note">' + esc(tx('capture.help.tips', '')) + '</p>';

    /* ⑦ 隐私 */
    html += section(tx('capture.help.privacyTitle', '隐私'));
    html += '<p class="cap-help-note cap-help-privacy">' + esc(tx('capture.help.privacy', '')) + '</p>';

    body.innerHTML = html;
  }

  const open = () => {
    render();
    modal.hidden = false;
    try { if (btnClose) btnClose.focus(); } catch (e) { }
  };
  const close = () => { modal.hidden = true; };

  btnOpen.addEventListener('click', open);
  if (btnClose) btnClose.addEventListener('click', close);
  modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !modal.hidden) { e.stopPropagation(); close(); }
  });

  window.PerfCaptureHelp = { open: open, close: close, render: render };
})();
