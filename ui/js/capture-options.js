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
 */
function renderCaptureOptions(options) {
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

  applyTranslations(grid);
}
