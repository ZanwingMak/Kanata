/** 绑定配色按钮，仅更新官网示意画面；无参数和返回值，缺少预览元素时跳过。 */
function setupPalettePreview() {
  const preview = document.querySelector('#preview');
  if (!preview) return;
  const buttons = document.querySelectorAll('.palette');
  for (const button of buttons) {
    /** 点击选中的配色并同步按钮状态；无参数和返回值，不发起网络请求。 */
    button.addEventListener('click', function selectPalette() {
      preview.dataset.palette = button.dataset.palette;
      for (const option of buttons) {
        option.setAttribute('aria-pressed', String(option === button));
      }
    });
  }
}

/** 绑定弹幕示意动效开关；无参数和返回值，缺少元素时跳过，减少动态效果时禁用。 */
function setupMotionControl() {
  const preview = document.querySelector('#preview');
  const button = document.querySelector('#preview-motion');
  if (!preview || !button) return;
  const preference = window.matchMedia('(prefers-reduced-motion: reduce)');

  /** 同步系统减少动态效果偏好；无参数和返回值，系统设置变化时保留用户暂停状态。 */
  function updateMotionPreference() {
    button.disabled = preference.matches;
    button.textContent = preference.matches ? '静态预览' : preview.classList.contains('is-paused') ? '继续动效 ▷' : '暂停动效 Ⅱ';
  }

  /** 切换示意弹幕的暂停状态；无参数和返回值，不控制任何音视频播放。 */
  button.addEventListener('click', function togglePreviewMotion() {
    const paused = preview.classList.toggle('is-paused');
    button.setAttribute('aria-pressed', String(paused));
    updateMotionPreference();
  });
  preference.addEventListener('change', updateMotionPreference);
  updateMotionPreference();
}

setupPalettePreview();
setupMotionControl();
