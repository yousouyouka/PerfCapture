/* 历史报告库（2.1.14 / F1）
   列表来自宿主扫描 reports\*.json；对比在前端算（两边摘要都在手上，不需要额外往返）。
   红线：条件不同（GPU / 驱动 / 系统 / BIOS / 帧数据源）时**不生成百分比结论**，只给原始差值。 */

(function () {
  const S = {
    items: [],
    total: 0,
    truncated: false,
    filter: '',            // 目标进程过滤（'' = 全部）
    search: '',
    picked: [],            // 最多两个 id，按点击顺序
    detail: null,
    detailId: '',
    detailFiles: [],
    compare: null,
    loaded: false,
    pendingDelete: '',
  };

  const el = () => document.getElementById('repList');
  const panel = () => document.getElementById('repPanel');

  function pad(n) { return String(n).padStart(2, '0'); }
  function fmtTime(ms) {
    if (!ms) return '—';
    const d = new Date(Number(ms));
    if (isNaN(d.getTime())) return '—';
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  function itemById(id) { return S.items.find((it) => it.id === id) || null; }
  /* bridge.js 的 send() 只接受**一个对象**（{cmd:...}）。
     早先这里按「先命令、再参数」两段式调用，宿主收到的是裸字符串、$msg.cmd 为空被静默丢弃，
     表现为「列表空的、打开目录没反应」。统一走这个包装，别再直接传字符串。 */
  function sendCmd(cmd, extra) { send(Object.assign({ cmd: cmd }, extra || {})); }
  /* send() 来自 bridge.js 的全局函数；本文件不重复定义，避免两份实现走岔 */

  function num(v, digits) {
    if (v == null || v === '' || isNaN(Number(v))) return '—';
    return Number(v).toFixed(digits == null ? 1 : digits);
  }

  function filtered() {
    const q = S.search.trim().toLowerCase();
    return S.items.filter((it) => {
      if (S.filter && it.process !== S.filter) return false;
      if (!q) return true;
      return `${it.process || ''} ${it.id || ''} ${it.gpu || ''} ${it.driver || ''}`.toLowerCase().includes(q);
    });
  }

  function qualityBadge(q) {
    if (q === 'caution') return `<span class="rep-badge warn">${escapeHtml(t('reports.badgeWarn', '数据需注意'))}</span>`;
    if (q === 'blocked') return `<span class="rep-badge bad">${escapeHtml(t('reports.badgeBad', '数据不足'))}</span>`;
    return '';
  }

  function renderChips() {
    const box = document.getElementById('repChips');
    if (!box) return;
    const names = [];
    S.items.forEach((it) => { if (it.process && names.indexOf(it.process) < 0) names.push(it.process); });
    const top = names.slice(0, 6);
    let html = `<button type="button" class="rep-chip ${S.filter ? '' : 'is-on'}" data-filter="">${escapeHtml(t('reports.all', '全部'))}</button>`;
    top.forEach((n) => {
      html += `<button type="button" class="rep-chip ${S.filter === n ? 'is-on' : ''}" data-filter="${escapeHtml(n)}">${escapeHtml(n)}</button>`;
    });
    box.innerHTML = html;
  }

  function renderList() {
    const box = el();
    if (!box) return;
    renderChips();
    const rows = filtered();
    const cnt = document.getElementById('repCount');
    if (cnt) {
      cnt.textContent = S.truncated
        ? fillParams(t('reports.truncated', '显示最近 {n} 份（共 {total} 份）'), { n: S.items.length, total: S.total })
        : fillParams(t('reports.count', '共 {n} 份'), { n: S.total });
    }
    const pickInfo = document.getElementById('repPickInfo');
    if (pickInfo) {
      pickInfo.textContent = S.picked.length
        ? fillParams(t('reports.picked', '已选 {n} / 2 份'), { n: S.picked.length })
        : t('reports.pickHint', '勾选两份可对比');
    }

    if (!rows.length) {
      box.innerHTML = `<div class="rep-empty"><div class="k">${escapeHtml(t('reports.empty', '还没有历史报告'))}</div>` +
        `<div class="h">${escapeHtml(t('reports.emptyHint', '完成一次采集后，报告会自动出现在这里'))}</div></div>`;
      return;
    }

    let html = '';
    rows.forEach((it) => {
      const picked = S.picked.indexOf(it.id) >= 0;
      html += `<div class="rep-row ${picked ? 'is-picked' : ''}" data-id="${escapeHtml(it.id)}">` +
        `<label class="rep-pick"><input type="checkbox" data-act="pick" ${picked ? 'checked' : ''}></label>` +
        `<div class="rep-main">` +
          `<div class="rep-line1"><span class="rep-game">${escapeHtml(it.process || it.id)}</span>` +
          `<span class="rep-when">${escapeHtml(fmtTime(it.mtime))}</span>${qualityBadge(it.quality)}</div>` +
          `<div class="rep-line2">${escapeHtml(fillParams(t('reports.rowStats', '平均 {a} FPS · 1% Low {l} · {s} 秒 / {f} 帧'), {
            a: num(it.avg, 1), l: num(it.low1, 1), s: num(it.seconds, 0), f: String(it.frames == null ? '—' : it.frames)
          }))}${it.driver ? ' · ' + escapeHtml(t('reports.driver', '驱动')) + ' ' + escapeHtml(it.driver) : ''}</div>` +
        `</div>` +
        `<div class="rep-actions">` +
          `<button type="button" class="rep-mini" data-act="detail">${escapeHtml(t('reports.detail', '查看'))}</button>` +
          `<button type="button" class="rep-mini" data-act="del">${escapeHtml(t('reports.delete', '删除'))}</button>` +
        `</div>` +
      `</div>`;
    });
    box.innerHTML = html;
  }

  /* ── 详情 ── */
  function renderDetail(msg) {
    const p = panel();
    if (!p) return;
    if (!msg.ok) {
      p.hidden = false;
      p.innerHTML = `<div class="rep-panel-head"><span class="rep-panel-title">${escapeHtml(t('reports.detailTitle', '报告详情'))}</span>` +
        `<button type="button" class="rep-panel-close" data-act="closePanel">×</button></div>` +
        `<p class="rep-note bad">${escapeHtml(t('reports.detailFail', '这份报告已不存在或无法读取'))}</p>`;
      return;
    }
    S.detail = msg.data || {};
    S.detailFiles = msg.files || [];
    const d = S.detail;
    const env = d.environment || {};
    const q = (d.quality && d.quality.level) || '';
    const files = S.detailFiles.map((f) => {
      const label = { json: 'JSON', html: 'HTML', pmcsv: t('reports.openCsv', '逐帧 CSV'), senscsv: t('reports.openSens', '传感器 CSV') }[f.kind] || f.kind;
      return `<button type="button" class="rep-mini" data-act="open" data-kind="${escapeHtml(f.kind)}">${escapeHtml(label)}</button>`;
    }).join(' ');

    const kv = [
      [t('reports.kvTime', '采集时间'), fmtTime((itemById(msg.id) || {}).mtime)],
      [t('reports.kvDuration', '时长 / 帧数'), `${num(d.captured_seconds, 0)} s / ${d.frames == null ? '—' : d.frames}`],
      [t('reports.kvQuality', '数据可信度'), q === 'ok' ? t('reports.qualityOk', '未发现问题') : (q === 'caution' ? t('reports.badgeWarn', '数据需注意') : (q === 'blocked' ? t('reports.badgeBad', '数据不足') : '—'))],
      [t('reports.kvGpu', '显卡'), env.gpu_model || '—'],
      [t('reports.kvDriver', '显卡驱动'), env.driver_version || '—'],
      [t('reports.kvOs', '操作系统'), env.os_version || '—'],
      [t('reports.kvBios', 'BIOS'), env.bios_version || '—'],
      [t('reports.kvRes', '分辨率'), d.resolution || '—'],
    ];
    p.hidden = false;
    p.innerHTML = `<div class="rep-panel-head"><span class="rep-panel-title">${escapeHtml(t('reports.detailTitle', '报告详情'))}</span>` +
      `<span class="rep-panel-sub">${escapeHtml(d.run || '')}</span>` +
      `<button type="button" class="rep-panel-close" data-act="closePanel">×</button></div>` +
      `<div class="rep-kv">` + kv.map(([k, v]) => `<div><div class="k">${escapeHtml(k)}</div><div class="v">${escapeHtml(String(v))}</div></div>`).join('') + `</div>` +
      `<p class="rep-note">${escapeHtml(t('reports.detailHint', '完整图表请打开 HTML 报告；逐帧数据在 CSV 里。'))}</p>` +
      `<div style="margin-top:.35rem">${files}</div>`;
  }

  /* ── 对比 ── */
  const BLOCK_FIELDS = [
    ['gpu', 'gpu_model', 'reports.fGpu', '显卡'],
    ['driver', 'driver_version', 'reports.fDriver', '显卡驱动'],
    ['os', 'os_version', 'reports.fOs', '操作系统'],
    ['bios', 'bios_version', 'reports.fBios', 'BIOS'],
    ['src', 'fps_source', 'reports.fSrc', '帧数据源'],
  ];
  const NOTE_FIELDS = [
    ['resolution', null, 'reports.fRes', '分辨率'],
    ['present_mode', null, 'reports.fPresent', '呈现模式'],
  ];

  function pickField(r, key) {
    if (key === 'resolution') return r.resolution;
    if (key === 'present_mode') return r.present_mode;
    const env = r.environment || {};
    return env[key];
  }

  function comparability(a, b) {
    const diffs = [];
    let blocked = false;
    BLOCK_FIELDS.forEach(([id, key, tkey, fallback]) => {
      const va = pickField(a, key), vb = pickField(b, key);
      const name = t(tkey, fallback);
      if (!va || !vb) { diffs.push({ level: 'unknown', name, va: va || '—', vb: vb || '—' }); return; }
      if (String(va) !== String(vb)) { blocked = true; diffs.push({ level: 'block', name, va, vb }); }
    });
    NOTE_FIELDS.forEach(([id, key, tkey, fallback]) => {
      // 注意：这里的比对字段就是 id 本身（resolution / present_mode 是顶层字段，
      // 不在 environment 里）。早先误用 key 导致两边都取到 undefined，全被当成「没记录」。
      const va = pickField(a, id), vb = pickField(b, id);
      const name = t(tkey, fallback);
      if (!va || !vb) { diffs.push({ level: 'unknown', name, va: va || '—', vb: vb || '—' }); return; }
      if (String(va) !== String(vb)) { diffs.push({ level: 'note', name, va, vb }); }
    });
    return { diffs, blocked };
  }

  const ROWS = [
    ['reports.mAvg', '平均帧率', (r) => r.avg_fps, 1, true],
    ['reports.mLow1', '1% Low', (r) => r.fps_1pct_low, 1, true],
    ['reports.mLow01', '0.1% Low', (r) => r.fps_01pct_low, 1, true],
    ['reports.mStutter', '卡顿次数', (r) => (r.stutter ? r.stutter.count : null), 0, false],
    ['reports.mWorst', '最差帧（ms）', (r) => (r.stutter ? r.stutter.worst_ms : null), 1, false],
    ['reports.mGpuUtil', 'GPU 平均占用', (r) => r.gpu_util_avg_pct, 0, true],
    ['reports.mGpuTemp', 'GPU 峰值温度', (r) => r.gpu_temp_max_c, 0, false],
    ['reports.mCpuUtil', 'CPU 平均占用', (r) => r.cpu_util_avg_pct, 0, true],
  ];

  function renderCompare(msg) {
    const p = panel();
    if (!p) return;
    if (!msg.ok) {
      p.hidden = false;
      p.innerHTML = `<div class="rep-panel-head"><span class="rep-panel-title">${escapeHtml(t('reports.cmpTitle', '两次采集对比'))}</span>` +
        `<button type="button" class="rep-panel-close" data-act="closePanel">×</button></div>` +
        `<p class="rep-note bad">${escapeHtml(msg.reason === 'needTwo' ? t('reports.cmpNeedTwo', '请先勾选两份报告') : t('reports.detailFail', '这份报告已不存在或无法读取'))}</p>`;
      return;
    }
    S.compare = msg;
    const a = msg.a, b = msg.b;
    const { diffs, blocked } = comparability(a, b);
    const nameA = `${a.process || ''} · ${num(a.avg_fps, 1)} FPS`;
    const nameB = `${b.process || ''} · ${num(b.avg_fps, 1)} FPS`;

    let rowsHtml = '';
    ROWS.forEach(([key, fallback, get, digits, allowPct]) => {
      const va = get(a), vb = get(b);
      const hasBoth = va != null && vb != null && !isNaN(Number(va)) && !isNaN(Number(vb));
      const d = hasBoth ? Number(vb) - Number(va) : null;
      const dPct = (hasBoth && Number(va) !== 0) ? (100 * d / Math.abs(Number(va))) : null;
      const cls = d == null ? 'v-na' : (d > 0 ? 'v-up' : (d < 0 ? 'v-down' : ''));
      const dTxt = d == null ? '—' : (d > 0 ? '+' : '') + d.toFixed(digits);
      const pTxt = (!blocked && allowPct && dPct != null) ? (dPct > 0 ? '+' : '') + dPct.toFixed(1) + '%' : '—';
      rowsHtml += `<tr><td>${escapeHtml(t(key, fallback))}</td>` +
        `<td>${va == null ? '—' : num(va, digits)}</td><td>${vb == null ? '—' : num(vb, digits)}</td>` +
        `<td class="${cls}">${dTxt}</td><td class="${cls}">${pTxt}</td></tr>`;
    });

    let diffHtml = '';
    if (diffs.length) {
      diffHtml = `<ul class="rep-diff">` + diffs.map((x) => {
        const tag = x.level === 'block' ? t('reports.cmpDiffers', '不同，不能直接比')
          : (x.level === 'note' ? t('reports.cmpNoteLevel', '不同，结论需注意') : t('reports.cmpUnknown', '有一侧没记录，无法确认'));
        return `<li><b>${escapeHtml(x.name)}</b>：${escapeHtml(String(x.va))} → ${escapeHtml(String(x.vb))}（${escapeHtml(tag)}）</li>`;
      }).join('') + `</ul>`;
    }
    const hasUnknown = diffs.some((x) => x.level === 'unknown');
    const hasNote = diffs.some((x) => x.level === 'note');
    const head = blocked
      ? `<p class="rep-note bad">${escapeHtml(t('reports.cmpBlocked', '两次采集的关键条件不同，下面只给原始差值，不做「提升 / 下降」的百分比结论。'))}</p>`
      : (hasNote
        ? `<p class="rep-note warn">${escapeHtml(t('reports.cmpNote', '条件基本一致，但下列项目有差异，结论需结合它们看。'))}</p>`
        : (hasUnknown
          ? `<p class="rep-note warn">${escapeHtml(t('reports.cmpUnknownHead', '有项目在一边没有记录，无法确认条件是否一致——下面只给原始差值。'))}</p>`
          : `<p class="rep-note">${escapeHtml(t('reports.cmpSame', '两次采集的条件指纹一致，可以直接对比。'))}</p>`));

    p.hidden = false;
    p.innerHTML = `<div class="rep-panel-head"><span class="rep-panel-title">${escapeHtml(t('reports.cmpTitle', '两次采集对比'))}</span>` +
      `<span class="rep-panel-sub">A = ${escapeHtml(nameA)} ／ B = ${escapeHtml(nameB)}</span>` +
      `<button type="button" class="rep-panel-close" data-act="closePanel">×</button></div>` +
      head + diffHtml +
      `<table class="rep-table" style="margin-top:.45rem"><thead><tr>` +
      `<th>${escapeHtml(t('reports.colMetric', '指标'))}</th><th>A（较早）</th><th>B（较晚）</th>` +
      `<th>${escapeHtml(t('reports.colDelta', '差值'))}</th><th>${escapeHtml(t('reports.colPct', '变化'))}</th>` +
      `</tr></thead><tbody>${rowsHtml}</tbody></table>`;
  }

  /* ── 事件 ── */
  function onListClick(e) {
    const row = e.target.closest('.rep-row');
    if (!row) return;
    const id = row.dataset.id;
    const act = e.target.dataset.act;

    if (act === 'pick') {
      const i = S.picked.indexOf(id);
      if (i >= 0) S.picked.splice(i, 1);
      else {
        if (S.picked.length >= 2) S.picked.shift();   // 已选两份：挤掉较早选的那份
        S.picked.push(id);
      }
      S.pendingDelete = '';
      renderList();
      if (S.picked.length === 2) requestCompare();
      else if (S.picked.length === 0 && panel()) { panel().hidden = true; }
      return;
    }
    if (act === 'detail') { sendCmd('reportDetail', { id }); return; }
    if (act === 'del') {
      if (S.pendingDelete !== id) {
        S.pendingDelete = id;
        e.target.textContent = t('reports.confirmDelete', '确认删除？');
        e.target.classList.add('is-danger');
        setTimeout(() => { if (S.pendingDelete === id) { S.pendingDelete = ''; renderList(); } }, 4000);
        return;
      }
      S.pendingDelete = '';
      sendCmd('reportDelete', { id, withAssets: true });
    }
  }

  function requestCompare() {
    if (S.picked.length !== 2) return;
    // 固定 A = 较早、B = 较晚：按 mtime 排序，不依赖点击顺序（否则「提升了」会看反）
    const ids = S.picked.slice().sort((x, y) => {
      const ax = itemById(x), ay = itemById(y);
      return ((ax && ax.mtime) || 0) - ((ay && ay.mtime) || 0);
    });
    sendCmd('reportCompare', { ids });
  }

  function onPanelClick(e) {
    const act = e.target.dataset.act;
    if (act === 'closePanel') { e.target.closest('.rep-panel').hidden = true; return; }
    if (act === 'open') {
      if (!S.detailId) return;
      sendCmd('reportOpenFile', { id: S.detailId, kind: e.target.dataset.kind });
    }
  }

  /* ── 宿主消息 ── */
  function handle(msg) {
    if (!msg || !msg.type) return;
    if (msg.type === 'reports') {
      S.items = msg.items || [];
      S.total = msg.total || 0;
      S.truncated = !!msg.truncated;
      S.loaded = true;
      // 列表刷新后丢掉已经不存在的选择
      S.picked = S.picked.filter((id) => S.items.some((it) => it.id === id));
      renderList();
      if (S.picked.length === 2) requestCompare();
      return;
    }
    if (msg.type === 'reportDetail') {
      S.detailId = msg.id;
      renderDetail(msg);
      return;
    }
    if (msg.type === 'reportCompare') { renderCompare(msg); return; }
    if (msg.type === 'reportDeleted') {
      const n = (msg.removed || []).length;
      S.picked = S.picked.filter((id) => id !== msg.id);
      if (S.detailId === msg.id) { S.detailId = ''; if (panel()) panel().hidden = true; }
      sendCmd('reportsList');
      const p = panel();
      if (p) { p.hidden = false; p.innerHTML = `<p class="rep-note">${escapeHtml(fillParams(t('reports.deleted', '已删除 {n} 个文件（移到回收站）'), { n }))}</p>`; }
      return;
    }
  }

  /* ── 打开页面时加载 ── */
  function ensureLoaded(force) {
    if (!S.loaded || force) sendCmd('reportsList');
  }

  function bind() {
    const list = el();
    if (list) list.addEventListener('click', onListClick);
    const p = panel();
    if (p) p.addEventListener('click', onPanelClick);
    const chips = document.getElementById('repChips');
    if (chips) chips.addEventListener('click', (e) => {
      const b = e.target.closest('.rep-chip');
      if (!b) return;
      S.filter = b.dataset.filter || '';
      renderList();
    });
    const search = document.getElementById('repSearch');
    if (search) search.addEventListener('input', () => { S.search = search.value || ''; renderList(); });
    const refresh = document.getElementById('repRefresh');
    if (refresh) refresh.addEventListener('click', () => { ensureLoaded(true); });
    const openFolder = document.getElementById('repOpenFolder');
    if (openFolder) openFolder.addEventListener('click', () => sendCmd('openReports'));
    const clear = document.getElementById('repClearPick');
    if (clear) clear.addEventListener('click', () => { S.picked = []; renderList(); if (panel()) panel().hidden = true; });
    // 切到本页时懒加载（首次进入才请求，避免启动就扫目录）
    document.querySelectorAll('.nav-item').forEach((b) => {
      b.addEventListener('click', () => { if (b.dataset.page === 'reports') ensureLoaded(false); });
    });
  }

  window.PerfReports = { handle, ensureLoaded, refresh: () => renderList() };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', bind);
  else bind();
})();
