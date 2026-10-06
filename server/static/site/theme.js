(function () {
  try {
    // Only an explicit toggle is saved (site.js). The old "naptable-theme" key was written on every visit, so it is ignored.
    var stored = localStorage.getItem('naptable-theme-preference');
    var prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
    var theme = stored || (prefersDark ? 'dark' : 'light');
    document.documentElement.dataset.theme = theme;
  } catch (_) {}
})();
