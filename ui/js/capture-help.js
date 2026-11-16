/* 性能采集 →「详细说明」弹窗（批次 C）
   样式复用「发现更新」的 .upd-modal / .upd-modal-box（实色框体 + 主窗口虚化），
   正文容器 #capHelpBody 先留空，后续往里面填内容即可，不用改这里。 */
(function initCaptureHelp() {
  const byId = (id) => document.getElementById(id);
  const modal = byId('capHelpModal');
  const btnOpen = byId('btnCapHelp');
  const btnClose = byId('capHelpClose');
  if (!modal || !btnOpen) return;

  const open = () => {
    modal.hidden = false;
    try { if (btnClose) btnClose.focus(); } catch (e) { }
  };
  const close = () => { modal.hidden = true; };

  btnOpen.addEventListener('click', open);
  if (btnClose) btnClose.addEventListener('click', close);
  /* 点遮罩关闭（点框体内部不关） */
  modal.addEventListener('click', (e) => { if (e.target === modal) close(); });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !modal.hidden) { e.stopPropagation(); close(); }
  });

  window.PerfCaptureHelp = { open: open, close: close };
})();
