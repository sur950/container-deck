/* Container Deck website: theme toggle, header, mobile menu, copy buttons,
   screenshot tabs and reveal on scroll. No dependencies. */
(function () {
  "use strict";

  var root = document.documentElement;
  var KEY = "deck-theme";
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  var live = document.getElementById("live");

  function announce(text) {
    if (!live) return;
    live.textContent = "";
    setTimeout(function () { live.textContent = text; }, 30);
  }

  /* ---------- Theme ---------- */

  function saved() {
    try { return localStorage.getItem(KEY) || "system"; } catch (e) { return "system"; }
  }

  function isDark(choice) {
    return choice === "dark" || (choice === "system" && darkQuery.matches);
  }

  // <picture> sources pick light or dark screenshots. Follow the toggle, not only the system.
  function syncPictures(choice) {
    var sources = document.querySelectorAll("source[data-scheme]");
    for (var i = 0; i < sources.length; i++) {
      var s = sources[i];
      var forDark = s.getAttribute("data-scheme") === "dark";
      if (choice === "system") s.setAttribute("media", "(prefers-color-scheme: " + (forDark ? "dark" : "light") + ")");
      else s.setAttribute("media", isDark(choice) === forDark ? "all" : "not all");
    }
  }

  function syncThemeColor(choice) {
    var metas = document.querySelectorAll('meta[name="theme-color"]');
    for (var i = 0; i < metas.length; i++) {
      var m = metas[i];
      if (!m.hasAttribute("data-media")) m.setAttribute("data-media", m.getAttribute("media") || "");
      if (choice === "system") m.setAttribute("media", m.getAttribute("data-media"));
      else m.setAttribute("media", (/dark/.test(m.getAttribute("data-media")) === isDark(choice)) ? "all" : "not all");
    }
  }

  function applyTheme(choice) {
    if (choice === "light" || choice === "dark") root.setAttribute("data-theme", choice);
    else root.removeAttribute("data-theme");
    syncPictures(choice);
    syncThemeColor(choice);
    var buttons = document.querySelectorAll("[data-theme-choice]");
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", String(buttons[i].getAttribute("data-theme-choice") === choice));
    }
  }

  applyTheme(saved());
  document.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest("[data-theme-choice]");
    if (!b) return;
    var choice = b.getAttribute("data-theme-choice");
    try {
      if (choice === "system") localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, choice);
    } catch (err) {}
    applyTheme(choice);
  });
  var onSystem = function () { if (saved() === "system") applyTheme("system"); };
  if (darkQuery.addEventListener) darkQuery.addEventListener("change", onSystem);
  else if (darkQuery.addListener) darkQuery.addListener(onSystem);

  /* ---------- Header and menu ---------- */

  var header = document.querySelector(".site-header");
  var onScroll = function () { header.classList.toggle("scrolled", window.scrollY > 4); };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  var menu = document.querySelector(".menu-button");
  var nav = document.getElementById("site-nav");
  function setMenu(open) {
    nav.classList.toggle("open", open);
    menu.setAttribute("aria-expanded", String(open));
  }
  if (menu && nav) {
    menu.addEventListener("click", function () { setMenu(!nav.classList.contains("open")); });
    nav.addEventListener("click", function (e) { if (e.target.closest("a")) setMenu(false); });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && nav.classList.contains("open")) { setMenu(false); menu.focus(); }
    });
    document.addEventListener("click", function (e) {
      if (nav.classList.contains("open") && !nav.contains(e.target) && !menu.contains(e.target)) setMenu(false);
    });
  }

  // Highlight the nav link for the section in view.
  var navLinks = document.querySelectorAll('.site-nav a[href^="#"]');
  if ("IntersectionObserver" in window && navLinks.length) {
    var byId = {};
    navLinks.forEach(function (a) { byId[a.getAttribute("href").slice(1)] = a; });
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        var a = byId[en.target.id];
        if (!a) return;
        if (en.isIntersecting) {
          navLinks.forEach(function (l) { l.removeAttribute("aria-current"); });
          a.setAttribute("aria-current", "true");
        } else {
          a.removeAttribute("aria-current");
        }
      });
    }, { rootMargin: "-45% 0px -50% 0px" });
    Object.keys(byId).forEach(function (id) { var t = document.getElementById(id); if (t) spy.observe(t); });
  }

  /* ---------- Copy ---------- */

  function legacyCopy(text) {
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "0";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error("copy failed"));
    });
  }

  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
    }
    return legacyCopy(text);
  }

  document.addEventListener("click", function (e) {
    var btn = e.target.closest && e.target.closest("[data-copy]");
    if (!btn) return;
    var scope = btn.closest("[data-copy-scope]");
    var src = scope && scope.querySelector("[data-copy-text]");
    if (!src) return;
    var label = btn.querySelector(".copy-label");
    copyText(src.textContent.trim()).then(function () {
      btn.classList.add("copied");
      if (label) label.textContent = "Copied";
      announce("Copied to the clipboard");
      clearTimeout(btn._t);
      btn._t = setTimeout(function () {
        btn.classList.remove("copied");
        if (label) label.textContent = "Copy";
      }, 1800);
    }, function () {
      announce("Copy failed. Select the text and copy it.");
    });
  });

  /* ---------- Tabs ---------- */

  document.querySelectorAll("[data-tabs]").forEach(function (box) {
    var tabs = Array.prototype.slice.call(box.querySelectorAll('[role="tab"]'));
    function select(tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", String(on));
        t.tabIndex = on ? 0 : -1;
        var panel = document.getElementById(t.getAttribute("aria-controls"));
        if (!panel) return;
        if (on) {
          panel.hidden = false;
          panel.classList.remove("entering");
          void panel.offsetWidth;
          panel.classList.add("entering");
        } else {
          panel.hidden = true;
        }
      });
      if (focus) {
        tab.focus();
        tab.scrollIntoView({ block: "nearest", inline: "nearest" });
      }
    }
    tabs.forEach(function (t, i) {
      t.addEventListener("click", function () { select(t, false); });
      t.addEventListener("keydown", function (e) {
        var next = null;
        if (e.key === "ArrowRight") next = tabs[(i + 1) % tabs.length];
        else if (e.key === "ArrowLeft") next = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === "Home") next = tabs[0];
        else if (e.key === "End") next = tabs[tabs.length - 1];
        if (next) { e.preventDefault(); select(next, true); }
      });
    });
  });

  /* ---------- GitHub numbers and releases ---------- */

  // Two unauthenticated API calls, cached for 30 minutes (GitHub allows 60 an hour per address).
  // On failure an older cache (up to a week) is used, else the numbers stay hidden.
  var API = "https://api.github.com/repos/sur950/container-deck";
  var CACHE_KEY = "deck-gh-v1";
  var FRESH = 30 * 60 * 1000;
  var STALE = 7 * 24 * 60 * 60 * 1000;

  function readCache() {
    try { return JSON.parse(localStorage.getItem(CACHE_KEY) || "null"); } catch (e) { return null; }
  }

  function isInstaller(name) { return /\.(pkg|dmg)$/i.test(name || ""); }

  function shape(repo, releases) {
    var downloads = 0;
    var list = [];
    (releases || []).forEach(function (r) {
      var dmg = null, pkg = null;
      (r.assets || []).forEach(function (a) {
        if (isInstaller(a.name)) downloads += a.download_count || 0;
        if (/\.dmg$/i.test(a.name)) dmg = { url: a.browser_download_url, size: a.size };
        if (/\.pkg$/i.test(a.name)) pkg = { url: a.browser_download_url, size: a.size };
      });
      if (r.draft || r.prerelease) return;
      list.push({ tag: r.tag_name, date: r.published_at, url: r.html_url, dmg: dmg, pkg: pkg });
    });
    return { stars: repo.stargazers_count || 0, forks: repo.forks_count || 0, downloads: downloads, releases: list.slice(0, 4) };
  }

  var ghPromise = null;
  function loadGitHub() {
    if (ghPromise) return ghPromise;
    var cached = readCache();
    if (cached && cached.data && Date.now() - cached.t < FRESH) return (ghPromise = Promise.resolve(cached.data));
    if (!window.fetch) return (ghPromise = Promise.resolve(null));
    var get = function (path) {
      return fetch(API + path, { headers: { Accept: "application/vnd.github+json" } }).then(function (r) {
        if (!r.ok) throw new Error("GitHub " + r.status);
        return r.json();
      });
    };
    ghPromise = Promise.all([get(""), get("/releases?per_page=100")]).then(function (res) {
      var data = shape(res[0], res[1]);
      try { localStorage.setItem(CACHE_KEY, JSON.stringify({ t: Date.now(), data: data })); } catch (e) {}
      return data;
    }).catch(function () {
      return cached && cached.data && Date.now() - cached.t < STALE ? cached.data : null;
    });
    return ghPromise;
  }

  var compact = window.Intl && Intl.NumberFormat ? new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 }) : null;
  function formatCount(n) { return compact ? compact.format(n) : String(n); }

  function renderStats(data) {
    var box = document.getElementById("gh-stats");
    if (!box || !data) return;
    var shown = 0;
    ["downloads", "stars", "forks"].forEach(function (key) {
      var li = box.querySelector('[data-stat="' + key + '"]');
      var n = data[key];
      if (!li || !(n > 0)) return; // never show 0
      li.querySelector("[data-value]").textContent = formatCount(n);
      var label = li.querySelector("[data-label]");
      label.textContent = n === 1 ? label.getAttribute("data-one") : label.getAttribute("data-many");
      // The pill shows 1.2K, the exact number goes in the tooltip and the accessible name.
      var exact = (window.Intl ? new Intl.NumberFormat("en").format(n) : String(n)) + " " + label.textContent;
      var link = li.querySelector("a");
      link.title = exact;
      link.setAttribute("aria-label", exact + " on GitHub");
      li.hidden = false;
      shown++;
    });
    if (shown) box.setAttribute("data-state", "ready");
  }

  loadGitHub().then(renderStats);

  /* ---------- Download dialog ---------- */

  var dialog = document.getElementById("download-dialog");
  var dateFormat = window.Intl ? new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "long", year: "numeric" }) : null;
  function formatDate(iso) {
    var d = new Date(iso);
    if (isNaN(d)) return "";
    return dateFormat ? dateFormat.format(d) : d.toDateString();
  }
  function formatSize(bytes) { return bytes > 0 ? (bytes / 1e6).toFixed(1) + " MB" : ""; }
  function version(tag) { return String(tag || "").replace(/^v/i, ""); }

  function fillDialog(data) {
    if (!dialog || !data || !data.releases || !data.releases.length) return;
    var q = function (name) { return dialog.querySelector('[data-rel="' + name + '"]'); };
    var latest = data.releases[0];
    q("version").textContent = "Version " + version(latest.tag);
    var date = formatDate(latest.date);
    if (date) { q("date").textContent = date; q("date").hidden = false; }
    q("notes").href = latest.url;
    [["dmg", latest.dmg], ["pkg", latest.pkg]].forEach(function (pair) {
      if (!pair[1]) return;
      q(pair[0]).href = pair[1].url;
      var size = formatSize(pair[1].size);
      if (size) { q(pair[0] + "-size").textContent = size; q(pair[0] + "-size").hidden = false; }
    });
    var older = data.releases.slice(1, 4);
    var list = q("older");
    list.textContent = "";
    older.forEach(function (r) {
      var li = document.createElement("li");
      var a = document.createElement("a");
      a.href = r.url;
      a.textContent = "Version " + version(r.tag);
      var span = document.createElement("span");
      span.textContent = formatDate(r.date);
      li.appendChild(a);
      li.appendChild(span);
      list.appendChild(li);
    });
    list.hidden = older.length === 0;
    q("older-empty").hidden = older.length !== 0;
  }

  if (dialog && typeof dialog.showModal === "function") {
    var opener = null;
    loadGitHub().then(fillDialog);
    document.addEventListener("click", function (e) {
      var link = e.target.closest && e.target.closest("[data-download]");
      if (!link || e.metaKey || e.ctrlKey || e.shiftKey || e.button > 0) return;
      e.preventDefault();
      opener = link;
      if (nav && nav.classList.contains("open")) setMenu(false);
      dialog.showModal();
      var first = dialog.querySelector('[data-rel="dmg"]');
      if (first) first.focus();
    });
    dialog.addEventListener("click", function (e) {
      // The dialog box itself is only hit on the backdrop: the content fills it.
      if (e.target === dialog || (e.target.closest && e.target.closest("[data-close]"))) dialog.close();
    });
    dialog.addEventListener("keydown", function (e) {
      if (e.key !== "Tab") return;
      var items = Array.prototype.filter.call(
        dialog.querySelectorAll('a[href], button:not([disabled]), [tabindex]:not([tabindex="-1"])'),
        function (el) { return el.offsetParent !== null; }
      );
      if (!items.length) return;
      var firstItem = items[0], lastItem = items[items.length - 1];
      if (e.shiftKey && document.activeElement === firstItem) { e.preventDefault(); lastItem.focus(); }
      else if (!e.shiftKey && document.activeElement === lastItem) { e.preventDefault(); firstItem.focus(); }
    });
    dialog.addEventListener("close", function () {
      if (opener && document.contains(opener)) {
        var target = opener;
        // The header button can be hidden on small screens. Then return to the menu button.
        if (!target.offsetParent && menu) target = menu;
        target.focus();
      }
    });
  }

  /* ---------- Guide pages: table of contents follows the reading position ---------- */

  var tocLinks = document.querySelectorAll(".doc-toc-side a[href^='#']");
  if (tocLinks.length && "IntersectionObserver" in window) {
    var headings = [];
    tocLinks.forEach(function (a) {
      var h = document.getElementById(decodeURIComponent(a.getAttribute("href").slice(1)));
      if (h) headings.push({ el: h, link: a });
    });
    var markCurrent = function () {
      var current = headings[0];
      for (var i = 0; i < headings.length; i++) {
        if (headings[i].el.getBoundingClientRect().top < 140) current = headings[i];
        else break;
      }
      tocLinks.forEach(function (a) { a.removeAttribute("aria-current"); });
      if (current) current.link.setAttribute("aria-current", "true");
    };
    var tocTicking = false;
    window.addEventListener("scroll", function () {
      if (tocTicking) return;
      tocTicking = true;
      requestAnimationFrame(function () { markCurrent(); tocTicking = false; });
    }, { passive: true });
    markCurrent();
  }

  /* ---------- Reveal ---------- */

  var reveals = document.querySelectorAll(".reveal");
  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduce && "IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add("in"); io.unobserve(en.target); }
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.06 });
    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add("in"); });
  }
})();
