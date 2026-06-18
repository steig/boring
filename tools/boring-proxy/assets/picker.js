// picker.js — vanilla, no framework. The cockpit shell (ARD-0041): a "mission
// control" dashboard plus a tab bar that opens each project in its own
// same-origin iframe. The dashboard is the home/empty state; clicking a card
// opens (or focuses) that project's tab. Open tabs + the active tab persist in
// localStorage so a refresh restores the workspace.
//
// One tab == one project's existing single chat (served from /<slug>/ through
// the proxy). Multiple threads per project and new-project creation are out of
// scope here (separate slices).

(function () {
  "use strict";

  // SW registration lives here (not an inline <script>) so the strict
  // proxy-owned CSP (script-src 'self') doesn't block it.
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/assets/sw.js").catch(() => {});
  }

  const KNOWN_STATUSES = ["running", "starting", "stopped", "error"];
  const REFRESH_MS = 4000;
  const STORE_KEY = "boring.cockpit.tabs.v1";

  // openTabs: ordered [{slug, name}]. active: slug, or "" for the home view.
  let openTabs = [];
  let active = "";
  // Latest /api/projects snapshot, by slug — feeds tab status dots + add menu.
  let projectsBySlug = {};

  function el(tag, attrs, ...children) {
    const e = document.createElement(tag);
    if (attrs) {
      for (const k in attrs) {
        if (k === "class") e.className = attrs[k];
        else if (k === "onclick") e.addEventListener("click", attrs[k]);
        else e.setAttribute(k, attrs[k]);
      }
    }
    for (const c of children) {
      if (c == null) continue;
      e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return e;
  }

  function statusOf(status) {
    return KNOWN_STATUSES.includes(status) ? status : "stopped";
  }

  function statusBadge(status) {
    const s = statusOf(status);
    return el("span", { class: "badge " + s }, el("span", { class: "dot" }), s);
  }

  // Compact relative time ("3m ago", "2h ago"); null when unparseable.
  function relTime(iso) {
    if (!iso) return null;
    const t = Date.parse(iso);
    if (isNaN(t)) return null;
    const secs = Math.max(0, Math.floor((Date.now() - t) / 1000));
    if (secs < 60) return "just now";
    const mins = Math.floor(secs / 60);
    if (mins < 60) return mins + "m ago";
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return hrs + "h ago";
    return Math.floor(hrs / 24) + "d ago";
  }

  // ----- tab persistence -----------------------------------------------------

  function persist() {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify({ tabs: openTabs, active: active }));
    } catch (_) {
      // Private mode / quota — non-fatal; the workspace just won't restore.
    }
  }

  function restore() {
    try {
      const raw = localStorage.getItem(STORE_KEY);
      if (!raw) return;
      const saved = JSON.parse(raw);
      if (Array.isArray(saved.tabs)) {
        openTabs = saved.tabs.filter((t) => t && typeof t.slug === "string");
      }
      if (typeof saved.active === "string") active = saved.active;
    } catch (_) {
      openTabs = [];
      active = "";
    }
    if (active && !openTabs.some((t) => t.slug === active)) active = "";
  }

  // ----- tab open / close / focus -------------------------------------------

  function openTab(slug, name) {
    if (!openTabs.some((t) => t.slug === slug)) {
      openTabs.push({ slug: slug, name: name || slug });
    }
    focusTab(slug);
  }

  function focusTab(slug) {
    active = slug;
    persist();
    syncViews();
    renderTabs();
  }

  function focusHome() {
    active = "";
    persist();
    syncViews();
    renderTabs();
  }

  function closeTab(slug) {
    const idx = openTabs.findIndex((t) => t.slug === slug);
    if (idx < 0) return;
    openTabs.splice(idx, 1);
    const frame = document.getElementById("frame-" + slug);
    if (frame) frame.remove();
    if (active === slug) {
      const next = openTabs[idx] || openTabs[idx - 1];
      active = next ? next.slug : "";
    }
    persist();
    syncViews();
    renderTabs();
  }

  // reconcileTabs drops tabs whose project is gone from the live registry
  // (e.g. a project deregistered since a refresh restored it) and refreshes
  // names from the snapshot. Called after a successful /api/projects load.
  function reconcileTabs() {
    let changed = false;
    for (let i = openTabs.length - 1; i >= 0; i--) {
      const p = projectsBySlug[openTabs[i].slug];
      if (!p) {
        closeTab(openTabs[i].slug);
        changed = true;
      } else if (p.name && p.name !== openTabs[i].name) {
        openTabs[i].name = p.name;
        changed = true;
      }
    }
    if (changed) persist();
  }

  // syncViews shows either the home dashboard or the active tab. Every open
  // tab keeps its own iframe alive (hidden when inactive) so switching is
  // instant and a backgrounded chat retains its connection and scroll state.
  function syncViews() {
    document.getElementById("home-view").hidden = active !== "";
    const views = document.getElementById("tab-views");
    views.hidden = active === "";

    for (const t of openTabs) {
      let frame = document.getElementById("frame-" + t.slug);
      if (!frame) {
        frame = el("iframe", {
          id: "frame-" + t.slug,
          class: "tab-frame",
          src: "/" + t.slug + "/",
          title: t.name,
        });
        views.appendChild(frame);
      }
      frame.hidden = t.slug !== active;
    }
  }

  // ----- tab bar rendering ---------------------------------------------------

  function renderTabs() {
    document.getElementById("home-tab").classList.toggle("active", active === "");

    const bar = document.getElementById("tabs");
    bar.innerHTML = "";
    for (const t of openTabs) {
      const live = projectsBySlug[t.slug];
      const status = statusOf(live ? live.status : "stopped");
      bar.appendChild(
        el(
          "div",
          { class: "tab" + (t.slug === active ? " active" : ""), onclick: () => focusTab(t.slug) },
          el("span", { class: "tab-dot " + status, title: status }),
          el("span", { class: "tab-name" }, t.name || t.slug),
          el(
            "span",
            {
              class: "tab-close",
              title: "Close",
              onclick: (e) => {
                e.stopPropagation();
                closeTab(t.slug);
              },
            },
            "×"
          )
        )
      );
    }
  }

  // ----- add-a-tab menu ------------------------------------------------------

  function toggleAddMenu() {
    const menu = document.getElementById("add-menu");
    if (!menu.hidden) {
      menu.hidden = true;
      return;
    }
    const available = Object.values(projectsBySlug)
      .filter((p) => !openTabs.some((t) => t.slug === p.slug))
      .sort((a, b) => (a.name || a.slug).localeCompare(b.name || b.slug));

    menu.innerHTML = "";
    if (!available.length) {
      menu.appendChild(el("div", { class: "add-empty" }, "All projects are open."));
    } else {
      for (const p of available) {
        menu.appendChild(
          el(
            "button",
            {
              class: "add-item",
              onclick: () => {
                document.getElementById("add-menu").hidden = true;
                openTab(p.slug, p.name);
              },
            },
            el("span", { class: "tab-dot " + statusOf(p.status) }),
            el("span", { class: "add-item-name" }, p.name || p.slug)
          )
        );
      }
    }
    menu.hidden = false;
  }

  // ----- dashboard grid ------------------------------------------------------

  function renderCard(project) {
    const last = relTime(project.last_active);
    return el(
      "div",
      {
        class: "card status-" + statusOf(project.status),
        onclick: () => openTab(project.slug, project.name),
      },
      el("div", { class: "card-top" },
        el("div", { class: "name" }, project.name || project.slug),
        statusBadge(project.status)
      ),
      el("div", { class: "summary" }, project.summary || "No active session"),
      el("div", { class: "meta" },
        el("span", { class: "slug" }, project.slug),
        last ? el("span", { class: "last" }, last) : null
      )
    );
  }

  function renderAddCard() {
    // TODO(boring-ui): wire to the "add a project" wizard (ARD-0021 §7).
    return el(
      "div",
      { class: "card add", onclick: () => alert("Add-project wizard: not yet implemented.") },
      el("span", { class: "plus" }, "+"),
      "Add a project"
    );
  }

  function renderCounts(projects) {
    const counts = document.getElementById("counts");
    counts.innerHTML = "";
    if (!projects.length) return;
    const running = projects.filter((p) => statusOf(p.status) === "running").length;
    counts.appendChild(el("span", { class: "count running" }, running + " running"));
    counts.appendChild(el("span", { class: "count" }, projects.length + " total"));
  }

  function setConn(ok) {
    const c = document.getElementById("conn");
    c.textContent = ok ? "live" : "offline";
    c.className = "conn" + (ok ? "" : " off");
  }

  function showError(msg) {
    const e = document.getElementById("error");
    e.textContent = msg;
    e.hidden = false;
  }
  function clearError() {
    document.getElementById("error").hidden = true;
  }

  function renderGrid(projects) {
    const grid = document.getElementById("projects");
    grid.innerHTML = "";
    if (!projects || projects.length === 0) {
      grid.appendChild(
        el("div", { class: "empty" }, "No projects yet. Run `boring open <path>` to register one.")
      );
      grid.appendChild(renderAddCard());
      renderCounts([]);
      return;
    }
    projects.sort((a, b) => (a.name || a.slug).localeCompare(b.name || b.slug));
    for (const p of projects) grid.appendChild(renderCard(p));
    grid.appendChild(renderAddCard());
    renderCounts(projects);
  }

  // ----- poll ----------------------------------------------------------------

  function load() {
    fetch("/api/projects", { credentials: "same-origin" })
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then((data) => {
        setConn(true);
        clearError();
        const projects = data.projects || [];
        projectsBySlug = {};
        for (const p of projects) projectsBySlug[p.slug] = p;
        renderGrid(projects);
        reconcileTabs();
        renderTabs();
      })
      .catch((err) => {
        setConn(false);
        showError("Failed to load projects: " + err.message);
      });
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.getElementById("home-tab").addEventListener("click", focusHome);
    document.getElementById("add-tab").addEventListener("click", (e) => {
      e.stopPropagation();
      toggleAddMenu();
    });
    document.addEventListener("click", () => {
      document.getElementById("add-menu").hidden = true;
    });

    restore();
    syncViews();
    renderTabs();
    load();
    setInterval(load, REFRESH_MS);
  });
})();
