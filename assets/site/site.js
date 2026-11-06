/* Container Deck site.
   Progressive enhancement of the README that Jekyll renders. Without this script
   the page is a clean, readable document. With it, the home page becomes a
   sectioned site. No frameworks. */
(function () {
  "use strict";

  var root = document.documentElement;
  var body = document.body;
  var article = document.querySelector(".markdown-body");
  var THEME_KEY = "deck-theme";
  var REPO = "https://github.com/sur950/container-deck";
  var darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

  /* ---------- Icons (24 px grid, stroked) ---------- */

  var ICONS = {
    bolt: '<path d="M13 2.5 4.8 13.4h6.4L10.6 21.5l8.6-11.2h-6.6L13 2.5Z"/>',
    window: '<rect x="3" y="4.5" width="18" height="15" rx="2.6"/><path d="M3 9h18"/><circle cx="6.2" cy="6.8" r=".5"/><circle cx="8.4" cy="6.8" r=".5"/>',
    leaf: '<path d="M5 19.5C5 11 10 5 20 4.2c-.6 9.8-6.4 15.3-15 15.3Z"/><path d="M5 19.5 12.5 12"/>',
    terminal: '<rect x="3" y="4.5" width="18" height="15" rx="2.6"/><path d="m7.5 10 3 2.5-3 2.5M12.5 15.5h4"/>',
    lock: '<rect x="5" y="10.5" width="14" height="10" rx="2.4"/><path d="M8.5 10.5V7.8a3.5 3.5 0 0 1 7 0v2.7"/><path d="M12 14.5v2"/>',
    hammer: '<path d="m14.5 6.5 3 3M4 20l8.6-8.6"/><path d="M11.5 5.5 14 3l6 6-2.5 2.5-2-2-1.4 1.4-3-3 1.4-1.4-1-1Z"/>',
    layers: '<path d="m12 3.5 8.5 4.3-8.5 4.3-8.5-4.3L12 3.5Z"/><path d="m3.5 12 8.5 4.3 8.5-4.3M3.5 16.2l8.5 4.3 8.5-4.3"/>',
    monitor: '<rect x="3" y="4" width="18" height="12.5" rx="2.4"/><path d="M8.5 20h7M12 16.5V20"/>',
    cube: '<path d="m12 3 8 4.5v9L12 21l-8-4.5v-9L12 3Z"/><path d="m4 7.5 8 4.5 8-4.5M12 12v9"/>',
    users: '<path d="M15.5 20v-1.3a3.7 3.7 0 0 0-3.7-3.7H7.2a3.7 3.7 0 0 0-3.7 3.7V20"/><circle cx="9.5" cy="8" r="3.5"/><path d="M20.5 20v-1.3a3.7 3.7 0 0 0-2.8-3.6M15.3 4.6a3.5 3.5 0 0 1 0 6.8"/>',
    shield: '<path d="M12 3 4.8 6v5.4c0 4.5 3.1 8.3 7.2 9.6 4.1-1.3 7.2-5.1 7.2-9.6V6L12 3Z"/><path d="m9 12 2.1 2.1 4-4.2"/>',
    doc: '<path d="M7 3h7.2L19 7.8V21H7V3Z"/><path d="M14 3v5h5M10 13h6M10 17h6"/>',
    heart: '<path d="M12 20s-7.8-4.7-7.8-10.3a4.4 4.4 0 0 1 7.8-2.8 4.4 4.4 0 0 1 7.8 2.8C19.8 15.3 12 20 12 20Z"/>',
    download: '<path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2.4"/><path d="M16 8V6.4A2.4 2.4 0 0 0 13.6 4H6.4A2.4 2.4 0 0 0 4 6.4v7.2A2.4 2.4 0 0 0 6.4 16H8"/>',
    check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
    arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>'
  };

  function icon(name, cls) {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"' + (cls ? ' class="' + cls + '"' : "") + ">" + (ICONS[name] || ICONS.cube) + "</svg>";
  }
  var MARKS = {
    yes: '<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9.5" fill="currentColor" opacity=".15"/><path d="M6 10.4 8.7 13 14 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    no: '<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9.5" fill="currentColor" opacity=".16"/><path d="M7 10h6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    partial: '<svg viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="9.5" fill="currentColor" opacity=".16"/><path d="M10 4.6a5.4 5.4 0 0 1 0 10.8Z" fill="currentColor"/></svg>'
  };

  function el(tag, cls, html) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (html != null) n.innerHTML = html;
    return n;
  }

  /* ---------- Appearance ---------- */

  function savedChoice() {
    try { return localStorage.getItem(THEME_KEY) || "system"; } catch (e) { return "system"; }
  }

  // <picture> sources use prefers-color-scheme. Rewrite their media so they follow the site toggle.
  function syncPictures(choice) {
    var sources = document.querySelectorAll('picture source[media*="prefers-color-scheme"], picture source[data-media]');
    for (var i = 0; i < sources.length; i++) {
      var s = sources[i];
      if (!s.hasAttribute("data-media")) s.setAttribute("data-media", s.getAttribute("media"));
      var original = s.getAttribute("data-media");
      if (choice === "system") {
        s.setAttribute("media", original);
      } else {
        var forDark = /dark/.test(original);
        s.setAttribute("media", (choice === "dark") === forDark ? "all" : "not all");
      }
    }
  }

  function applyTheme(choice) {
    if (choice === "light" || choice === "dark") root.setAttribute("data-theme", choice);
    else root.removeAttribute("data-theme");
    syncPictures(choice);
    var buttons = document.querySelectorAll("[data-theme-choice]");
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", String(buttons[i].getAttribute("data-theme-choice") === choice));
    }
  }

  function initTheme() {
    applyTheme(savedChoice());
    document.addEventListener("click", function (e) {
      var b = e.target.closest && e.target.closest("[data-theme-choice]");
      if (!b) return;
      var choice = b.getAttribute("data-theme-choice");
      try {
        if (choice === "system") localStorage.removeItem(THEME_KEY);
        else localStorage.setItem(THEME_KEY, choice);
      } catch (err) {}
      applyTheme(choice);
    });
    var onSystemChange = function () { if (savedChoice() === "system") applyTheme("system"); };
    if (darkQuery.addEventListener) darkQuery.addEventListener("change", onSystemChange);
    else if (darkQuery.addListener) darkQuery.addListener(onSystemChange);
  }

  /* ---------- Header ---------- */

  function initHeader() {
    var header = document.querySelector(".site-header");
    var onScroll = function () { header.classList.toggle("scrolled", window.scrollY > 4); };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();

    var menu = document.querySelector(".menu-button");
    var nav = document.getElementById("site-nav");
    if (menu && nav) {
      menu.addEventListener("click", function () {
        var open = nav.classList.toggle("open");
        menu.setAttribute("aria-expanded", String(open));
      });
      nav.addEventListener("click", function (e) {
        if (e.target.tagName === "A") { nav.classList.remove("open"); menu.setAttribute("aria-expanded", "false"); }
      });
    }
  }

  /* ---------- Links ---------- */

  // Raw HTML links in the README point at .md files (right for github.com). On the site those are .html pages.
  function fixMarkdownLinks() {
    var links = article.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i++) {
      var href = links[i].getAttribute("href");
      if (/^(https?:|mailto:|#|\/\/)/i.test(href)) continue;
      // GitHub Pages never renders these as pages, so send readers to github.com for them.
      var file = href.replace(/^\.\//, "").split("#")[0];
      if (/^(CONTRIBUTING\.md|CODE_OF_CONDUCT\.md|LICENSE)$/i.test(file)) {
        links[i].setAttribute("href", REPO + "/blob/main/" + href.replace(/^\.\//, ""));
      } else if (/\.md(#.*)?$/i.test(href)) {
        links[i].setAttribute("href", href.replace(/\.md(#.*)?$/i, ".html$1"));
      }
    }
  }

  /* ---------- Code blocks ---------- */

  function copyText(text, button) {
    var done = function () {
      button.classList.add("copied");
      var label = button.querySelector("span");
      if (label) label.textContent = "Copied";
      setTimeout(function () { button.classList.remove("copied"); if (label) label.textContent = "Copy"; }, 1600);
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    } else {
      fallbackCopy(text); done();
    }
  }
  function fallbackCopy(text) {
    var t = document.createElement("textarea");
    t.value = text; t.setAttribute("readonly", ""); t.style.position = "fixed"; t.style.opacity = "0";
    document.body.appendChild(t); t.select();
    try { document.execCommand("copy"); } catch (e) {}
    document.body.removeChild(t);
  }
  function copyButton(getText) {
    var b = el("button", "copy-btn", icon("copy") + "<span>Copy</span>");
    b.type = "button";
    b.setAttribute("aria-label", "Copy to clipboard");
    b.addEventListener("click", function () { copyText(getText(), b); });
    return b;
  }

  function initCodeBlocks() {
    var pres = article.querySelectorAll("pre");
    for (var i = 0; i < pres.length; i++) {
      var pre = pres[i];
      var host = pre.closest(".highlighter-rouge") || pre.parentNode;
      if (host === article || host.classList.contains("code-wrap")) {
        var w = el("div", "code-wrap");
        pre.parentNode.insertBefore(w, pre);
        w.appendChild(pre);
        host = w;
      }
      host.classList.add("code-wrap");
      (function (p) {
        host.appendChild(copyButton(function () { return p.innerText.replace(/\n$/, ""); }));
      })(pre);
    }
  }

  /* ---------- Lightbox ---------- */

  function initLightbox() {
    var box = el("figure", "lightbox");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-label", "Screenshot");
    box.innerHTML = '<button type="button" aria-label="Close">&times;</button><img alt=""><figcaption></figcaption>';
    document.body.appendChild(box);
    var big = box.querySelector("img");
    var cap = box.querySelector("figcaption");
    var lastFocus = null;
    function close() { box.classList.remove("open"); if (lastFocus) lastFocus.focus(); }
    box.addEventListener("click", close);
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && box.classList.contains("open")) close(); });
    document.addEventListener("click", function (e) {
      var frame = e.target.closest && e.target.closest(".frame");
      if (!frame) return;
      e.preventDefault();
      var img = frame.querySelector("img");
      big.src = img.currentSrc || img.src;
      big.alt = img.alt;
      cap.textContent = img.alt;
      lastFocus = frame;
      box.classList.add("open");
      box.querySelector("button").focus();
    });
  }

  function framed(img) {
    var a = el("a", "frame");
    a.href = img.currentSrc || img.getAttribute("src");
    a.setAttribute("aria-label", "Enlarge: " + (img.alt || "screenshot"));
    var pic = img.closest("picture");
    var node = pic || img;
    node.parentNode.insertBefore(a, node);
    a.appendChild(node);
    img.removeAttribute("width");
    return a;
  }

  /* ---------- Home page ---------- */

  function sliceUntil(start, stop) {
    // start and every following sibling until stop(node) is true.
    var out = [];
    var n = start;
    while (n) {
      if (n !== start && stop(n)) break;
      out.push(n);
      n = n.nextElementSibling;
    }
    return out;
  }

  function isTag(n, tag) { return n && n.tagName === tag; }
  function textOf(n) { return (n.textContent || "").trim(); }

  function sectionHead(h2, eyebrow, lead) {
    var head = el("div", "section-head reveal");
    if (eyebrow) head.appendChild(el("p", "eyebrow", eyebrow));
    head.appendChild(h2);
    if (lead) { lead.classList.add("lead"); head.appendChild(lead); }
    return head;
  }

  function band(id, alt, extra) {
    var s = el("section", "band" + (alt ? " alt" : "") + (extra ? " " + extra : ""));
    if (id) s.setAttribute("data-section", id);
    var w = el("div", "wrap");
    s.appendChild(w);
    return { section: s, wrap: w };
  }

  // A list item like "<strong>Fast.</strong> Text" becomes a card.
  function listToCards(ul, iconFor, cls) {
    ul.classList.add("card-grid");
    if (cls) cls.split(" ").forEach(function (c) { ul.classList.add(c); });
    var items = ul.children;
    for (var i = 0; i < items.length; i++) {
      var li = items[i];
      var strong = li.querySelector("strong");
      var title = strong ? textOf(strong).replace(/[.:]$/, "") : "";
      if (strong) strong.parentNode.removeChild(strong);
      var rest = li.innerHTML.replace(/^\s*[:.]?\s*/, "");
      li.className = "card reveal";
      li.innerHTML =
        '<div class="card-icon">' + icon(iconFor(title)) + "</div>" +
        (title ? '<span class="card-title">' + title + "</span>" : "") +
        '<p class="card-text">' + rest + "</p>";
    }
    return ul;
  }

  function pickIcon(title) {
    var t = title.toLowerCase();
    if (/fast/.test(t)) return "bolt";
    if (/native/.test(t)) return "window";
    if (/light/.test(t)) return "leaf";
    if (/honest/.test(t)) return "terminal";
    if (/privat/.test(t)) return "lock";
    if (/build/.test(t)) return "hammer";
    if (/compose/.test(t)) return "layers";
    if (/machine/.test(t)) return "monitor";
    return "cube";
  }

  function buildHero(nodes) {
    var hero = el("section", "hero");
    var w = el("div", "wrap");
    hero.appendChild(w);
    var logo, title, lead, badges, links, shot;
    nodes.forEach(function (n) {
      if (/^H[1-6]$/.test(n.tagName) && !title) { title = n; return; }
      if (n.tagName !== "P") return;
      if (n.querySelector('img[src*="shields.io"], img[src*="badge"]')) { badges = n; return; }
      if (n.querySelector("picture") && !logo && !title) { logo = n; return; }
      if (n.querySelector("picture, img")) { shot = n; return; }
      if (n.querySelectorAll("a").length >= 2) { links = n; return; }
      if (!lead) lead = n;
    });

    if (logo) { logo.classList.add("hero-logo"); logo.removeAttribute("align"); w.appendChild(logo); }

    if (title) {
      var h1 = el("h1", "hero-title");
      var parts = title.innerHTML.split(/<br\s*\/?>/i);
      h1.innerHTML = parts.map(function (p, i) {
        return '<span class="line' + (i === parts.length - 1 && parts.length > 1 ? " line-accent" : "") + '">' + p.trim() + "</span>";
      }).join("");
      w.appendChild(h1);
    }
    if (lead) { lead.className = "hero-lead"; lead.removeAttribute("align"); w.appendChild(lead); }

    var actions = el("div", "hero-actions");
    if (links) {
      var anchors = links.querySelectorAll("a");
      if (anchors[0]) {
        var primary = el("a", "btn btn-primary", icon("download") + textOf(anchors[0]));
        primary.href = anchors[0].getAttribute("href");
        actions.appendChild(primary);
      }
      var gh = el("a", "btn btn-secondary", '<svg viewBox="0 0 16 16" aria-hidden="true" style="fill:currentColor;stroke:none"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>View on GitHub');
      gh.href = REPO;
      actions.appendChild(gh);
      links.className = "hero-links";
      w.appendChild(actions);
      w.appendChild(links);
    }

    // The install one liner, taken from the Install section, as a copyable chip.
    var install = document.getElementById("install");
    var firstCode = null;
    if (install) {
      var n = install.nextElementSibling;
      while (n && n.tagName !== "H2") {
        var c = n.querySelector && n.querySelector("pre code");
        if (c) { firstCode = c; break; }
        n = n.nextElementSibling;
      }
    }
    if (firstCode) {
      var cmd = firstCode.textContent.trim();
      var chip = el("div", "hero-chip");
      chip.innerHTML = '<span class="prompt">$</span>';
      var code = el("code");
      code.textContent = cmd;
      chip.appendChild(code);
      chip.appendChild(copyButton(function () { return cmd; }));
      var chipRow = el("div");
      chipRow.appendChild(chip);
      w.appendChild(chipRow);
    }

    var metaText = (document.querySelector("[data-hero-meta]") || {}).getAttribute ? document.querySelector("[data-hero-meta]").getAttribute("data-hero-meta") : "";
    if (metaText) {
      var ul = el("ul", "hero-meta");
      metaText.split("|").forEach(function (m) { ul.appendChild(el("li", null, icon("check") + m)); });
      w.appendChild(ul);
    }
    if (badges) { badges.className = "hero-badges"; w.appendChild(badges); }

    if (shot) {
      var img = shot.querySelector("img");
      var holder = el("div", "hero-shot");
      holder.appendChild(framed(img));
      w.appendChild(holder);
      shot.parentNode && shot.parentNode.removeChild(shot);
    }
    return hero;
  }

  function enhanceInstall(h2, rest) {
    var b = band("install", true, "band-install");
    var lead = rest[0] && rest[0].tagName === "P" ? rest.shift() : null;
    b.wrap.appendChild(sectionHead(h2, "Get started", lead));

    // Split the rest by H3.
    var groups = [];
    rest.forEach(function (n) {
      if (n.tagName === "H3") groups.push({ h3: n, nodes: [] });
      else if (groups.length) groups[groups.length - 1].nodes.push(n);
    });

    var grid = el("div", "install-grid");
    var option = 0;
    groups.forEach(function (g) {
      if (/first launch/i.test(textOf(g.h3))) {
        var card = el("div", "card first-launch reveal");
        var head = el("div", "fl-head");
        g.h3.insertAdjacentHTML("afterbegin", '<span class="card-icon">' + icon("shield") + "</span>");
        head.appendChild(g.h3);
        var nodes = g.nodes.slice();
        if (nodes[0] && nodes[0].tagName === "P") head.appendChild(nodes.shift());
        card.appendChild(head);
        var left = el("div", "fl-steps");
        var right = el("div", "fl-side");
        var toRight = false;
        nodes.forEach(function (n) {
          if (n.tagName === "OL") { n.classList.add("steps"); left.appendChild(n); toRight = true; return; }
          (toRight ? right : left).appendChild(n);
        });
        card.appendChild(left);
        card.appendChild(right);
        b.wrap.appendChild(grid);
        b.wrap.appendChild(card);
        return;
      }
      option += 1;
      var c = el("div", "card install-card reveal");
      c.appendChild(el("p", "step-tag", "<b>" + option + "</b>Option " + option + (option === 1 ? '<span class="pill">Recommended</span>' : "")));
      c.appendChild(g.h3);
      g.nodes.forEach(function (n) {
        if (n.tagName === "OL") n.classList.add("steps");
        c.appendChild(n);
      });
      grid.appendChild(c);
    });
    if (!grid.parentNode) b.wrap.appendChild(grid);
    return b.section;
  }

  function enhanceWhy(h2, rest) {
    var b = band("why", false);
    var lead = rest[0] && rest[0].tagName === "P" ? rest.shift() : null;
    b.wrap.appendChild(sectionHead(h2, "Why Container Deck", lead));
    if (h2.textContent.trim() === "Why Container Deck") h2.textContent = "Built for this Mac, not ported to it";
    rest.forEach(function (n) {
      if (n.tagName === "UL") b.wrap.appendChild(listToCards(n, pickIcon, "cols-3 why-grid"));
      else b.wrap.appendChild(n);
    });
    return b.section;
  }

  function enhanceFeatures(h2, rest) {
    var b = band("features", true);
    b.wrap.appendChild(sectionHead(h2, "Features", el("p", null, "Everything Apple's platform can do, plus the parts it leaves to you: AI, MCP, HTTPS, imports and a real menu bar app.")));
    var groups = [];
    rest.forEach(function (n) {
      if (n.tagName === "H3") groups.push({ h3: n, nodes: [] });
      else if (groups.length) groups[groups.length - 1].nodes.push(n);
      else b.wrap.appendChild(n);
    });
    var flip = false;
    groups.forEach(function (g) {
      var list = null, shotP = null, others = [];
      g.nodes.forEach(function (n) {
        if (n.tagName === "UL" && !list) list = n;
        else if (n.tagName === "P" && n.querySelector("img")) shotP = n;
        else others.push(n);
      });
      var group = el("div", "feature-group reveal");
      var copy = el("div", "feature-copy");
      copy.appendChild(g.h3);
      others.forEach(function (n) { copy.appendChild(n); });
      group.appendChild(copy);
      if (shotP) {
        if (list) {
          list.classList.add("points");
          var titles = list.querySelectorAll("li > strong:first-child");
          for (var t = 0; t < titles.length; t++) titles[t].textContent = titles[t].textContent.replace(/[.:]\s*$/, "");
          copy.appendChild(list);
        }
        var img = shotP.querySelector("img");
        var wide = img.naturalWidth && img.naturalHeight ? img.naturalWidth / img.naturalHeight < 1.45 : /palette/.test(img.src);
        if (wide) group.classList.add("narrow-shot");
        var shot = el("div", "feature-shot");
        shot.appendChild(framed(img));
        group.appendChild(shot);
        if (flip) group.classList.add("flip");
        flip = !flip;
      } else {
        group.classList.add("full");
        if (list) copy.appendChild(listToCards(list, pickIcon, "cols-3"));
      }
      b.wrap.appendChild(group);
    });
    return b.section;
  }

  function enhanceCompare(h2, rest) {
    var b = band("compare", false, "band-compare");
    var lead = rest[0] && rest[0].tagName === "P" ? rest.shift() : null;
    b.wrap.appendChild(sectionHead(h2, "Compare", lead));
    rest.forEach(function (n) {
      var table = n.tagName === "TABLE" ? n : n.querySelector && n.querySelector("table");
      if (table) {
        table.classList.add("compare");
        var heads = table.querySelectorAll("thead th");
        if (heads[1]) heads[1].classList.add("ours");
        var rows = table.querySelectorAll("tbody tr");
        for (var r = 0; r < rows.length; r++) {
          var cells = rows[r].children;
          for (var c = 1; c < cells.length; c++) {
            var td = cells[c];
            if (c === 1) td.classList.add("ours");
            // README cells start with 🟢 / 🟠 / 🔴 (older text: Yes / Partial / No).
            var m = td.innerHTML.trim().match(/^(\uD83D\uDFE2|\uD83D\uDFE0|\uD83D\uDD34|Yes|No|Partial)[,.]?\s*([\s\S]*)$/);
            if (m) {
              var EMOJI = { "\uD83D\uDFE2": "yes", "\uD83D\uDFE0": "partial", "\uD83D\uDD34": "no" };
              var kind = EMOJI[m[1]] || m[1].toLowerCase();
              var label = { yes: "Yes", partial: "Partly", no: "No" }[kind];
              td.innerHTML = '<span class="mark mark-' + kind + '">' + MARKS[kind] + '<span class="sr">' + label + "</span>" +
                (m[2] ? '<span class="note">' + m[2] + "</span>" : "") + "</span>";
            } else {
              td.classList.add("text-value");
            }
          }
        }
        var legend = el("div", "compare-legend",
          '<span class="mark mark-yes">' + MARKS.yes + "Yes</span>" +
          '<span class="mark mark-partial">' + MARKS.partial + "Partly, see note</span>" +
          '<span class="mark mark-no">' + MARKS.no + "No</span>");
        b.wrap.appendChild(legend);
        var card = el("div", "card compare-card reveal");
        var scroll = el("div", "table-scroll");
        scroll.setAttribute("tabindex", "0");
        scroll.setAttribute("aria-label", "Comparison table, scrolls sideways");
        card.appendChild(scroll);
        scroll.appendChild(table);
        b.wrap.appendChild(card);
        if (n !== table && n.parentNode) n.parentNode.removeChild(n);
      } else {
        if (n.tagName === "P" && n.querySelector("sub")) n.classList.add("compare-note");
        if (n.tagName === "P" && /^\s*\uD83D\uDFE2/.test(n.textContent)) n.style.display = "none";
        b.wrap.appendChild(n);
      }
    });
    return b.section;
  }

  function enhanceDocker(h2, rest) {
    var b = band("docker", true, "band-docker");
    var card = el("div", "card docker-card reveal");
    card.appendChild(el("div", "card-icon", icon("terminal")));
    var mid = el("div");
    mid.appendChild(h2);
    var guide = null;
    rest.forEach(function (n) {
      mid.appendChild(n);
      if (!guide && n.querySelector) guide = n.querySelector('a[href*="DOCKER"]');
    });
    card.appendChild(mid);
    if (guide) {
      var btn = el("a", "btn btn-secondary", "Read the guide" + icon("arrow"));
      btn.href = guide.getAttribute("href");
      card.appendChild(btn);
    }
    b.wrap.appendChild(card);
    return b.section;
  }

  function enhanceHow(h2, rest) {
    var b = band("how", false);
    b.wrap.appendChild(sectionHead(h2, "Under the hood", null));
    var bodyEl = el("div", "how-body reveal");
    rest.forEach(function (n) {
      if (n.querySelector && n.querySelector("pre")) {
        bodyEl.appendChild(el("div", "term-bar", "<i></i><i></i><i></i><span>Container Deck</span>"));
      }
      bodyEl.appendChild(n);
    });
    b.wrap.appendChild(bodyEl);
    return b.section;
  }

  function cardFromSection(h2, rest, iconName, extra) {
    var card = el("div", "card reveal" + (extra ? " " + extra : ""));
    if (iconName) h2.insertAdjacentHTML("afterbegin", '<span class="card-icon">' + icon(iconName) + "</span>");
    card.appendChild(h2);
    rest.forEach(function (n) {
      if (n.tagName === "TABLE") n.classList.add("keys-table");
      card.appendChild(n);
    });
    return card;
  }

  // "- **[Title](link).** Text" items become cards that open the guide.
  function enhanceDocs(h2, rest) {
    var b = band("documentation", false);
    var lead = rest[0] && rest[0].tagName === "P" ? rest.shift() : null;
    b.wrap.appendChild(sectionHead(h2, "Docs", lead));
    rest.forEach(function (n) {
      if (n.tagName !== "UL") { b.wrap.appendChild(n); return; }
      var grid = el("div", "card-grid cols-3 docs-grid");
      Array.prototype.slice.call(n.children).forEach(function (li) {
        var link = li.querySelector("strong a") || li.querySelector("a");
        var strong = li.querySelector("strong");
        var title = textOf(strong || link || li).replace(/[.:]$/, "");
        if (strong) strong.parentNode.removeChild(strong);
        var card = el("a", "card reveal doc-card");
        card.href = link ? link.getAttribute("href") : "#";
        card.innerHTML =
          '<div class="card-icon">' + icon("doc") + "</div>" +
          '<span class="card-title">' + title + "</span>" +
          '<p class="card-text">' + li.innerHTML.replace(/^\s*[:.]?\s*/, "") + "</p>" +
          '<span class="doc-card-more">Read the guide</span>';
        grid.appendChild(card);
      });
      b.wrap.appendChild(grid);
    });
    return b.section;
  }

  function enhanceFAQ(h2, rest) {
    var b = band("faq", true);
    b.wrap.appendChild(sectionHead(h2, "FAQ", el("p", null, "Straight answers to the questions people ask first.")));
    var list = el("div", "faq-list reveal");
    var current = null;
    rest.forEach(function (n) {
      if (n.tagName === "H3") {
        current = document.createElement("details");
        if (n.id) current.id = n.id;
        var s = document.createElement("summary");
        s.innerHTML = "<span>" + n.innerHTML + '</span><span class="plus" aria-hidden="true"></span>';
        current.appendChild(s);
        current.appendChild(el("div", "faq-answer"));
        if (!list.children.length) current.open = true;
        list.appendChild(current);
      } else if (current) {
        current.querySelector(".faq-answer").appendChild(n);
      } else {
        b.wrap.appendChild(n);
      }
    });
    b.wrap.appendChild(list);
    return b.section;
  }

  function closingCTA(scope) {
    var hero = scope.querySelector(".hero-actions");
    var box = el("div", "closing reveal");
    box.appendChild(el("p", "closing-title", "Give your containers a proper home."));
    if (hero) box.appendChild(hero.cloneNode(true));
    return box;
  }

  function enhanceHome() {
    var children = Array.prototype.slice.call(article.children);
    var firstH2 = article.querySelector("h2");
    if (!firstH2) return;

    var heroNodes = [];
    for (var i = 0; i < children.length && children[i] !== firstH2; i++) heroNodes.push(children[i]);

    // Group every H2 with what follows it.
    var sections = [];
    children.forEach(function (n) {
      if (n.tagName === "H2") sections.push({ h2: n, id: n.id, nodes: [] });
      else if (sections.length) sections[sections.length - 1].nodes.push(n);
    });

    var out = document.createDocumentFragment();
    out.appendChild(buildHero(heroNodes));

    var project = null;
    var projectGrid = null;
    var pendingSplit = null;
    var readmeFooter = null;

    sections.forEach(function (s) {
      var id = s.id;
      var rest = s.nodes.slice();
      var built = null;
      if (id === "install") built = enhanceInstall(s.h2, rest);
      else if (id === "why-container-deck") built = enhanceWhy(s.h2, rest);
      else if (id === "features") built = enhanceFeatures(s.h2, rest);
      else if (id === "container-deck-vs-davit-vs-orchard") built = enhanceCompare(s.h2, rest);
      else if (id === "use-docker-commands") built = enhanceDocker(s.h2, rest);
      else if (id === "how-it-works") built = enhanceHow(s.h2, rest);
      else if (id === "keyboard" || id === "privacy") {
        if (!pendingSplit) {
          var b = band("keyboard", true, "band-split");
          pendingSplit = el("div", "split");
          b.wrap.appendChild(pendingSplit);
          built = b.section;
        }
        if (id === "keyboard") {
          var kicker = el("p", "kicker", "Keep your hands on the keys.");
          var kc = cardFromSection(s.h2, rest, null, "keys-card");
          kc.insertBefore(kicker, kc.children[1]);
          pendingSplit.appendChild(kc);
        } else {
          var pc = cardFromSection(s.h2, rest, "lock", "privacy-card");
          // Lift the first sentence into a statement.
          var firstP = pc.querySelector("p");
          if (firstP) {
            var m = firstP.innerHTML.match(/^([^.]+\.)\s+([\s\S]*)$/);
            if (m) {
              var statement = el("p", "privacy-statement", m[1]);
              firstP.innerHTML = m[2];
              pc.insertBefore(statement, firstP);
            }
          }
          pendingSplit.appendChild(pc);
        }
      }
      else if (id === "faq") built = enhanceFAQ(s.h2, rest);
      else if (id === "documentation") built = enhanceDocs(s.h2, rest);
      else if (id === "contributing" || id === "security" || id === "license" || id === "acknowledgements") {
        if (!project) {
          var pb = band("project", false, "band-project");
          pb.wrap.appendChild(sectionHead(el("h2", null, "Free to use, open to read"), "Project", el("p", null, "How to help, how to report a problem, and what the license allows.")));
          projectGrid = el("div", "project-grid");
          pb.wrap.appendChild(projectGrid);
          project = pb;
          built = pb.section;
        }
        // The last centered paragraph is the README footer. The site footer covers it.
        var last = rest[rest.length - 1];
        if (id === "acknowledgements" && last && last.tagName === "P" && last.getAttribute("align") === "center") {
          readmeFooter = rest.pop();
        }
        var icons = { contributing: "users", security: "shield", license: "doc", acknowledgements: "heart" };
        projectGrid.appendChild(cardFromSection(s.h2, rest, icons[id]));
      } else {
        // Anything new in the README still shows up, as a plain section.
        var g = band(id, false);
        g.wrap.appendChild(sectionHead(s.h2, null, null));
        rest.forEach(function (n) { g.wrap.appendChild(n); });
        built = g.section;
      }
      if (built) out.appendChild(built);
    });

    if (project) project.wrap.appendChild(closingCTA(out));
    if (readmeFooter) { readmeFooter.className = "readme-footer"; out.appendChild(readmeFooter); }

    // Alternate the bands after grouping, so the rhythm stays even if sections move.
    var bands = out.querySelectorAll(".band");
    for (var k = 0; k < bands.length; k++) bands[k].classList.toggle("alt", k % 2 === 0);

    article.innerHTML = "";
    article.appendChild(out);
    body.classList.add("enhanced");
  }

  /* ---------- Active nav, reveal ---------- */

  function initActiveNav() {
    var links = document.querySelectorAll(".site-nav a[data-section]");
    if (!links.length || !("IntersectionObserver" in window)) return;
    var map = {};
    var targets = [];
    for (var i = 0; i < links.length; i++) {
      var id = links[i].getAttribute("data-section");
      var target = document.getElementById(id);
      if (!target) continue;
      var sec = target.closest(".band") || target;
      map[id] = links[i];
      sec.setAttribute("data-nav", id);
      targets.push(sec);
    }
    var visible = {};
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { visible[e.target.getAttribute("data-nav")] = e.isIntersecting; });
      var current = null;
      targets.forEach(function (t) { var id = t.getAttribute("data-nav"); if (visible[id] && !current) current = id; });
      for (var key in map) map[key].classList.toggle("active", key === current);
    }, { rootMargin: "-45% 0px -50% 0px" });
    targets.forEach(function (t) { io.observe(t); });
  }

  function initReveal() {
    var items = document.querySelectorAll(".reveal");
    if (!("IntersectionObserver" in window) || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      for (var i = 0; i < items.length; i++) items[i].classList.add("in");
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { rootMargin: "0px 0px -6% 0px", threshold: 0.06 });
    for (var j = 0; j < items.length; j++) io.observe(items[j]);
  }

  function openHashTarget() {
    if (!location.hash) return;
    var t = document.getElementById(decodeURIComponent(location.hash.slice(1)));
    if (t && t.tagName === "DETAILS") { t.open = true; t.scrollIntoView(); }
  }

  /* ---------- Start ---------- */

  initTheme();
  initHeader();
  if (article) {
    fixMarkdownLinks();
    initCodeBlocks();
    if (body.classList.contains("page-home")) {
      var backup = article.innerHTML;
      try { enhanceHome(); } catch (err) {
        // If anything goes wrong the plain README stays on screen.
        article.innerHTML = backup;
        body.classList.remove("enhanced");
        if (window.console) console.error(err);
      }
      syncPictures(savedChoice());
      initActiveNav();
      openHashTarget();
      window.addEventListener("hashchange", openHashTarget);
    }
    initLightbox();
    initReveal();
  }
})();
