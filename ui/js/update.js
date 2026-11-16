/* 检查更新（前端）：只负责显示与转发命令。
   网络请求、清单验签（RSA-2048/SHA-256）、安装包 SHA-256 校验与下载都在宿主（src/app/70-Updates.ps1）。
   状态机：idle → checking → latest | available → downloading → verifying → ready | error */

(function initUpdateUi() {
  const byId = (id) => document.getElementById(id);
  const banner = byId('updateBanner');
  const bannerText = byId('updateBannerText');
  const btnMain = byId('btnUpdateMain');
  const btnSkip = byId('btnUpdateSkip');
  const statusEl = byId('updateStatus');
  const btnCheck = byId('btnCheckUpdate');
  const chkAuto = byId('chkUpdateAuto');
  const modal = byId('updModal');
  const modalText = byId('updModalText');
  const btnYes = byId('updModalYes');
  const btnNo = byId('updModalNo');
  const progWrap = byId('updProgress');
  const progBar = byId('updProgressBar');
  const progPct = byId('updProgressPct');
  if (!banner || !btnCheck) return;

  let phase = 'idle';
  let info = {};
  let pendingApply = false;     // 用户点过「立即更新」：下载完成后直接进安装并退出当前进程
  let askedVersion = '';        // 本次会话已经问过哪个版本，避免重复弹窗
  let promptPending = false;    // 采集中检测到新版：先压住，采集结束再弹

  const tx = (k, fb) => (typeof t === 'function' ? t(k, fb) : fb);
  const fill = (tpl, p) => Object.keys(p).reduce((s, k) => s.split('{' + k + '}').join(p[k]), tpl);
  const lang = () => ((typeof state !== 'undefined' && state && state.language) || 'zh-CN');
  const note = () => {
    const n = info.notes || {};
    return n[lang()] || n.zh || n.en || '';
  };
  const setStatus = (s) => { if (statusEl) statusEl.textContent = s; };
  const bannerHead = () => fill(tx('update.banner', '有新版本 v{v}'), { v: info.version || '' });

  function showBanner(text, mainLabel, skipVisible) {
    banner.hidden = false;
    bannerText.textContent = text;
    btnMain.textContent = mainLabel;
    btnMain.disabled = false;
    btnSkip.hidden = !skipVisible;
  }
  function hideBanner() { banner.hidden = true; }

  /* 下载进度条：只在下载阶段显示（设置页「检查更新」下方） */
  function setProgress(pct, visible) {
    if (!progWrap) return;
    progWrap.hidden = !visible;
    if (!visible) return;
    const v = Math.max(0, Math.min(100, Math.round(pct || 0)));
    if (progBar) progBar.style.width = v + '%';
    if (progPct) progPct.textContent = v + '%';
  }

  /* 选择下载后立刻切到设置页 → 进度条马上可见 */
  function goSettings() {
    try {
      if (typeof showPage === 'function') { showPage('settings'); return; }
      const btn = document.querySelector('.nav-item[data-page="settings"]');
      if (btn) btn.click();
    } catch (e) { }
  }

  /* ── 新版本二选一弹窗 ──
     用户选择「以后再说」→ 只关弹窗（本次会话不再问同一版本，横幅仍可手动更新）；
     选择「立即更新」→ 下载 → 校验 → 启动安装程序 → 宿主退出当前进程。 */
  function openPrompt() {
    if (!modal) return;
    const v = info.version || '';
    if (askedVersion === v) return;      // 同一版本只问一次
    askedVersion = v;
    if (modalText) {
      modalText.textContent = fill(tx('update.dialogText', '新版本 v{v} 已发布。现在更新吗？'), { v: v });
    }
    modal.hidden = false;
    try { if (btnYes) btnYes.focus(); } catch (e) { }
  }
  function closePrompt() { if (modal) modal.hidden = true; }

  /* 采集中先压住：把「该弹窗」记下来，等采集结束（busy=false）再弹。
     理由：采集中途盖一层遮罩会挡住停止按钮，也打断正在看的数据。 */
  function tryPrompt() {
    const v = info.version || '';
    if (!v) return;
    if (askedVersion === v) { promptPending = false; return; }   // 问过就不再压
    if (typeof state !== 'undefined' && state && state.busy === true) { promptPending = true; return; }
    promptPending = false;
    openPrompt();
  }

  /** 交给宿主：先启动安装窗口，随后宿主关闭当前进程（避免覆盖正在使用的 dll） */
  function applyNow() {
    if (!info.path) { pendingApply = false; return; }
    send({ cmd: 'applyUpdate', path: info.path, sha256: info.sha256 });
  }

  function render() {
    setProgress(0, false);              // 非下载阶段：进度条一律隐藏
    switch (phase) {
      case 'checking':
        hideBanner();
        setStatus(tx('update.checking', '正在检查更新…'));
        btnCheck.disabled = true;
        break;
      case 'latest':
        hideBanner();
        setStatus(fill(tx('update.latest', '已是最新版本（v{v}）'), { v: info.version || info.current || '' }));
        btnCheck.disabled = false;
        break;
      case 'available': {
        setStatus(fill(tx('update.available', '发现新版本 v{v}'), { v: info.version || '' }));
        const extra = note();
        showBanner(bannerHead() + (extra ? ' · ' + extra : ''), tx('update.download', '下载'), true);
        btnCheck.disabled = false;
        tryPrompt();
        break;
      }
      case 'downloading':
        setStatus(fill(tx('update.downloading', '正在下载… {pct}%'), { pct: info.progress || 0 }));
        showBanner(bannerHead(), fill(tx('update.downloading', '正在下载… {pct}%'), { pct: info.progress || 0 }), false);
        setProgress(info.progress || 0, true);
        btnMain.disabled = true;
        break;
      case 'verifying':
        hideBanner();
        setStatus(tx('update.verifying', '正在校验完整性…'));
        btnCheck.disabled = true;
        break;
      case 'ready':
        setStatus(tx('update.ready', '已下载并通过校验，可以安装'));
        showBanner(bannerHead(), tx('update.runInstaller', '运行安装包'), false);
        btnCheck.disabled = false;
        closePrompt();
        if (pendingApply) { pendingApply = false; applyNow(); }
        break;
      case 'error':
        hideBanner();
        closePrompt();
        pendingApply = false;
        setStatus(tx('update.error', '检查更新失败') + (info.hint ? ' · ' + tx(info.hint, '') : ''));
        btnCheck.disabled = false;
        break;
      default:
        setStatus(tx('settings.updateIdle', '启动后会自动检查一次，也可以手动点按钮'));
        btnCheck.disabled = false;
        break;
    }
  }

  const handlers = {
    checking: (m) => { phase = 'checking'; info = Object.assign({}, info, m); },
    latest: (m) => { phase = 'latest'; info = Object.assign({}, info, m); },
    available: (m) => { phase = 'available'; info = Object.assign({}, info, m); },
    downloading: (m) => { phase = 'downloading'; info = Object.assign({}, info, m); },
    verifying: (m) => { phase = 'verifying'; info = Object.assign({}, info, m); },
    ready: (m) => { phase = 'ready'; info = Object.assign({}, info, m); },
    error: (m) => { phase = 'error'; info = Object.assign({}, info, m); },
    idle: () => { phase = 'idle'; },
  };

  btnCheck.addEventListener('click', () => {
    phase = 'checking';
    render();
    send({ cmd: 'checkUpdate' });
  });

  btnMain.addEventListener('click', () => {
    if (phase === 'available') {
      goSettings();                     // 选下载就切到设置页（进度条在「检查更新」下方）
      send({ cmd: 'downloadUpdate', name: info.name, sha256: info.sha256, size: info.size, urls: info.urls || [] });
    } else if (phase === 'ready') {
      // 横幅上的「运行安装包」：只起安装程序（宿主不退出）；弹窗里的「立即更新」才会装完退出
      send({ cmd: 'runUpdateInstaller', path: info.path, sha256: info.sha256 });
    }
  });

  // 弹窗：否 → 只关；是 → 下载（若已就绪直接安装）
  if (btnNo) {
    btnNo.addEventListener('click', () => { closePrompt(); });
  }
  if (btnYes) {
    btnYes.addEventListener('click', () => {
      closePrompt();
      if (phase === 'ready') { applyNow(); return; }
      pendingApply = true;
      goSettings();                     // 立即跳到设置页，进度条当场可见
      send({ cmd: 'downloadUpdate', name: info.name, sha256: info.sha256, size: info.size, urls: info.urls || [] });
    });
  }

  btnSkip.addEventListener('click', () => {
    if (info.version) send({ cmd: 'skipUpdateVersion', version: info.version });
  });

  if (chkAuto) {
    chkAuto.addEventListener('change', () => send({ cmd: 'setUpdateAuto', auto: chkAuto.checked }));
  }

  window.PerfUpdate = {
    handle(msg) {
      const h = handlers[msg.state];
      if (h) h(msg);
      render();
    },
    init(cfg) {
      if (chkAuto) chkAuto.checked = !(cfg && cfg.auto === false);
      if (cfg && cfg.lastCheckAt) {
        setStatus(fill(tx('settings.updateLast', '上次检查：{t}'), { t: cfg.lastCheckAt }));
      } else {
        setStatus(tx('settings.updateIdle', '启动后会自动检查一次，也可以手动点按钮'));
      }
    },
    refresh() { render(); },
    /* 采集状态变化：采集刚结束（busy=false）时，把被压住的弹窗补上 */
    busy(value) {
      if (value || !promptPending) return;
      promptPending = false;
      openPrompt();
    },
    current() { return { phase: phase, info: info }; },
  };

  render();
})();
