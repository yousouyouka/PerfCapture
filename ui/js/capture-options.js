/* 采集项勾选框：清单来自宿主下发的 capture-options.json
   新增采集项只改 capture-options.json（+ 引擎实现），不必动这里和 index.html。
   宿主读不到清单时会不下发 options，此时用下面的内置清单兜底。 */

/* 旧配置迁移：1.2 及更早只有 gpu / mem 两个粗开关，映射到拆分后的四个 */
const LEGACY_SKIP = {
  gpu: ['gputemp', 'gpuusage'],
  mem: ['vram', 'ram'],
};

const FALLBACK_OPTIONS = [
  { skip: 'latency', label: 'capture.item.latency', default: true },
  { skip: 'gputemp', label: 'capture.item.gputemp', default: true },
  { skip: 'gpuusage', label: 'capture.item.gpuusage', default: true },
  { skip: 'vram', label: 'capture.item.vram', default: true },
  { skip: 'ram', label: 'capture.item.ram', default: true },
  { skip: 'features', label: 'capture.item.features', default: true },
  { skip: 'res', label: 'capture.item.res', default: true },
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

/** 取当前渲染出来的采集项（调试与冒烟用） */
function currentCaptureOptions() {
  return $$('.collect-grid input').map(el => ({ skip: el.dataset.skip, checked: el.checked }));
}

/**
 * 按清单重建勾选框。options 为 null/空时退回 FALLBACK_OPTIONS。
 * 只负责“有哪些项、默认值”，不负责套用用户已保存的 skip —— 那是调用方的事。
 * presets 同理：只渲染按钮与默认值，套用与否由调用方（或用户点击）决定。
 */
function renderCaptureOptions(options, presets) {
  const grid = $('.collect-grid');
  if (!grid) return;

  const list = Array.isArray(options) && options.length ? options : FALLBACK_OPTIONS;
  captureOptionsSource = list === FALLBACK_OPTIONS ? 'fallback' : 'json';

  grid.innerHTML = '';
  list.forEach((o) => {
    if (!o || !o.skip) return;
    const wrap = document.createElement('label');
    wrap.className = 'check';

    const input = document.createElement('input');
    input.type = 'checkbox';
    input.dataset.skip = String(o.skip);
    input.checked = o.default !== false;

    const span = document.createElement('span');
    if (o.label) {
      span.dataset.i18n = String(o.label);
      span.textContent = t(o.label, String(o.label));   // 词典缺该键时先显示 key，绝不空白
    } else {
      span.textContent = String(o.skip);
    }

    wrap.append(input, span);
    grid.append(wrap);
  });

  renderPresetButtons(Array.isArray(presets) && presets.length ? presets : FALLBACK_PRESETS);
  applyTranslations(grid);
}

/* ── 高级预设：快速 / 标准 / 专业 ──
   预设只做三件事：改时长、改勾选项、带一个预热丢弃秒数（warmup）。
   用户随后手工改动任意一项 → 视为自定义，按钮取消高亮，但 warmup 沿用最后套用的预设
   （改时长不该顺手把预热丢掉，那样会让「套了标准又调时长」的结果变来变去）。 */

const FALLBACK_PRESETS = [
  { id: 'quick',    label: 'capture.preset.quick',    seconds: 60,  warmup: 0, skip: ['latency', 'features', 'res'] },
  { id: 'standard', label: 'capture.preset.standard', seconds: 120, warmup: 3, skip: ['features'] },
  { id: 'pro',      label: 'capture.preset.pro',      seconds: 180, warmup: 5, skip: [] },
];

let capturePresets = FALLBACK_PRESETS;
let activePreset = null;        // 'quick' | 'standard' | 'pro' | null（自定义）
let activeWarmup = 0;           // 当前生效的预热丢弃秒数

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
  updatePresetPressed();
}

/** 把某档预设套到界面上（时长 + 勾选项 + 预热） */
function applyPreset(id) {
  const p = capturePresets.find((x) => x && x.id === id);
  if (!p) return;
  activePreset = p.id;
  activeWarmup = Number(p.warmup) || 0;

  const sec = $('#seconds');
  if (sec && p.seconds) sec.value = String(p.seconds);

  const skip = expandSkip(Array.isArray(p.skip) ? p.skip.join(',') : '');
  $$('.collect-grid input').forEach((el) => { el.checked = !skip.includes(el.dataset.skip); });

  updatePresetPressed();
  if (typeof saveSettings === 'function') saveSettings();
}

/** 手工改动 → 自定义（不再高亮任何预设），预热沿用最后套用的那一档 */
function markPresetCustom() {
  if (activePreset === null) return;
  activePreset = null;
  updatePresetPressed();
}

function updatePresetPressed() {
  $$('#presetViews button').forEach((b) => {
    b.setAttribute('aria-pressed', String(b.dataset.preset === activePreset));
  });
  /* 预设说明文案已按要求删掉：只在「当前为自定义设置」时出提示，套用预设时留空 */
  const hint = $('#presetHint');
  if (hint) {
    if (activePreset) {
      delete hint.dataset.i18n;
      hint.textContent = '';
    } else {
      hint.dataset.i18n = 'capture.preset.custom';
      hint.textContent = t('capture.preset.custom', '当前为自定义设置');
    }
  }
}

/** 主机重启后恢复上次选的预设（只恢复高亮与 warmup，不改用户的时长/勾选） */
function restorePresetState(id, warmup) {
  const p = capturePresets.find((x) => x && x.id === id);
  activePreset = p ? p.id : null;
  activeWarmup = Number.isFinite(warmup) ? warmup : (p ? Number(p.warmup) || 0 : 0);
  updatePresetPressed();
}

/** 当前生效的预热丢弃秒数（start 消息带给主机） */
function currentWarmup() { return activeWarmup; }
