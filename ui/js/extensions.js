/* 扩展中心：状态由宿主下发（extensions.json 注册表 + 持久化 + 自有进程校验），本文件只渲染与发命令。
   批次 E 起托管扩展的主操作是「一键启用」：宿主在 runspace 里完成下载/校验/安装/配置/启动，
   经 extensionProgress 回推阶段进度；「关闭」是真开关，结束自有进程、回退数据源并持久化。
   本机预装的同类软件由宿主无视，界面不做依赖探测提示；所有失败都有细分原因与重试入口。
   语言切换后由 __refreshExtensions 重画；文案一律走 t('extensions.*')。 */

(function initExtensions() {
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };
  const tx = (key, fallback) => (typeof t === 'function' ? t(key, fallback) : fallback);
  const send = (msg) => { if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(msg); };

  const list = document.getElementById('extensionsList');
  const countEl = document.getElementById('extensionsCount');
  const areasEl = document.getElementById('extAreas');
  const filtersEl = document.getElementById('extFilters');
  const onlyEl = document.getElementById('extOnlyInstalled');
  const refreshEl = document.getElementById('extRefresh');
  if (!list) return;

  const CATS = ['all', 'datasource', 'sensor', 'display'];
  const STATUS = {
    planned:      { cls: 'is-planned',      key: 'extensions.status.planned',      fb: '规划中' },
    notInstalled: { cls: 'is-notinstalled', key: 'extensions.status.notInstalled', fb: '未安装' },
    installed:    { cls: 'is-installed',    key: 'extensions.status.installed',    fb: '已安装未启用' },
    enabled:      { cls: 'is-enabled',      key: 'extensions.status.enabled',      fb: '已启用' },
    unsupported:  { cls: 'is-unsupported',  key: 'extensions.status.unsupported',  fb: '不支持当前硬件' },
    failed:       { cls: 'is-failed',       key: 'extensions.status.failed',       fb: '读取失败' }
  };
  const REASONS = {
    notAvailable:     'extensions.reason.notAvailable',
    dependencyMissing:'extensions.reason.dependencyMissing',
    notInstalled:     'extensions.reason.notInstalled',
    payloadMissing:   'extensions.reason.payloadMissing',
    installFailed:    'extensions.reason.installFailed',
    invalidSource:    'extensions.reason.invalidSource',
    readerMissing:    'extensions.reason.readerMissing',
    shmNotFound:      'extensions.reason.shmNotFound',
    shmOpenFailed:    'extensions.reason.shmOpenFailed',
    badSignature:     'extensions.reason.badSignature',
    oldVersion:       'extensions.reason.oldVersion',
    badLayout:        'extensions.reason.badLayout',
    noEntry:          'extensions.reason.noEntry',
    staleData:        'extensions.reason.staleData',
    noFrames:         'extensions.reason.noFrames',
    readException:    'extensions.reason.readException',
    // 内置厂商通道（v2.1.10）：为什么这台机器没有 CPU 温度
    vendorNotSupported: 'extensions.reason.vendorNotSupported',
    vendorNeedsAdmin:   'extensions.reason.vendorNeedsAdmin',
    vendorNoChannel:    'extensions.reason.vendorNoChannel',
    vendorNotImplemented:'extensions.reason.vendorNotImplemented',
    vendorOutOfRange:   'extensions.reason.vendorOutOfRange',
    vendorReadFailed:   'extensions.reason.vendorReadFailed',
    // 批次 E：供应层失败细分（一律回滚后回推，不假装成功）
    provisionBusy:       'extensions.reason.provisionBusy',
    provisionUnavailable:'extensions.reason.provisionUnavailable',
    packageInvalid:      'extensions.reason.packageInvalid',
    hashMismatch:        'extensions.reason.hashMismatch',
    signatureInvalid:    'extensions.reason.signatureInvalid',
    installerMissing:    'extensions.reason.installerMissing',
    installerHashMismatch:'extensions.reason.installerHashMismatch',
    shmNotReady:         'extensions.reason.shmNotReady',
    shmIncompatible:     'extensions.reason.shmIncompatible',
    installMissing:      'extensions.reason.installMissing',
    ownProcessMissing:   'extensions.reason.ownProcessMissing',
    foreignProcess:      'extensions.reason.foreignProcess',
    // E1（2.1.2）：阶段化原因；detail 由宿主一并下发，UI 原样展示，不再笼统成「安装过程出错」。
    downloadFailed:      'extensions.reason.downloadFailed',
    extractFailed:       'extensions.reason.extractFailed',
    verifyFailed:        'extensions.reason.verifyFailed',
    configureFailed:     'extensions.reason.configureFailed',
    startFailed:         'extensions.reason.startFailed',
    verifyRuntimeFailed: 'extensions.reason.verifyRuntimeFailed',
    uacCancelled:        'extensions.reason.uacCancelled',
    provisionException:  'extensions.reason.provisionException',
    // E2（2.1.7）：用户主动取消，不是故障；文案强调「未做任何更改」。
    cancelled:           'extensions.reason.cancelled',
    // 2.1.4：关闭时自有运行时没清干净（例如残留注入器），如实告知而不是写「影响已清除」。
    stopIncomplete:      'extensions.reason.stopIncomplete',
    // 2.1.8：手动导入（本地包）相关的三种确定性原因
    localPackageMissing: 'extensions.reason.localPackageMissing',
    archiveTooLarge:     'extensions.reason.archiveTooLarge',
    noPageUrl:           'extensions.reason.noPageUrl',
    unknown:             'extensions.reason.unknown'
  };
  // 宿主下发的关闭后提示：restartTarget=注入已移除，需重启游戏恢复图形选项；
  // stopIncomplete=仍有残留进程，卡片与 toast 同时提示。文案走 i18n，不在前端拼中文。
  const NOTES = {
    restartTarget:     'extensions.note.restartTarget',
    stopIncomplete:    'extensions.note.stopIncomplete',
    vulkanLayerStuck:  'extensions.note.vulkanLayerStuck'
  };
  const STAGES = ['starting', 'stopping', 'prepare', 'download', 'verify', 'extract', 'install', 'configure', 'start', 'verifyRuntime', 'done', 'failed'];

  // 宿主 PowerShell 若把数组二次包装成 [[{...}]]，这里展平一层兜底；
  // 正常路径下 msg.extensions 就是对象数组，不受影响。
  function normalizeStates(states) {
    let arr = Array.isArray(states) ? states : [];
    if (arr.length === 1 && Array.isArray(arr[0])) arr = arr[0];
    return arr
      .filter((s) => s && typeof s === 'object' && !Array.isArray(s))
      .map((s) => ({ ...s, status: s.status || 'planned' }));
  }

  let curCat = 'all';
  let onlyInstalled = false;
  let items = normalizeStates(window.PerfExtensions);
  let fpsSource = 'presentmon';
  let toast = null;                  // 最近一次失败：{ text, detail }；detail 为宿主给的阶段原文
  const busy = Object.create(null);  // id -> 当前供应阶段；非空时禁用该卡按钮
  const progress = Object.create(null); // id -> 0..100（整体进度，和进度条一致）
  const progressInfo = Object.create(null); // id -> 宿主最近一条进度消息（含 recv/total/bps/eta/part）
  const cancelling = Object.create(null);   // id -> 已点过取消，等 worker 回滚完成

  /* 下载速度 / 大小的人类可读格式；0 或非法值回空串，调用方据此决定要不要显示 */
  function fmtBytes(b) {
    const n0 = Number(b);
    if (!(n0 > 0)) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    let n = n0;
    let i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
    return (i === 0 ? String(Math.round(n)) : n.toFixed(1)) + ' ' + units[i];
  }

  /* 取消按钮：点一次就置灰，等宿主把 worker 回滚完（成功/失败都会回 message） */
  function cancelButton(id) {
    const b = el('button', 'btn ext-cancel', cancelling[id]
      ? tx('extensions.cancelling', '正在取消…')
      : tx('extensions.cancel', '取消'));
    b.type = 'button';
    b.disabled = !!cancelling[id];
    b.addEventListener('click', () => {
      if (cancelling[id]) return;
      cancelling[id] = true;
      send({ cmd: 'cancelExtensionProvision', id });
      render();
    });
    return b;
  }

  function metaRow(k, v) {
    const row = el('span', 'ext-meta-row');
    row.appendChild(el('span', 'ext-meta-k', k));
    row.appendChild(el('span', 'ext-meta-v', v));
    return row;
  }

  function action(label, cmd, id, primary) {
    const b = el('button', primary ? 'btn btn-primary' : 'btn', label);
    b.type = 'button';
    b.dataset.cmd = cmd;
    b.dataset.id = id;
    if (busy[id]) b.disabled = true;              // 供应进行中，禁止连点造成重入
    b.addEventListener('click', () => {
      if (busy[id]) return;
      toast = null;                                // 新一轮操作清掉上一次的失败提示
      // 初始阶段按动作区分：关闭=正在关闭，启用=正在启动。
      // 只有真的需要下载安装时，宿主的第一条进度才会切到 prepare/download/install…，
      // 复用已装副本时整段流程瞬间结束，用户不会再误以为「每次都在重装」。
      busy[id] = cmd === 'disableExtension' ? 'stopping' : 'starting';
      progress[id] = 0;
      send({ cmd, id });
      render();
    });
    return b;
  }

  /* 手动导入（2.1.8）：官方镜像不可达时的兜底。宿主弹文件框 → 回传路径 → 直接走同一条供应流水线。 */
  function importButton(id) {
    const b = el('button', 'btn', tx('extensions.importPackage', '手动导入'));
    b.type = 'button';
    b.title = tx('extensions.importHint', '自己下载好安装包后从这里选择，软件会按官方哈希校验');
    if (busy[id]) b.disabled = true;
    b.addEventListener('click', () => {
      if (busy[id]) return;
      toast = null;
      send({ cmd: 'pickExtensionPackage', id });
    });
    return b;
  }

  function pageButton(id) {
    const b = el('button', 'btn', tx('extensions.openPage', '官方下载页'));
    b.type = 'button';
    b.title = tx('extensions.openPageHint', '用浏览器打开官方下载页；下载好后回到这里点「手动导入」');
    b.addEventListener('click', () => { send({ cmd: 'openExtensionPage', id }); });
    return b;
  }

  function actionsFor(s) {
    const box = el('div', 'ext-actions');
    if (!s.available) {
      const b = el('button', 'btn', tx('extensions.notReady', '后续版本开放'));
      b.type = 'button'; b.disabled = true;                   // 未发布：如实禁用，不做假安装
      b.title = tx('extensions.reason.notAvailable', '该扩展尚未发布');
      box.appendChild(b);
      return box;
    }
    // 内置能力：随主程序提供，不需要安装/启用/关闭（例如厂商固件温度通道）。
    // 不给「一键启用」按钮，避免用户以为点了才会生效；状态只说明当前机器能不能用。
    if (s.builtin) {
      const on = s.status === 'enabled';
      const b = el('button', 'btn', tx(on ? 'extensions.builtinOn' : 'extensions.builtinOff', on ? '内置 · 无需安装' : '当前机型不支持'));
      b.type = 'button'; b.disabled = true;
      b.title = tx('extensions.builtinHint', '该能力随主程序提供，不需要安装或启用；状态表示当前机型是否支持');
      box.appendChild(b);
      return box;
    }
    switch (s.status) {
      case 'notInstalled':
        box.appendChild(action(tx('extensions.oneClick', '一键启用'), 'oneClickEnableExtension', s.id, true));
        box.appendChild(importButton(s.id)); break;
      case 'installed':
        box.appendChild(action(tx('extensions.oneClick', '一键启用'), 'oneClickEnableExtension', s.id, true));
        box.appendChild(action(tx('extensions.uninstall', '卸载'), 'uninstallExtension', s.id)); break;
      case 'enabled':
        // 「关闭」是真开关：显眼、一键；宿主结束自有进程、回退数据源并持久化。
        box.appendChild(action(tx('extensions.disable', '关闭'), 'disableExtension', s.id, true)); break;
      case 'unsupported':
      case 'failed':
        box.appendChild(action(tx('extensions.retry', '重试启用'), 'oneClickEnableExtension', s.id, true));
        box.appendChild(importButton(s.id));
        // 下载失败多半是镜像不可达：给一条「用浏览器自己下」的路，浏览器可能走系统代理而 .NET 不走。
        box.appendChild(pageButton(s.id));
        box.appendChild(action(tx('extensions.uninstall', '卸载'), 'uninstallExtension', s.id)); break;
    }
    return box;
  }

  function progressFor(id) {
    if (!busy[id]) return null;
    const stageKey = 'extensions.stage.' + busy[id];
    const stageText = tx(stageKey, (STAGES.indexOf(busy[id]) >= 0 ? busy[id] : '处理中'));
    const wrap = el('div', 'ext-progress');
    // 「正在启动 / 正在关闭」是瞬时状态，没有百分比可言：只显示动作，不摆一条假进度条。
    const transient = busy[id] === 'starting' || busy[id] === 'stopping';
    const info = progressInfo[id] || {};
    let text;
    if (cancelling[id]) {
      // 取消已下发：worker 正在回滚（删 .part / work-* / 停进程），这时不该再显示漂亮的下载速度。
      text = tx('extensions.progressCancelling', '正在取消并回滚…');
    } else if (!transient && busy[id] === 'download' && info.part >= 0 && info.part != null) {
      // 下载阶段：给出「本次下载」的真实百分比，而不是整体进度里被压扁的 12%–30%。
      const pct = Math.max(0, Math.min(100, Number(info.part) || 0));
      let extra = '';
      if (info.bps > 0) {
        const speed = fmtBytes(info.bps) + '/s';
        const eta = (info.eta > 0)
          ? tx('extensions.etaSeconds', '剩余 {s} 秒').replace('{s}', String(info.eta))
          : tx('extensions.etaUnknown', '剩余时间未知');
        extra = tx('extensions.progressSpeed', ' · {speed} · {eta}').replace('{speed}', speed).replace('{eta}', eta);
      }
      text = tx('extensions.progressDownload', '正在下载 {pct}%{extra}')
        .replace('{pct}', String(pct)).replace('{extra}', extra);
    } else {
      text = transient
        ? tx('extensions.progressSimple', '正在{stage}…').replace('{stage}', stageText)
        : tx('extensions.progress', '正在 {stage}… {pct}%').replace('{stage}', stageText).replace('{pct}', String(progress[id] || 0));
    }
    const bar = el('div', 'ext-progress-bar');
    const fill = el('div', 'ext-progress-fill');
    fill.style.width = transient ? '35%' : Math.max(0, Math.min(100, progress[id] || 0)) + '%';
    if (transient) wrap.classList.add('is-indeterminate');
    bar.appendChild(fill);
    wrap.appendChild(el('span', 'ext-progress-text', text));
    wrap.appendChild(bar);
    // 只有真正在跑供应流程的阶段才给「取消」：瞬时态（启用/关闭）没东西可取消。
    if (!transient) wrap.appendChild(cancelButton(id));
    return wrap;
  }

  function card(s) {
    const art = el('article', 'ext-card');
    if (s.id) art.dataset.extension = s.id;

    const head = el('div', 'ext-card-head');
    const title = el('h2');
    title.appendChild(document.createTextNode(s.name || ''));
    if (s.version) title.appendChild(el('span', 'ext-card-ver', s.version));
    head.appendChild(title);
    const st = STATUS[s.status] || STATUS.planned;
    head.appendChild(el('span', 'ext-status ' + st.cls, tx(st.key, st.fb)));
    art.appendChild(head);

    if (s.desc) art.appendChild(el('p', 'ext-desc', s.desc));

    // 关闭后的状态提示：这条不是错误，但必须显眼——否则用户会以为「关了却没用」。
    if (s.note && NOTES[s.note]) {
      art.appendChild(el('p', 'ext-note is-info', tx(NOTES[s.note], s.note)));
    }

    // 细分失败原因：单独一行，不用「暂不可用」笼统带过；数据源标注当前是谁。
    if (s.status === 'unsupported' || s.status === 'failed') {
      const why = tx(REASONS[s.reason] || REASONS.unknown, s.reason || '未知原因');
      art.appendChild(el('p', 'ext-note', why));
    }
    if (s.status === 'enabled' && fpsSource === s.id) {
      art.appendChild(el('p', 'ext-note', tx('extensions.currentSource', '当前数据源：本扩展')));
      // 高频源：如实标注刷新与 1% Low 口径，不假装亚秒级；口径与报告一致。
      art.appendChild(el('p', 'ext-note', tx('extensions.fastSource', '高频数据源：亚秒级刷新；1% Low = 最慢 1% 帧的平均帧时间取倒数')));
    }
    if (s.status === 'enabled' && fpsSource !== s.id) {
      art.appendChild(el('p', 'ext-note', tx('extensions.standbySource', '已启用，但当前未作为数据源（本工具仍用 PresentMon 基线）')));
    }

    const pg = progressFor(s.id);
    if (pg) art.appendChild(pg);

    const meta = el('div', 'ext-meta');
    if (s.metrics && s.metrics.length) {
      meta.appendChild(metaRow(tx('extensions.field.metrics', '提供指标'), s.metrics.join(' · ')));
    }
    const fields = [
      ['depends', 'extensions.field.depends', '依赖'],
      ['size', 'extensions.field.size', '磁盘占用'],
      ['permission', 'extensions.field.permission', '权限需求'],
      ['platform', 'extensions.field.platform', '支持平台'],
      ['cost', 'extensions.field.cost', '采集开销'],
      ['source', 'extensions.field.source', '来源']
    ];
    fields.forEach(([k, key, fb]) => { if (s[k]) meta.appendChild(metaRow(tx(key, fb), s[k])); });
    if (meta.children.length) art.appendChild(meta);

    art.appendChild(actionsFor(s));
    return art;
  }

  function buildToolbar() {
    if (areasEl) {
      areasEl.innerHTML = '';
      CATS.forEach((c) => {
        const b = el('button', curCat === c ? 'is-active' : '', tx('extensions.cat.' + c, c === 'all' ? '全部' : c));
        b.type = 'button';
        b.dataset.cat = c;
        b.addEventListener('click', () => { curCat = c; render(); });
        areasEl.appendChild(b);
      });
    }
    if (onlyEl) { onlyEl.checked = onlyInstalled; onlyEl.addEventListener('change', () => { onlyInstalled = onlyEl.checked; render(); }); }
    if (refreshEl) {
      refreshEl.addEventListener('click', () => { send({ cmd: 'refreshExtensionStatus' }); });
    }
  }

  function render() {
    buildToolbar();
    const shown = items.filter((s) => {
      if (curCat !== 'all' && s.category !== curCat) return false;
      if (onlyInstalled && s.status !== 'installed' && s.status !== 'enabled') return false;
      return true;
    });
    if (countEl) countEl.textContent = tx('extensions.count', '共 {n} 项').replace('{n}', String(shown.length));

    list.innerHTML = '';
    if (toast) {
      const box = el('div', 'ext-error');
      box.appendChild(el('p', 'ext-note', toast.text));
      if (toast.detail) {
        box.appendChild(el('pre', 'ext-error-detail', toast.detail));
        const copy = el('button', 'btn', tx('extensions.copyDiagnostics', '复制诊断信息'));
        copy.type = 'button';
        copy.addEventListener('click', () => {
          if (typeof navigator !== 'undefined' && navigator.clipboard) {
            navigator.clipboard.writeText(toast.text + '\n' + toast.detail);
          }
        });
        box.appendChild(copy);
      }
      list.appendChild(box);
    }
    if (!shown.length) {
      const empty = el('div', 'extensions-empty');
      empty.appendChild(el('strong', '', tx('extensions.emptyTitle', '暂无扩展')));
      empty.appendChild(el('p', '', tx('extensions.emptyHint', '规划中的扩展会出现在这里。')));
      list.appendChild(empty);
      return;
    }
    shown.forEach((s) => list.appendChild(card(s)));
  }

  // 宿主消息入口（bridge.js 分发）
  const api = {
    apply(states, source) {
      if (Array.isArray(states)) items = normalizeStates(states);
      if (source) fpsSource = source;
      render();
    },
    state(msg) {
      const hit = items.find((s) => s.id === msg.id);
      if (hit) {
        hit.status = msg.status;
        // note 由宿主下发（关闭后的重启提示 / 残留提示）；缺省表示清空。
        hit.note = msg.note || '';
      }
      if (msg.fpsSource) fpsSource = msg.fpsSource;
      delete busy[msg.id]; delete progress[msg.id]; delete progressInfo[msg.id]; delete cancelling[msg.id];
      render();
    },
    progress(msg) {
      if (!msg.id) return;
      if (msg.stage === 'done' || msg.stage === 'failed') {
        delete busy[msg.id]; delete progress[msg.id]; delete progressInfo[msg.id]; delete cancelling[msg.id];
      } else {
        busy[msg.id] = msg.stage || 'prepare';
        progress[msg.id] = Number(msg.pct) || 0;
        // 整条留存：下载阶段要用 recv/total/bps/eta/part 显示真实速度与剩余时间
        progressInfo[msg.id] = msg;
      }
      render();
    },
    error(msg) {
      const why = tx(REASONS[msg.reason] || REASONS.unknown, msg.reason || '未知原因');
      toast = { text: (msg.id ? (msg.id + ':') : '') + why, detail: msg.detail || '' };
      delete busy[msg.id]; delete progress[msg.id]; delete progressInfo[msg.id]; delete cancelling[msg.id];
      render();
      // 失败后回读真实状态，避免界面停在旧状态（例如供应失败却显示已启用）
      send({ cmd: 'listExtensions' });
    },
    /* 宿主选完本地安装包：直接发起导入，不再二次确认（文件是用户刚亲手选的）。 */
    picked(msg) {
      if (!msg || !msg.id || !msg.path) return;
      toast = null;
      busy[msg.id] = 'starting';
      progress[msg.id] = 0;
      send({ cmd: 'importExtensionPackage', id: msg.id, path: msg.path });
      render();
    },
    pickCancelled() { /* 用户取消选择：什么都不做 */ }
  };
  window.PerfExtensionsUI = api;

  render();
  window.__refreshExtensions = render;
})();
