// chat.js — v0 boring-ui chat client (ARD-0022 §4).
// Vanilla JS. Subscribes to the SSE event stream, renders cards as they
// arrive, posts user messages and saves through fetch().

(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);

  const thread = $("thread");
  const composer = $("composer");
  const input = $("input");
  const saveBtn = $("save-btn");
  const saveDialog = $("save-dialog");
  const saveForm = $("save-form");
  const saveTitle = $("save-title");
  const saveDesc = $("save-description");
  const saveBranch = $("save-branch");
  const saveReviewers = $("save-reviewers");
  const saveDraft = $("save-draft");
  const saveCancel = $("save-cancel");
  const toast = $("toast");

  // --- Rendering ---------------------------------------------------------

  function el(tag, props = {}, children = []) {
    const e = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (k === "className") e.className = v;
      else if (k === "html") e.innerHTML = v;
      else if (k === "text") e.textContent = v;
      else if (k.startsWith("on") && typeof v === "function") {
        e.addEventListener(k.slice(2).toLowerCase(), v);
      } else if (v !== undefined && v !== null) {
        e.setAttribute(k, v);
      }
    }
    for (const c of children) {
      if (c) e.appendChild(typeof c === "string" ? document.createTextNode(c) : c);
    }
    return e;
  }

  function scrollToBottom() {
    thread.scrollTop = thread.scrollHeight;
  }

  function renderUserMessage(data) {
    const c = el("div", { className: "card user" }, [
      el("div", { className: "summary", text: data.text || "" }),
    ]);
    thread.appendChild(c);
    scrollToBottom();
  }

  let currentThinking = null;
  function renderThinking() {
    if (currentThinking) return;
    currentThinking = el("div", { className: "card thinking" }, [
      el("div", { className: "summary" }, [
        document.createTextNode("AI is thinking"),
        el("span", { className: "dots" }),
      ]),
    ]);
    thread.appendChild(currentThinking);
    scrollToBottom();
  }
  function clearThinking() {
    if (currentThinking && currentThinking.parentNode) {
      currentThinking.parentNode.removeChild(currentThinking);
    }
    currentThinking = null;
  }

  const TOOL_ICONS = {
    file_edit: "✎",
    shell: "$",
    network: "⚡",
    db: "🗄",
    undo: "↩",
  };

  const pendingTools = {}; // tool name -> card el (last unfilled)

  function renderToolCall(data) {
    const icon = TOOL_ICONS[data.tool] || "•";
    const argsStr = data.args ? JSON.stringify(data.args) : "";
    const card = el("div", { className: "card tool" }, [
      el("div", { className: "meta" }, [
        el("span", { className: "icon", text: icon }),
        document.createTextNode(data.tool || "tool"),
      ]),
      el("div", { className: "summary", text: argsStr }),
    ]);
    pendingTools[data.tool] = card;
    thread.appendChild(card);
    scrollToBottom();
  }

  function renderToolResult(data) {
    const card = pendingTools[data.tool];
    if (card) {
      delete pendingTools[data.tool];
      const summary = card.querySelector(".summary");
      if (summary) summary.textContent = data.result_summary || "(no summary)";
      if (data.diff) {
        const det = el("details", {}, [
          el("summary", { text: "show diff" }),
          el("pre", { text: data.diff }),
        ]);
        card.appendChild(det);
      }
    } else {
      // Result arrived without a prior call card (e.g. stub undo). Render fresh.
      const icon = TOOL_ICONS[data.tool] || "•";
      const fresh = el("div", { className: "card tool" }, [
        el("div", { className: "meta" }, [
          el("span", { className: "icon", text: icon }),
          document.createTextNode(data.tool || "tool"),
        ]),
        el("div", { className: "summary", text: data.result_summary || "" }),
      ]);
      if (data.diff) {
        fresh.appendChild(el("details", {}, [
          el("summary", { text: "show diff" }),
          el("pre", { text: data.diff }),
        ]));
      }
      thread.appendChild(fresh);
    }
    scrollToBottom();
  }

  function renderSaveCard(kind, data) {
    let body;
    if (kind === "started") {
      body = el("div", { className: "summary", text: "Saving..." });
    } else if (kind === "succeeded") {
      const link = el("a", {
        href: data.pr_url || "#",
        target: "_blank",
        rel: "noopener",
        text: data.pr_url || "(no URL)",
      });
      body = el("div", { className: "summary" }, [
        document.createTextNode("Saved as PR: "),
        link,
        document.createTextNode(" (branch: " + (data.branch_name || "?") + ")"),
      ]);
    } else {
      body = el("div", { className: "summary", text: "Save failed: " + (data.error || "(unknown)") });
    }
    const cls = kind === "failed" ? "card error" : "card save";
    const card = el("div", { className: cls }, [
      el("div", { className: "meta" }, [
        el("span", { className: "icon", text: kind === "failed" ? "⚠" : "📤" }),
        document.createTextNode(kind === "started" ? "save started" : "save " + kind),
      ]),
      body,
    ]);
    thread.appendChild(card);
    scrollToBottom();
  }

  function dispatchEnvelope(type, data) {
    switch (type) {
      case "user_message":
        renderUserMessage(data);
        break;
      case "ai_thinking":
        renderThinking();
        break;
      case "tool_call":
        clearThinking();
        renderToolCall(data);
        break;
      case "tool_result":
        renderToolResult(data);
        break;
      case "turn_complete":
        clearThinking();
        composer.classList.remove("busy");
        break;
      case "save_started":
        renderSaveCard("started", data);
        setComposerBusy(true);
        break;
      case "save_succeeded":
        renderSaveCard("succeeded", data);
        setComposerBusy(false);
        showToast("Saved.", false);
        break;
      case "save_failed":
        renderSaveCard("failed", data);
        setComposerBusy(false);
        showToast("Save failed: " + (data.error || "unknown"), true);
        break;
      case "lock_status":
        // v0: not surfaced visually beyond the toast.
        break;
      default:
        // Unknown event type — log + ignore so future additions don't break.
        console.warn("unknown event:", type, data);
    }
  }

  function setComposerBusy(busy) {
    input.disabled = busy;
    saveBtn.disabled = busy;
    composer.querySelector("button[type=submit]").disabled = busy;
  }

  function showToast(msg, isError) {
    toast.textContent = msg;
    toast.classList.toggle("error", !!isError);
    toast.hidden = false;
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => { toast.hidden = true; }, 4000);
  }

  // --- Network -----------------------------------------------------------

  // Hydrate from /api/thread, then attach SSE so we don't double-render the
  // events that arrive on the live stream between hydration and connection.
  async function hydrate() {
    try {
      const r = await fetch("api/thread");
      if (!r.ok) return;
      const body = await r.json();
      const events = body.events || [];
      for (const env of events) {
        dispatchEnvelope(env.type, env.data || {});
      }
    } catch (e) {
      console.warn("hydrate failed", e);
    }
  }

  function attachSSE() {
    const es = new EventSource("api/events");
    const types = [
      "user_message", "ai_thinking", "tool_call", "tool_result",
      "turn_complete", "lock_status",
      "save_started", "save_succeeded", "save_failed",
    ];
    for (const t of types) {
      es.addEventListener(t, (e) => {
        let data = {};
        try { data = JSON.parse(e.data); } catch (_) { /* ignore */ }
        dispatchEnvelope(t, data);
      });
    }
    es.onerror = () => {
      // EventSource auto-reconnects. v0: just log.
      console.warn("SSE error; browser will reconnect");
    };
  }

  composer.addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    input.value = "";
    composer.classList.add("busy");
    try {
      const r = await fetch("api/messages", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
      });
      if (!r.ok) showToast("Send failed: " + r.status, true);
    } catch (err) {
      showToast("Send failed: " + err, true);
    }
  });

  // --- Save dialog -------------------------------------------------------

  saveBtn.addEventListener("click", async () => {
    // Pre-fill from server-side summary.
    try {
      const r = await fetch("api/save/preview");
      if (r.ok) {
        const body = await r.json();
        saveTitle.value = body.title || "";
        saveDesc.value = body.description || "";
      }
    } catch (_) { /* ignore — leave fields blank */ }

    // Pre-fill branch name from title (kebab-case).
    const slug = (saveTitle.value || "untitled")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 40) || "untitled";
    saveBranch.value = "marketer/" + slug + "-" + Date.now().toString(36);
    saveReviewers.value = "";
    saveDraft.checked = true;

    if (typeof saveDialog.showModal === "function") {
      saveDialog.showModal();
    } else {
      saveDialog.setAttribute("open", "");
    }
  });

  saveCancel.addEventListener("click", () => {
    if (typeof saveDialog.close === "function") saveDialog.close();
    else saveDialog.removeAttribute("open");
  });

  saveForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const reviewers = saveReviewers.value
      .split(",").map((s) => s.trim()).filter(Boolean);
    const body = {
      title: saveTitle.value,
      description: saveDesc.value,
      draft: !!saveDraft.checked,
      reviewers,
    };
    if (typeof saveDialog.close === "function") saveDialog.close();
    else saveDialog.removeAttribute("open");

    try {
      const r = await fetch("api/save", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!r.ok) showToast("Save failed: " + r.status, true);
    } catch (err) {
      showToast("Save failed: " + err, true);
    }
  });

  // --- Boot --------------------------------------------------------------

  (async () => {
    await hydrate();
    attachSSE();
  })();
})();
