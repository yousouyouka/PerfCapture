/* 采集项勾选框：清单来自宿主下发的 capture-options.json（schemaVersion 3）
   新增采集项只改 capture-options.json（+ 引擎实现），不必动这里和 index.html。
   宿主读不到清单时会不下发 options，此时用下面的内置清单兜底。
   always=true 的项 = 引擎无条件采集：默认勾选、不可修改，界面上标「始终采集」。 */

/* 旧配置迁移：1.2 及更早只有 gpu / mem 两个粗开关，映射到拆分后的四个 */
const LEGACY_SKIP = {
  gpu: ['gputemp', 'gpuusage'],
  mem: ['vram', 'ram'],
};

/* 兜底清单：与 capture-options.json 同构（7 个板块）
   kind：core = 引擎无条件采集（只读）/ optional = 可开关 / derived = 由已采数据算出来 */
const FALLBACK_GROUPS = [
  { id: 'perf', label: 'capture.group.perf', note: '' },
  { id: 'cpu', label: 'capture.group.cpu', note: '' },
  { id: 'gpu', label: 'capture.group.gpu', note: 'capture.note.gpuShared' },
  { id: 'memory', label: 'capture.group.memory', note: '' },
  { id: 'thermal', label: 'capture.group.thermal', note: 'capture.note.thermal' },
  { id: 'bottleneck', label: 'capture.group.bottleneck', note: 'capture.note.bottleneck' },
  { id: 'environment', label: 'capture.group.environment', note: '' },
];

const FALLBACK_OPTIONS = [
  { skip: 'fps', module: 'perf', kind: 'core', label: 'capture.item.fps' },
  { skip: 'frametime', module: 'perf', kind: 'core', label: 'capture.item.frametime' },
  { skip: 'chart', module: 'perf', kind: 'derived', label: 'capture.item.chart', note: 'capture.derive.chart' },
  { skip: 'latency', module: 'perf', kind: 'optional', label: 'capture.item.latency', tip: 'capture.tip.latency', default: true },
  { skip: 'cpuutil', module: 'cpu', kind: 'core', label: 'capture.item.cpuutil' },
  { skip: 'proccpu', module: 'cpu', kind: 'optional', label: 'capture.item.proccpu', default: true },
  { skip: 'gpuusage', module: 'gpu', kind: 'optional', label: 'capture.item.gpuusage', tip: 'capture.tip.gpuusage', default: true },
  { skip: 'gputemp', module: 'gpu', kind: 'optional', label: 'capture.item.gputemp', tip: 'capture.tip.gputemp', default: true },
  { skip: 'vram', module: 'memory', kind: 'optional', label: 'capture.item.vram', default: true },
  { skip: 'ram', module: 'memory', kind: 'optional', label: 'capture.item.ram', default: true },
  { skip: 'sysmem', module: 'memory', kind: 'optional', label: 'capture.item.sysmem', tip: 'capture.tip.sysmem', default: true },
  { skip: 'sharedmem', module: 'memory', kind: 'optional', label: 'capture.item.sharedmem', default: true },
  { skip: 'gpubusy', module: 'bottleneck', kind: 'core', label: 'capture.item.gpubusy' },
  { skip: 'diagnosis', module: 'bottleneck', kind: 'derived', label: 'capture.item.diagnosis', note: 'capture.derive.diagnosis' },
  { skip: 'models', module: 'environment', kind: 'core', label: 'capture.item.models' },
  { skip: 'features', module: 'environment', kind: 'optional', label: 'capture.item.features', default: true },
  { skip: 'res', module: 'environment', kind: 'optional', label: 'capture.item.res', default: true },
];

let captureOptionsSource = 'fallback';

/** 把配置里的 skip 字符串展开成具体项，顺带兼容旧键 */
function expandSkip(raw) {
  const out = [];
  String(raw || '').split(',').map(x => x.trim().toLowerCase()).filter(Boolean).forEach((k) => {
    (LEGACY_SKIP[k] || [k]).forEach((v) => { if (!out.includes(v)) out.push(v); });
  });
  return out;
}

/** 取当前渲染出来的采集项（调试与冒烟用；always 项也包含在内，checked 恒为 true） */
function currentCaptureOptions() {
  return $$('.collect-grid input').map(el => ({ skip: el.dataset.skip, checked: el.checked, always: el.disabled }));
}

/**
 * 按清单重建勾选框。options 为 null/空时退回 FALLBACK_OPTIONS。
 * 只负责“有哪些项、默认值”，不负责套用用户已保存的 skip —— 那是调用方的事。
 * presets 同理：只渲染按钮与默认值，套用与否由调用方（或用户点击）决定。
 */
function renderCaptureOptions(options, presets, groups) {
  const grid = $('.collect-grid');
  if (!grid) return;

  const list = Array.isArray(options) && options.length ? options : FALLBACK_OPTIONS;
  captureOptionsSource = list === FALLBACK_OPTIONS ? 'fallback' : 'json';
  const presetList = Array.isArray(presets) && presets.length ? presets : FALLBACK_PRESETS;
  capturePresets = presetList;                 // 记下预设，供按钮与「套用」使用

  grid.innerHTML = '';
  const groupDefs = Array.isArray(groups) && groups.length ? groups.filter(g => g && g.id) : FALLBACK_GROUPS;
  const groupOf = (o) => o && (o.group || o.module) ? String(o.group || o.module) : '';

  /* 每一项的节点：core = 只读勾选 + 「始终采集」；optional = 可勾选（有关闭影响的给悬停说明）；
     derived = 不出勾选框，标「自动计算」——它不是采集开关，是拿已采数据算出来的 */
  const makeItem = (o) => {
    const kind = o.kind === 'core' || o.kind === 'derived' ? o.kind : 'optional';
    const name = o.label ? t(o.label, String(o.skip)) : String(o.skip);

    if (kind === 'derived') {
      const row = document.createElement('div');
      row.className = 'check is-derived';
      row.dataset.skip = String(o.skip);
      const span = document.createElement('span');
      if (o.label) span.dataset.i18n = String(o.label);
      span.textContent = name;
      const chip = document.createElement('span');
      chip.className = 'cotier is-derived';
      chip.textContent = t('capture.derived.badge', '自动计算');
      chip.title = o.note ? t(o.note, '由已采集的数据计算，不单独发起采集') : '';
      row.append(span, chip);
      return row;
    }

    const always = kind === 'core';
    const wrap = document.createElement('label');
    wrap.className = 'check' + (always ? ' is-always' : '');

    const input = document.createElement('input');
    input.type = 'checkbox';
    input.dataset.skip = String(o.skip);
    input.checked = always ? true : (o.default !== false);
    if (always) {
      input.disabled = true;                   // 引擎无条件采集，不给改
      input.dataset.always = '1';
      wrap.dataset.always = '1';
    }

    const span = document.createElement('span');
    if (o.label) {
      span.dataset.i18n = String(o.label);
      span.textContent = name;                 // 词典缺该键时显示 key，绝不空白
    } else {
      span.textContent = String(o.skip);
    }

    if (always) {
      const chip = document.createElement('span');
      chip.className = 'cotier is-always';
      chip.textContent = t('capture.tier.always', '始终采集');
      chip.title = t('capture.tier.alwaysTip', '这一项由引擎无条件采集，不能关闭');
      wrap.append(input, span, chip);
    } else {
      wrap.append(input, span);
      /* 关闭会影响报告里哪些内容：写在悬停提示上，不占用版面也不拦人 */
      if (o.tip) wrap.title = t(o.tip, '');
    }
    return wrap;
  };

  const used = new Set();
  const noted = new Set();       // 板块说明只在它第一次出现的那一块给一次
  /* 三块：核心 / 可选 / 派生。每块内部仍按板块分组，板块名做小标题 */
  const SECTIONS = [
    { kind: 'core', title: 'capture.section.core', dflt: '核心数据（始终采集）', note: 'capture.section.coreNote' },
    { kind: 'optional', title: 'capture.section.optional', dflt: '可选采集（可自行关闭）', note: 'capture.section.optionalNote' },
    { kind: 'derived', title: 'capture.section.derived', dflt: '派生分析（自动计算）', note: 'capture.section.derivedNote' },
  ];
  SECTIONS.forEach((sec) => {
    const items = list.filter(o => o && o.skip && (o.kind || (o.always ? 'core' : 'optional')) === sec.kind);
    if (!items.length) return;
    items.forEach(o => used.add(groupOf(o)));
    const box = document.createElement('div');
    box.className = 'cosection';
    box.dataset.kind = sec.kind;
    const title = document.createElement('div');
    title.className = 'cosection-title';
    title.dataset.i18n = sec.title;
    title.textContent = t(sec.title, sec.dflt);
    box.append(title);
    if (sec.note) {
      const note = document.createElement('div');
      note.className = 'cosection-note';
      note.dataset.i18n = sec.note;
      note.textContent = t(sec.note, '');
      box.append(note);
    }
    /* 块内按板块分组（顺序沿用 groups 定义，未声明的归到「其他」） */
    const boards = [];
    items.forEach((o) => {
      const gid = groupOf(o);
      let b = boards.find(x => x.id === gid);
      if (!b) { b = { id: gid, items: [] }; boards.push(b); }
      b.items.push(o);
    });
    boards.forEach((b) => {
      const g = groupDefs.find(x => x.id === b.id);
      const row = document.createElement('div');
      row.className = 'cogroup';
      row.dataset.group = b.id;
      const name = document.createElement('div');
      name.className = 'cogroup-name';
      if (g && g.label) { name.dataset.i18n = String(g.label); name.textContent = t(g.label, b.id); }
      else if (b.id) { name.textContent = b.id; }
      else { name.dataset.i18n = 'capture.group.other'; name.textContent = t('capture.group.other', '其他'); }
      const itemsBox = document.createElement('div');
      itemsBox.className = 'cogroup-items';
      b.items.forEach(o => itemsBox.append(makeItem(o)));
      row.append(name, itemsBox);
      /* 板块说明（比如「两项共用同一次显卡查询」）只在它第一次出现的位置给一次 */
      if (g && g.note && !noted.has(b.id)) {
        const n = document.createElement('div');
        n.className = 'cogroup-note';
        n.dataset.i18n = String(g.note);
        n.textContent = t(g.note, '');
        row.append(n);
        noted.add(b.id);
      }
      box.append(row);
    });
    grid.append(box);
  });
  /* 清单里有板块但没在 groups 里声明 → 交给上面的「其他」分支，绝不悄悄丢项 */
  const rest = list.filter(o => o && o.skip && !used.has(groupOf(o)));
  if (rest.length) {
    const box = document.createElement('div');
    box.className = 'cosection';
    box.dataset.kind = 'optional';
    const title = document.createElement('div');
    title.className = 'cosection-title';
    title.dataset.i18n = 'capture.section.optional';
    title.textContent = t('capture.section.optional', '可选采集（可自行关闭）');
    const row = document.createElement('div');
    row.className = 'cogroup';
    row.dataset.group = '';
    const name = document.createElement('div');
    name.className = 'cogroup-name';
    name.dataset.i18n = 'capture.group.other';
    name.textContent = t('capture.group.other', '其他');
    const itemsBox = document.createElement('div');
    itemsBox.className = 'cogroup-items';
    rest.forEach(o => itemsBox.append(makeItem(o)));
    row.append(name, itemsBox);
    box.append(title, row);
    grid.append(box);
  }

  renderPresetButtons(presetList);
  applyTranslations(grid);
}

/* ── 高级预设：快速 / 标准 / 专业 ──
   预设只做三件事：改时长、改勾选项、带一个预热丢弃秒数（warmup）。
   用户随后手工改动任意一项 → 视为自定义，按钮取消高亮，但 warmup 沿用最后套用的预设
   （改时长不该顺手把预热丢掉，那样会让「套了标准又调时长」的结果变来变去）。 */

const FALLBACK_PRESETS = [
  { id: 'quick',    label: 'capture.preset.quick',    seconds: 60,  warmup: 0, skip: ['latency', 'proccpu', 'sysmem', 'sharedmem', 'features', 'res'] },
  { id: 'standard', label: 'capture.preset.standard', seconds: 120, warmup: 3, skip: ['features'] },
  { id: 'pro',      label: 'capture.preset.pro',      seconds: 180, warmup: 5, skip: [] },
];

let capturePresets = FALLBACK_PRESETS;
let activePreset = null;        // 'quick' | 'standard' | 'pro' | null（自定义）
let customBase = 'standard';    // 自定义是从哪一档改出来的（用于「自定义 · 基于标准」与「恢复默认」）
let activeWarmup = 0;           // 当前生效的预热丢弃秒数

function presetName(id) {
  const p = capturePresets.find((x) => x && x.id === id);
  return p && p.label ? t(p.label, String(id)) : String(id || '');
}

function renderPresetButtons(presets) {
  capturePresets = presets;
  const box = $('#presetViews');
  if (!box) return;
  box.innerHTML = '';
  presets.forEach((p) => {
    if (!p || !p.id) return;
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.dataset.preset = String(p.id);
    btn.setAttribute('aria-pressed', 'false');
    if (p.label) {
      btn.dataset.i18n = String(p.label);
      btn.textContent = t(p.label, String(p.id));
    } else {
      btn.textContent = String(p.id);
    }
    btn.addEventListener('click', () => applyPreset(p.id));
    box.append(btn);
  });
  bindPresetReset();
  updatePresetPressed();
}

/** 「恢复当前档位默认」按钮：只在自定义状态下出现，点了就重套基础档（不弹确认） */
function bindPresetReset() {
  const btn = $('#btnPresetReset');
  if (!btn || btn.dataset.bound === '1') return;
  btn.dataset.bound = '1';
  btn.addEventListener('click', () => applyPreset(customBase || 'standard'));
}

/** 把某档预设套到界面上（时长 + 勾选项 + 预热） */
function applyPreset(id) {
  const p = capturePresets.find((x) => x && x.id === id);
  if (!p) return;
  activePreset = p.id;
  customBase = p.id;
  activeWarmup = Number(p.warmup) || 0;

  const sec = $('#seconds');
  if (sec && p.seconds) sec.value = String(p.seconds);

  const skip = expandSkip(Array.isArray(p.skip) ? p.skip.join(',') : '');
  $$('.collect-grid input').forEach((el) => {
    if (el.disabled) return;                 // 核心项不参与预设
    el.checked = !skip.includes(el.dataset.skip);
  });

  updatePresetPressed();
  if (typeof saveSettings === 'function') saveSettings();
}

/** 手工改动 → 自定义（取消预设高亮，但记住是从哪一档改出来的），预热沿用最后套用的那一档 */
function markPresetCustom() {
  if (activePreset === null) return;
  activePreset = null;
  updatePresetPressed();
}

function updatePresetPressed() {
  $$('#presetViews button').forEach((b) => {
    b.setAttribute('aria-pressed', String(b.dataset.preset === activePreset));
  });
  /* 当前配置状态紧跟在三档右侧：套用预设时显示档位名，改过之后显示「自定义 · 基于X」 */
  const hint = $('#presetHint');
  if (hint) {
    if (activePreset) {
      delete hint.dataset.i18n;
      hint.textContent = fillParams(t('capture.preset.state', '{name}预设'), { name: presetName(activePreset) });
      hint.classList.remove('is-custom');
    } else {
      delete hint.dataset.i18n;
      hint.textContent = fillParams(t('capture.preset.customBased', '自定义 · 基于{name}'), { name: presetName(customBase) });
      hint.classList.add('is-custom');
    }
  }
  const reset = $('#btnPresetReset');
  if (reset) {
    reset.hidden = activePreset !== null;
    if (!reset.textContent) reset.dataset.i18n = 'capture.preset.reset';
    reset.textContent = fillParams(t('capture.preset.reset', '恢复{name}默认'), { name: presetName(customBase) });
    reset.title = t('capture.preset.resetTip', '把这一档的默认勾选恢复回来（当前的其他改动会被覆盖）');
  }
}

/** 主机重启后恢复上次选的预设（只恢复高亮与 warmup，不改用户的时长/勾选） */
function restorePresetState(id, warmup, base) {
  const p = capturePresets.find((x) => x && x.id === id);
  activePreset = p ? p.id : null;
  const b = capturePresets.find((x) => x && x.id === base);
  customBase = activePreset || (b ? b.id : 'standard');
  activeWarmup = Number.isFinite(warmup) ? warmup : (p ? Number(p.warmup) || 0 : 0);
  updatePresetPressed();
}

/** 自定义是从哪一档改出来的（保存进设置，重启后还能说「基于标准」） */
function currentCustomBase() { return activePreset || customBase || 'standard'; }

/** 当前生效的预热丢弃秒数（start 消息带给主机） */
function currentWarmup() { return activeWarmup; }
