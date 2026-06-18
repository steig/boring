// picker.js — vanilla, no framework. Polls /api/projects and renders a live
// "mission control" grid of project cards. Kept intentionally small; the
// cockpit's multi-agent streaming panes (ARD-0041) land in a later slice.
//
// Each card shows name, live status (resolved server-side from socket
// reachability), summary, and last-activity, and links into the project's
// per-project route. Statuses auto-refresh on an interval.

(function () {
  "use strict";

  const KNOWN_STATUSES = ["running", "starting", "stopped", "error"];
  const REFRESH_MS = 4000;

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

  function renderCard(project) {
    const last = relTime(project.last_active);
    return el(
      "a",
      {
        class: "card status-" + statusOf(project.status),
        href: project.url || "/" + project.slug + "/",
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

  function render(projects) {
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

  function load() {
    fetch("/api/projects", { credentials: "same-origin" })
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then((data) => {
        setConn(true);
        clearError();
        render(data.projects || []);
      })
      .catch((err) => {
        setConn(false);
        showError("Failed to load projects: " + err.message);
      });
  }

  document.addEventListener("DOMContentLoaded", () => {
    load();
    setInterval(load, REFRESH_MS);
  });
})();
