(() => {
  const root = document.documentElement;
  const themeColor = document.querySelector('meta[name="theme-color"]');
  const systemTheme = matchMedia("(prefers-color-scheme: light)");
  const storageKey = "bop-theme";
  let preference;
  let button;

  try {
    const saved = localStorage.getItem(storageKey);
    if (saved === "light" || saved === "dark") preference = saved;
  } catch {
    // The system preference still works when storage is unavailable.
  }

  function applyTheme() {
    const theme = preference ?? (systemTheme.matches ? "light" : "dark");
    root.dataset.theme = theme;
    if (button) {
      const label = theme === "light" ? "Switch to dark mode" : "Switch to light mode";
      button.setAttribute("aria-label", label);
      button.title = label;
      themeColor.content = getComputedStyle(root).getPropertyValue("--page").trim();
    }
  }

  applyTheme();
  systemTheme.addEventListener("change", applyTheme);

  document.addEventListener("DOMContentLoaded", () => {
    button = document.querySelector(".theme-toggle");
    applyTheme();
    button.hidden = false;
    button.addEventListener("click", () => {
      preference = root.dataset.theme === "light" ? "dark" : "light";
      applyTheme();
      try {
        localStorage.setItem(storageKey, preference);
      } catch {
        // The chosen theme still applies to this page.
      }
    });
  }, { once: true });
})();
