(function () {
  var root = document.documentElement;
  var button = document.querySelector('.theme-toggle');
  var label = document.querySelector('.theme-label');
  var toast = document.querySelector('.theme-toast');
  function setTheme(theme, announce) {
    root.dataset.theme = theme;
    try { localStorage.setItem('naptable-theme', theme); } catch (_) {}
    if (button) {
      button.setAttribute('aria-pressed', theme === 'dark');
      button.setAttribute('aria-label', theme === 'dark' ? '切换为浅色模式' : '切换为深色模式');
    }
    if (label) label.textContent = theme === 'dark' ? '深色' : '浅色';
    if (announce && toast) {
      toast.textContent = theme === 'dark' ? '已切换为深色模式，App 预览同步更新' : '已切换为浅色模式，App 预览同步更新';
      toast.classList.add('show');
      clearTimeout(window.__napToast); window.__napToast = setTimeout(function () { toast.classList.remove('show'); }, 2300);
    }
  }
  setTheme(root.dataset.theme || 'light', false);
  if (button) button.addEventListener('click', function () { setTheme(root.dataset.theme === 'dark' ? 'light' : 'dark', true); });
  var observer = new IntersectionObserver(function (entries) { entries.forEach(function (entry) { if (entry.isIntersecting) entry.target.classList.add('is-visible'); }); }, { threshold: .12 });
  document.querySelectorAll('[data-reveal]').forEach(function (el) { observer.observe(el); });
})();
