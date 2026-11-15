/* 忙碌态、状态文字、进度条 */

/* ── 状态 / 进度 ── */
function setStatus(t) { $('#status').textContent = t; }
function setProgress(p) {
  const v = Math.max(0, Math.min(100, p | 0));
  $('#progressBar').style.width = v + '%';
}
function setBusy(busy) {
  state.busy = busy;
  $('#btnStart').disabled = busy;
  $('#btnStart').textContent = busy ? t('status.capturing', '采集中…') : t('capture.start', '开始采集');
  const stop = $('#btnStop');
  stop.hidden = !busy;
  stop.disabled = false;          // 每轮采集重新可用
  $('#btnProc').disabled = busy;
  $('#btnRefresh').disabled = busy;
  $('#seconds').disabled = busy;
  $$('.collect-grid input').forEach(el => { el.disabled = busy; });
}

