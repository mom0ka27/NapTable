(function () {
  var root = document.documentElement;
  var button = document.querySelector('.theme-toggle');
  var label = document.querySelector('.theme-label');
  var toast = document.querySelector('.theme-toast');
  // Must match theme.js. Written only when the visitor taps the toggle; otherwise the page follows the system.
  var storageKey = 'naptable-theme-preference';
  var systemDark = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
  function systemTheme() { return systemDark && systemDark.matches ? 'dark' : 'light'; }
  function savedTheme() {
    try {
      var value = localStorage.getItem(storageKey);
      return value === 'dark' || value === 'light' ? value : null;
    } catch (_) { return null; }
  }
  function setTheme(theme, announce) {
    root.dataset.theme = theme;
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
  // Earlier versions saved the current theme on every visit, pinning returning visitors to it.
  try { localStorage.removeItem('naptable-theme'); } catch (_) {}
  setTheme(savedTheme() || systemTheme(), false);
  if (button) button.addEventListener('click', function () {
    var theme = root.dataset.theme === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem(storageKey, theme); } catch (_) {}
    setTheme(theme, true);
  });
  function followSystem() { if (!savedTheme()) setTheme(systemTheme(), false); }
  if (systemDark && systemDark.addEventListener) systemDark.addEventListener('change', followSystem);
  else if (systemDark && systemDark.addListener) systemDark.addListener(followSystem);
  var revealTargets = document.querySelectorAll('[data-reveal]');
  function reveal(el) { el.classList.add('is-visible'); }
  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) { if (entry.isIntersecting) { reveal(entry.target); observer.unobserve(entry.target); } });
    }, { threshold: .12 });
    Array.prototype.forEach.call(revealTargets, function (el) { observer.observe(el); });
  } else Array.prototype.forEach.call(revealTargets, reveal);
})();
