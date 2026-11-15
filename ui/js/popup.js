/* 下拉弹层：定位、展开/收起动画、点击切换 */

/* ── 进程弹层 ── */
const popup = $('#popup');
const popupList = $('#popupList');
let popupHideTimer = 0;
let popupAnchor = null;          // 当前弹层的锚点按钮：同一个按钮再点一次 = 收起

function openPopup(anchor, items, onPick, activeIndex = -1) {
  popupList.innerHTML = '';
  items.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'popup-item' + (i === activeIndex ? ' active' : '');
    if (i === activeIndex) {
      const dot = document.createElement('span');
      dot.className = 'dot';
      row.appendChild(dot);
    }
    row.appendChild(document.createTextNode(it.text));
    row.addEventListener('click', () => { closePopup(); onPick(it, i); });
    popupList.appendChild(row);
  });
  popup.hidden = false;
  popupAnchor = anchor;
  popup.style.minWidth = Math.max(220, anchor.offsetWidth) + 'px';
  popup.style.maxWidth = '32rem';

  const r = anchor.getBoundingClientRect();
  popup.style.left = Math.round(r.left) + 'px';
  popup.style.top = Math.round(r.bottom + 4) + 'px';

  // 越界修正
  const pr = popup.getBoundingClientRect();
  if (pr.right > window.innerWidth - 8) {
    popup.style.left = Math.max(8, window.innerWidth - pr.width - 8) + 'px';
  }
  if (pr.bottom > window.innerHeight - 8) {
    popup.style.top = Math.max(8, r.top - pr.height - 4) + 'px';
  }
  // 先量好尺寸再切 .open：display:none → 显示 的那一帧补不回来
  clearTimeout(popupHideTimer);
  popup.classList.remove('open');
  void popup.offsetWidth;          // 强制重排：换锚点时也能重放展开动画
  requestAnimationFrame(() => {
    if (popup.hidden) return;      // 这一帧内被关掉了，别再点亮
    popup.classList.add('open');
    const act = popupList.querySelector('.popup-item.active');
    if (act) act.scrollIntoView({ block: 'center' });
  });
}

/** 同一锚点再点一次就收起，否则执行打开动作 */
function togglePopup(anchor, open) {
  if (popup.classList.contains('open') && popupAnchor === anchor) { closePopup(); return; }
  open();
}

function closePopup() {
  if (popup.hidden || !popup.classList.contains('open')) {
    popup.hidden = true; popupAnchor = null; return;
  }
  popup.classList.remove('open');
  clearTimeout(popupHideTimer);
  popupHideTimer = setTimeout(() => {
    if (!popup.classList.contains('open')) { popup.hidden = true; popupAnchor = null; }
  }, 170);
}
document.addEventListener('mousedown', (e) => {
  if (popup.hidden || popup.contains(e.target)) return;
  // 点在锚点按钮上时交给它自己的 click 处理，否则会被这里先关掉，"再点一次"永远失效
  if (popupAnchor && popupAnchor.contains(e.target)) return;
  closePopup();
}, true);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closePopup(); });
window.addEventListener('blur', closePopup);
