// picker.js — vanilla, no framework. Fetches /api/projects, renders cards.
// Kept intentionally tiny (~80 lines); the picker is read-only in v0.
//
// ARD-0021 §3: each card carries name, status badge, current-session summary,
// presence indicator. v0 ships name + status + summary; presence TODO.

(function () {
  "use strict";

  const KNOWN_STATUSES = ["running", "starting", "stopped", "error"];

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

  function statusBadge(status) {
    const cls = KNOWN_STATUSES.includes(status) ? status : "stopped";
    return el("span", { class: "badge " + cls }, status || "stopped");
  }

  function renderCard(project) {
    return el(
      "div",
      {
        class: "card",
        onclick: () => {
          // v0: navigate to /<slug>/. If the container isn't up, the proxy
          // renders a stub page. Real launch flow is TODO.
          window.location.href = "/" + project.slug + "/";
        },
      },
      el("div", { class: "name" }, project.name || project.slug, statusBadge(project.status)),
      el("div", { class: "summary" }, project.summary || "—")
    );
  }

  function renderAddCard() {
    // TODO(boring-ui): wire to the "add a project" wizard (ARD-0021 §7).
    return el(
      "div",
      { class: "card add", onclick: () => alert("Add-project wizard: not yet implemented.") },
      "+ Add a project"
    );
  }

  function showError(msg) {
    const e = document.getElementById("error");
    e.textContent = msg;
    e.hidden = false;
  }

  function render(projects) {
    const grid = document.getElementById("projects");
    grid.innerHTML = "";
    if (!projects || projects.length === 0) {
      grid.appendChild(
        el("div", { class: "empty" }, "No projects yet. Run `boring open <path>` to register one.")
      );
      grid.appendChild(renderAddCard());
      return;
    }
    projects.sort((a, b) => (a.name || a.slug).localeCompare(b.name || b.slug));
    for (const p of projects) grid.appendChild(renderCard(p));
    grid.appendChild(renderAddCard());
  }

  function load() {
    fetch("/api/projects", { credentials: "same-origin" })
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then((data) => render(data.projects || []))
      .catch((err) => showError("Failed to load projects: " + err.message));
  }

  document.addEventListener("DOMContentLoaded", load);
})();
