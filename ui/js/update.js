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
  if (!banner || !btnCheck) return;

  let phase = 'idle';
  let info = {};

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

  function render() {
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
        break;
      }
      case 'downloading':
        setStatus(fill(tx('update.downloading', '正在下载… {pct}%'), { pct: info.progress || 0 }));
        showBanner(bannerHead(), fill(tx('update.downloading', '正在下载… {pct}%'), { pct: info.progress || 0 }), false);
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
        break;
      case 'error':
        hideBanner();
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
      send({ cmd: 'downloadUpdate', name: info.name, sha256: info.sha256, size: info.size, urls: info.urls || [] });
    } else if (phase === 'ready') {
      send({ cmd: 'runUpdateInstaller', path: info.path, sha256: info.sha256 });
    }
  });

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
    current() { return { phase: phase, info: info }; },
  };

  render();
})();
