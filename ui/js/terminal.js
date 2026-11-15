/* 终端日志 */

/* ── 终端 ── */
const termEl = $('#term');
const termLines = [];
function addLog(text, cls) {
  for (const line of String(text).split(/\r?\n/)) {
    termLines.push({ text: line, cls: cls || '' });
  }
  while (termLines.length > 800) termLines.shift();
  const stick = termEl.scrollTop + termEl.clientHeight >= termEl.scrollHeight - 24;
  termEl.innerHTML = termLines.map(l =>
    `<div${l.cls ? ` class="${l.cls}"` : ''}>${escapeHtml(l.text) || '&nbsp;'}</div>`
  ).join('');
  if (stick) termEl.scrollTop = termEl.scrollHeight;
}

/* ── 终端拉长：覆盖左栏（目标进程以下），再点一次还原 ──
   展开动画从终端原来所在的底部那一段向上掀开：起点百分比由 JS 按当前终端高度算好，
   写进 --term-reveal-top，交给 CSS 的 clip-path 动画。 */
function initTermStretch() {
  const card = $('#cardTerm');
  const btn = $('#termStretch');
  const col = $('.col-left');
  if (!card || !btn || !col) return;

  const reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  let restoring = false;

  const setState = (on) => {
    card.classList.toggle('is-stretched', on);
    col.classList.toggle('is-term-stretched', on);
    btn.classList.toggle('is-on', on);
    btn.setAttribute('aria-pressed', String(on));
    btn.title = t(on ? 'term.restore' : 'term.stretch', on ? '还原' : '拉长展示');
  };

  const stretch = () => {
    // 起点 = 终端现在占的那一段（自下往上数），这样它像是从原位长出来的
    const colH = col.getBoundingClientRect().height;
    const termH = card.getBoundingClientRect().height;
    const topPct = colH > 0 ? Math.min(90, Math.max(0, 100 - (termH / colH) * 100)) : 55;
    card.style.setProperty('--term-reveal-top', topPct.toFixed(1) + '%');

    // 拉长时正文必须是展开的：直接点折叠按钮，交给 collapse.js 处理状态与持久化
    if (card.classList.contains('is-collapsed')) {
      const fold = card.querySelector('.card-toggle:not(.card-toggle-stretch)');
      if (fold) fold.click();
    }
    col.scrollTop = 0;      // 覆盖层以左栏顶部为基准，滚动位置无关，归零免得退出时错位
    setState(true);
    addLog('> 终端已拉长展示，再点一次还原', 'ln-accent');
    termEl.scrollTop = termEl.scrollHeight;
  };

  const restore = () => {
    if (restoring) return;
    restoring = true;

    const finish = () => {
      if (!restoring) return;
      restoring = false;
      card.classList.remove('is-restoring');
      card.removeEventListener('animationend', onEnd);
      setState(false);
      addLog('> 终端已还原', 'ln-accent');
    };
    const onEnd = (ev) => { if (ev.animationName === 'term-stretch-out') finish(); };

    if (reduceMotion) { finish(); return; }
    card.classList.add('is-restoring');
    card.addEventListener('animationend', onEnd);
    setTimeout(finish, 320);      // 兜底：动画事件丢了也能收尾
  };

  btn.addEventListener('click', () => {
    if (card.classList.contains('is-stretched')) restore();
    else stretch();
  });
}
initTermStretch();
