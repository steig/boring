// chat.js — v0 boring-ui chat client (ARD-0022 §4).
// Vanilla JS. Subscribes to the SSE event stream, renders cards as they
// arrive, posts user messages and saves through fetch().

(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);

  const thread = $("thread");
  const composer = $("composer");
  const input = $("input");
  // When --terminal-url is set, renderIndex (server.go) substitutes the
  // LEFT_PANE template with an iframe ONLY — there's no #thread, #composer,
  // or #input. The chat-pane-specific bindings below short-circuit on this
  // flag so they don't throw `Cannot read properties of null`. Save dialog,
  // toast, and preview-header bindings stay attached because they live
  // OUTSIDE LEFT_PANE in the HTML and make sense in both modes.
  const hasChatPane = !!thread && !!composer && !!input;
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
    if (!thread) return;
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

  // renderAIText renders one prose reply from the AI (a single text content
  // block in the assistant message). One turn may emit multiple of these.
  function renderAIText(data) {
    const card = el("div", { className: "card ai" }, [
      el("div", { className: "summary", text: data.text || "" }),
    ]);
    thread.appendChild(card);
    scrollToBottom();
  }

  // --- Tool-call rendering ----------------------------------------------
  //
  // Each tool call renders as a <details> element so the one-line summary
  // is visible by default and clicking expands the raw JSON + tool result
  // for debugging. We KEEP cards visible (transparency about what the AI
  // is doing) but render them subdued — see .card.tool styles in chat.css.
  //
  // Renderers are keyed by tool name. Each returns a DocumentFragment-like
  // node sequence built via el(). Unknown tools fall through to a generic
  // renderer so future additions degrade rather than disappear.

  function truncate(s, n) {
    s = String(s == null ? "" : s);
    return s.length > n ? s.slice(0, n) + "…" : s;
  }

  // makeCode wraps text in a monospaced <code> span for tool summaries.
  function makeCode(text) {
    return el("code", { className: "tool-arg", text: text });
  }

  // Type-aware renderers return the inline content node sequence for the
  // <summary>. They never return null — empty args fall back to "(no args)"
  // so the card still reads.
  const TOOL_RENDERERS = {
    Bash: (args) => {
      const cmd = (args && args.command) || "";
      return [
        el("span", { className: "tool-prefix", text: "> " }),
        makeCode(truncate(cmd, 100) || "(empty)"),
      ];
    },
    Edit: (args) => {
      const path = (args && args.file_path) || "(no path)";
      const oldLen = args && typeof args.old_string === "string" ? args.old_string.length : null;
      const newLen = args && typeof args.new_string === "string" ? args.new_string.length : null;
      const nodes = [
        el("span", { className: "tool-prefix", text: "✎ " }),
        makeCode(path),
      ];
      if (oldLen != null && newLen != null) {
        nodes.push(el("span", { className: "tool-meta-inline", text: ` (${oldLen}→${newLen} chars)` }));
      }
      return nodes;
    },
    Read: (args) => {
      const path = (args && args.file_path) || "(no path)";
      const nodes = [
        el("span", { className: "tool-prefix", text: "👁 " }),
        makeCode(path),
      ];
      if (args && (args.offset != null || args.limit != null)) {
        const off = args.offset || 0;
        const lim = args.limit || 0;
        const end = lim ? off + lim : "EOF";
        nodes.push(el("span", { className: "tool-meta-inline", text: ` (lines ${off}-${end})` }));
      }
      return nodes;
    },
    Write: (args) => {
      const path = (args && args.file_path) || "(no path)";
      return [
        el("span", { className: "tool-prefix", text: "🆕 " }),
        makeCode(path),
      ];
    },
    Glob: (args) => {
      const pat = (args && args.pattern) || "";
      return [
        el("span", { className: "tool-prefix", text: "🔍 " }),
        makeCode(pat || "(no pattern)"),
      ];
    },
    Grep: (args) => {
      const pat = (args && args.pattern) || "";
      const path = args && args.path;
      const nodes = [
        el("span", { className: "tool-prefix", text: "🔍 " }),
        makeCode('"' + pat + '"'),
      ];
      if (path) {
        nodes.push(el("span", { className: "tool-meta-inline", text: " in " }));
        nodes.push(makeCode(path));
      }
      return nodes;
    },
    WebFetch: (args) => {
      const url = (args && args.url) || "";
      return [
        el("span", { className: "tool-prefix", text: "🌐 " }),
        makeCode(truncate(url, 100) || "(no url)"),
      ];
    },
    WebSearch: (args) => {
      const q = (args && args.query) || "";
      return [
        el("span", { className: "tool-prefix", text: "🌐 " }),
        makeCode('"' + truncate(q, 80) + '"'),
      ];
    },
  };

  // genericRenderer is the fallback for any tool we don't have a specific
  // renderer for (orchestration tools, MCP tools, future built-ins).
  // Defense in depth: even if Part A's allowlist somehow misses a tool,
  // it still shows up here rather than rendering as raw JSON.
  function genericRenderer(toolName, args) {
    let argStr = "";
    try { argStr = JSON.stringify(args || {}); } catch (_) { argStr = "(unparsable args)"; }
    return [
      el("span", { className: "tool-prefix", text: (toolName || "tool") + ": " }),
      makeCode(truncate(argStr, 80)),
    ];
  }

  // pendingTools maps tool_use id (best-effort, by name in v0 since the
  // envelope doesn't carry the id) to the open <details> card so we can
  // attach the result inline when it arrives.
  const pendingTools = {};

  function renderToolCall(data) {
    const toolName = data.tool || "tool";
    const args = data.args || {};
    const renderer = TOOL_RENDERERS[toolName];
    const summaryNodes = renderer ? renderer(args) : genericRenderer(toolName, args);

    // <details> gives us zero-JS expand/collapse. The summary is the
    // always-visible one-liner; the body is the raw JSON for debugging.
    const detailsEl = el("details", { className: "card tool" }, [
      el("summary", { className: "tool-summary" }, summaryNodes),
      el("div", { className: "tool-body" }, [
        el("div", { className: "tool-body-label", text: "arguments" }),
        el("pre", { className: "tool-json", text: JSON.stringify(args, null, 2) }),
        // tool_result will be appended here when it arrives.
      ]),
    ]);
    pendingTools[toolName] = detailsEl;
    thread.appendChild(detailsEl);
    scrollToBottom();
  }

  function renderToolResult(data) {
    const toolName = data.tool || "tool";
    const summary = data.result_summary || "(no output)";
    const isError = summary.startsWith("error:") || summary.startsWith("✗");
    const firstLine = summary.split("\n")[0];
    const tag = isError ? "✗ " : "✓ ";
    const truncated = truncate(firstLine, 120);

    // The inline result line that sits under the summary, visible without
    // expanding (so the user knows the tool finished + briefly how).
    const resultLine = el("div", {
      className: "tool-result-line" + (isError ? " err" : ""),
      text: tag + truncated,
    });

    const card = pendingTools[toolName];
    if (card) {
      delete pendingTools[toolName];
      // Insert the one-line result inside the <summary> so it shows when
      // the card is collapsed. summaryEl is the <summary> element.
      const summaryEl = card.querySelector("summary.tool-summary");
      if (summaryEl) summaryEl.appendChild(resultLine);

      // Also stash the full output in the expanded body for debugging.
      const body = card.querySelector(".tool-body");
      if (body) {
        body.appendChild(el("div", { className: "tool-body-label", text: "output" }));
        body.appendChild(el("pre", { className: "tool-output", text: summary }));
        if (data.diff) {
          body.appendChild(el("div", { className: "tool-body-label", text: "diff" }));
          body.appendChild(el("pre", { className: "tool-output", text: data.diff }));
        }
      }
    } else {
      // Result arrived without a prior call card (stub undo, race). Render
      // a standalone card so the event isn't dropped.
      const fresh = el("details", { className: "card tool orphan" }, [
        el("summary", { className: "tool-summary" }, [
          el("span", { className: "tool-prefix", text: toolName + ": " }),
          resultLine,
        ]),
        el("div", { className: "tool-body" }, [
          el("div", { className: "tool-body-label", text: "output" }),
          el("pre", { className: "tool-output", text: summary }),
        ]),
      ]);
      thread.appendChild(fresh);
    }
    scrollToBottom();
  }

  // renderPolicyBlocked renders the red-bordered card for reverted
  // out-of-allowlist file writes (ARD-0029 §6 gap #1 backstop). The card is
  // collapsible — the summary shows the file + reason at a glance; expanding
  // shows the full team-facing explanation. Cards are stylistically similar
  // to tool cards (same weight, <details> shape) but with a distinct red/
  // orange accent so the user can see at a glance "the system blocked
  // something" without alarming them.
  function renderPolicyBlocked(data) {
    const path = (data && data.path) || "(unknown path)";
    const reason = (data && data.reason) || "outside your team's allowed paths";
    const card = el("details", { className: "card policy-blocked" }, [
      el("summary", { className: "policy-summary" }, [
        el("span", { className: "policy-icon", text: "🚫" }),
        el("code", { className: "policy-path", text: path }),
        el("span", { className: "policy-reason", text: reason + " — reverted" }),
      ]),
      el("div", { className: "policy-body" }, [
        document.createTextNode(
          "Your team has restricted edits to specific paths. " +
          "The change to this file was automatically reverted. " +
          "To allow edits here, ask an engineer to update the project's allowed_paths."
        ),
      ]),
    ]);
    thread.appendChild(card);
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

  // --- Cost tracking -----------------------------------------------------
  //
  // Session running total of cost_usd + turn count, updated on every
  // turn_complete event (whether from SSE or hydration). The header badge
  // re-renders on each update so refreshing the page restores the total.

  const session = { costUSD: 0, turns: 0 };
  const sessionBadge = $("session-cost");

  function fmtCost(usd) {
    // 3-decimal USD per the spec — sub-cent precision is noise. Use
    // toFixed(3) and prepend "$" for the small-money case ($0.000).
    return "$" + (Number(usd) || 0).toFixed(3);
  }

  function fmtDuration(ms) {
    if (!ms || ms < 0) return "";
    if (ms < 1000) return ms + "ms";
    return (ms / 1000).toFixed(1) + "s";
  }

  function renderSessionCost() {
    if (!sessionBadge) return;
    if (session.turns === 0) {
      sessionBadge.textContent = "";
      sessionBadge.hidden = true;
      return;
    }
    sessionBadge.hidden = false;
    const noun = session.turns === 1 ? "turn" : "turns";
    sessionBadge.textContent = "Session: " + fmtCost(session.costUSD) + " · " + session.turns + " " + noun;
  }

  function renderTurnCostBadge(data) {
    // Attach a small muted badge to the most recent AI surface so the cost
    // sits visually next to what produced it. Appended to the thread as a
    // standalone div so it survives even if no AI text was emitted.
    const cost = Number(data && data.cost_usd) || 0;
    const dur = Number(data && data.duration_ms) || 0;
    const err = data && data.error;
    const parts = [];
    if (err) {
      parts.push(el("span", { className: "turn-err", text: "error: " + truncate(err, 120) }));
    } else {
      if (cost > 0) parts.push(el("span", { text: fmtCost(cost) }));
      if (dur > 0) parts.push(el("span", { text: " · " + fmtDuration(dur) }));
    }
    if (parts.length === 0) return; // nothing to show (mock turn with no metrics)
    const badge = el("div", { className: "turn-badge" + (err ? " err" : "") }, parts);
    thread.appendChild(badge);
    scrollToBottom();
  }

  function dispatchEnvelope(type, data) {
    // Chat-pane-only event types: render functions append to #thread which
    // doesn't exist in terminal mode. Skip them cleanly so save events
    // (which still need to fire for toast feedback) keep working.
    const chatOnlyTypes = [
      "user_message", "ai_thinking", "ai_text",
      "tool_call", "tool_result", "turn_complete", "policy_blocked",
    ];
    if (!hasChatPane && chatOnlyTypes.indexOf(type) !== -1) return;

    switch (type) {
      case "user_message":
        renderUserMessage(data);
        break;
      case "ai_thinking":
        renderThinking();
        break;
      case "ai_text":
        clearThinking();
        renderAIText(data);
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
        renderTurnCostBadge(data);
        if (data && typeof data.cost_usd === "number") {
          session.costUSD += data.cost_usd;
        }
        session.turns += 1;
        renderSessionCost();
        break;
      case "save_started":
        if (hasChatPane) renderSaveCard("started", data);
        setComposerBusy(true);
        break;
      case "save_succeeded":
        if (hasChatPane) renderSaveCard("succeeded", data);
        setComposerBusy(false);
        showToast("Saved.", false);
        break;
      case "save_failed":
        if (hasChatPane) renderSaveCard("failed", data);
        setComposerBusy(false);
        showToast("Save failed: " + (data.error || "unknown"), true);
        break;
      case "policy_blocked":
        renderPolicyBlocked(data);
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
    if (!hasChatPane) {
      if (saveBtn) saveBtn.disabled = busy;
      return;
    }
    input.disabled = busy;
    if (saveBtn) saveBtn.disabled = busy;
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
      "user_message", "ai_thinking", "ai_text", "tool_call", "tool_result",
      "turn_complete", "lock_status", "policy_blocked",
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

  // Chat-pane-only: composer submit handler. Skipped in terminal-mode
  // (the terminal iframe owns input there).
  if (hasChatPane) {
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
  }

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

  // --- Preview tabs + editable address bar (ARD-0035) -------------------
  //
  // The preview pane renders a tab strip (#preview-tabs) + one pane per
  // declared tab (#preview-panes > .preview-tab-pane). Each pane's iframe loads
  // its dedicated-origin proxy (data-frame-url); the header shows/opens the
  // upstream (data-upstream). The address bar is editable and navigates
  // SAME-ORIGIN within the tab's proxy — we apply only path+query+hash, so a
  // typed off-origin host is ignored (containment, ARD-0035). The proxied page
  // postMessages its path up (preview.go nav script); we route by e.origin to
  // the matching pane to refresh its bar + open link. Runtime tabs (+ / ×)
  // clone an existing pane's proxy origin (no new backend port; session-only).
  (function previewTabs() {
    const tabsBar = $("preview-tabs");
    const panesEl = $("preview-panes");
    if (!tabsBar || !panesEl) return; // no preview configured -> fallback message

    const addBtn = $("preview-tab-add");
    const STORAGE_KEY = "boring:preview-active:" + location.pathname;
    const stripScheme = (u) => (u || "").replace(/^https?:\/\//, "");
    const originOf = (u) => {
      try {
        return new URL(u, location.href).origin;
      } catch (e) {
        return "";
      }
    };

    // Resolve the same-origin path a user typed. Any host they type is ignored;
    // we keep only path+query+hash (containment — never proxy off-origin).
    function typedPath(value, upstream) {
      value = (value || "").trim();
      if (value === "") return "/";
      let u = null;
      try {
        u = new URL(value);
      } catch (e) {
        try {
          u = new URL(value, upstream || "http://x/");
        } catch (e2) {
          u = null;
        }
      }
      if (!u) return null;
      return (u.pathname || "/") + u.search + u.hash;
    }

    function navigate(pane, path) {
      if (path == null) return;
      const iframe = pane.querySelector(".preview-iframe");
      const origin = originOf(pane.getAttribute("data-frame-url"));
      if (!iframe || !origin) return;
      iframe.src = origin + (path.charAt(0) === "/" ? path : "/" + path);
    }

    function activate(paneId) {
      let found = false;
      panesEl.querySelectorAll(".preview-tab-pane").forEach((p) => {
        const on = p.getAttribute("data-pane") === paneId;
        p.classList.toggle("active", on);
        if (on) found = true;
      });
      if (!found) return;
      tabsBar.querySelectorAll(".tab").forEach((t) =>
        t.classList.toggle("active", t.getAttribute("data-pane") === paneId),
      );
      try {
        localStorage.setItem(STORAGE_KEY, paneId);
      } catch (e) {
        /* private mode — non-fatal */
      }
    }

    function wirePane(pane) {
      const iframe = pane.querySelector(".preview-iframe");
      const refresh = pane.querySelector(".preview-refresh");
      const addr = pane.querySelector(".preview-url");
      if (refresh && iframe) {
        // Reassigning .src forces a reload that works cross-origin (unlike
        // contentWindow.location.reload(), which throws for foreign frames).
        refresh.addEventListener("click", () => {
          iframe.src = iframe.src;
        });
      }
      if (addr) {
        addr.addEventListener("keydown", (e) => {
          if (e.key !== "Enter") return;
          e.preventDefault();
          navigate(pane, typedPath(addr.value, pane.getAttribute("data-upstream")));
        });
      }
    }

    function wireTab(tab) {
      tab.addEventListener("click", () => activate(tab.getAttribute("data-pane")));
      const close = tab.querySelector(".tab-close");
      if (close) {
        close.addEventListener("click", (e) => {
          e.stopPropagation();
          closeRuntimeTab(tab.getAttribute("data-pane"));
        });
      }
    }

    // Runtime tab: clone the active pane's proxy origin (containment — only an
    // already-allowed origin, never a new backend proxy). Session-only.
    let runtimeSeq = 0;
    function activePane() {
      return (
        panesEl.querySelector(".preview-tab-pane.active") ||
        panesEl.querySelector(".preview-tab-pane")
      );
    }
    function addRuntimeTab() {
      const src = activePane();
      if (!src) return;
      const frameURL = src.getAttribute("data-frame-url");
      const upstream = src.getAttribute("data-upstream") || "";
      const origin = originOf(frameURL);
      if (!frameURL || !origin) return;
      const paneId = "rt-" + runtimeSeq++;

      const pane = document.createElement("div");
      pane.className = "preview-tab-pane";
      pane.setAttribute("data-pane", paneId);
      pane.setAttribute("data-frame-url", frameURL);
      pane.setAttribute("data-upstream", upstream);
      pane.innerHTML =
        '<div class="preview-header">' +
        '<input type="text" class="preview-url" spellcheck="false" autocomplete="off" aria-label="preview address">' +
        '<div class="preview-actions">' +
        '<button type="button" class="preview-btn preview-refresh" title="Reload preview">↻</button>' +
        '<a class="preview-btn preview-open" target="_blank" rel="noopener noreferrer" title="Open in new tab">↗</a>' +
        "</div></div>" +
        '<iframe class="preview-iframe" title="preview"></iframe>';
      const addr = pane.querySelector(".preview-url");
      if (addr) {
        addr.value = stripScheme(upstream);
        addr.title = upstream;
      }
      const open = pane.querySelector(".preview-open");
      if (open && upstream) open.setAttribute("href", upstream);
      pane.querySelector(".preview-iframe").src = origin + "/";
      panesEl.appendChild(pane);
      wirePane(pane);

      const tab = document.createElement("button");
      tab.type = "button";
      tab.className = "tab";
      tab.setAttribute("data-pane", paneId);
      const label = document.createElement("span");
      label.textContent = stripScheme(upstream).split("/")[0] || "tab";
      const close = document.createElement("span");
      close.className = "tab-close";
      close.title = "Close tab";
      close.textContent = "×"; // ×
      tab.appendChild(label);
      tab.appendChild(close);
      if (addBtn) tabsBar.insertBefore(tab, addBtn);
      else tabsBar.appendChild(tab);
      wireTab(tab);
      activate(paneId);
    }
    function closeRuntimeTab(paneId) {
      const tab = tabsBar.querySelector('.tab[data-pane="' + paneId + '"]');
      const pane = panesEl.querySelector('.preview-tab-pane[data-pane="' + paneId + '"]');
      const wasActive = pane && pane.classList.contains("active");
      if (tab) tab.remove();
      if (pane) pane.remove();
      if (wasActive) {
        const first = tabsBar.querySelector(".tab");
        if (first) activate(first.getAttribute("data-pane"));
      }
    }

    // Route nav-reflection messages (preview.go) to the matching pane by origin.
    window.addEventListener("message", (e) => {
      const d = e.data;
      if (!d || d.source !== "boring-preview" || typeof d.path !== "string") return;
      const panes = panesEl.querySelectorAll(".preview-tab-pane");
      for (let i = 0; i < panes.length; i++) {
        const pane = panes[i];
        if (originOf(pane.getAttribute("data-frame-url")) !== e.origin) continue;
        const upstreamOrigin = originOf(pane.getAttribute("data-upstream"));
        if (!upstreamOrigin) return;
        let full;
        try {
          full = new URL(d.path, upstreamOrigin).href;
        } catch (e2) {
          return;
        }
        const addr = pane.querySelector(".preview-url");
        const open = pane.querySelector(".preview-open");
        // Don't clobber the field while the user is editing it.
        if (addr && document.activeElement !== addr) {
          addr.value = stripScheme(full);
          addr.title = full;
        }
        if (open) open.setAttribute("href", full);
        return;
      }
    });

    // Wire declared tabs/panes, bind the add button, restore last active tab.
    panesEl.querySelectorAll(".preview-tab-pane").forEach(wirePane);
    tabsBar.querySelectorAll(".tab").forEach(wireTab);
    if (addBtn) addBtn.addEventListener("click", addRuntimeTab);
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved && panesEl.querySelector('.preview-tab-pane[data-pane="' + saved + '"]')) {
        activate(saved);
      }
    } catch (e) {
      /* private mode — keep server-rendered active tab */
    }
  })();

  // --- Pane layout: resizable split + collapse toggles -------------------
  //
  // The two panes sit in a CSS grid (.panes) whose left/right fr ratios are
  // driven from here; the fixed middle grid track is a draggable gutter.
  // Header buttons collapse either pane. Layout (split ratio + which pane is
  // hidden) persists per-project in localStorage, keyed on the path so
  // different slugs remember their own arrangement. Works identically whether
  // the left pane is the chat thread or the terminal iframe.
  const panes = $("panes");
  const gutter = $("pane-gutter");
  const toggleLeftBtn = $("toggle-left");
  const togglePreviewBtn = $("toggle-preview");
  if (panes) {
    const LS_KEY = "boring-ui:layout:" + location.pathname;
    const MIN = 0.15;
    const MAX = 0.85; // clamp so neither pane fully vanishes while dragging

    const clampRatio = (r) => Math.min(MAX, Math.max(MIN, r));

    function loadLayout() {
      const def = { ratio: 0.5, hidden: null }; // hidden: null | "left" | "right"
      try {
        const raw = localStorage.getItem(LS_KEY);
        if (!raw) return def;
        const p = JSON.parse(raw);
        return {
          ratio: typeof p.ratio === "number" ? clampRatio(p.ratio) : 0.5,
          hidden: p.hidden === "left" || p.hidden === "right" ? p.hidden : null,
        };
      } catch {
        return def;
      }
    }
    function saveLayout() {
      try {
        localStorage.setItem(LS_KEY, JSON.stringify(state));
      } catch {
        /* private mode / storage disabled — layout just won't persist */
      }
    }
    function applyLayout() {
      panes.style.setProperty("--left-fr", state.ratio + "fr");
      panes.style.setProperty("--right-fr", 1 - state.ratio + "fr");
      panes.classList.toggle("hide-left", state.hidden === "left");
      panes.classList.toggle("hide-right", state.hidden === "right");
      if (toggleLeftBtn) {
        const hidden = state.hidden === "left";
        toggleLeftBtn.setAttribute("aria-pressed", String(hidden));
        toggleLeftBtn.title = hidden ? "Show left pane" : "Hide left pane";
      }
      if (togglePreviewBtn) {
        const hidden = state.hidden === "right";
        togglePreviewBtn.setAttribute("aria-pressed", String(hidden));
        togglePreviewBtn.title = hidden ? "Show preview" : "Hide preview";
      }
    }

    const state = loadLayout();
    applyLayout();

    // Drag-to-resize. Pointer capture keeps tracking even when the cursor
    // crosses an iframe; the .dragging class also disables iframe pointer
    // events as a belt-and-braces measure.
    if (gutter) {
      gutter.addEventListener("pointerdown", (e) => {
        if (state.hidden) return; // nothing to resize when a pane is collapsed
        e.preventDefault();
        panes.classList.add("dragging");
        gutter.setPointerCapture(e.pointerId);
        const onMove = (ev) => {
          const rect = panes.getBoundingClientRect();
          if (rect.width === 0) return;
          state.ratio = clampRatio((ev.clientX - rect.left) / rect.width);
          panes.style.setProperty("--left-fr", state.ratio + "fr");
          panes.style.setProperty("--right-fr", 1 - state.ratio + "fr");
        };
        const onUp = (ev) => {
          panes.classList.remove("dragging");
          try {
            gutter.releasePointerCapture(ev.pointerId);
          } catch {
            /* capture may already be gone */
          }
          gutter.removeEventListener("pointermove", onMove);
          gutter.removeEventListener("pointerup", onUp);
          saveLayout();
        };
        gutter.addEventListener("pointermove", onMove);
        gutter.addEventListener("pointerup", onUp);
      });

      // Keyboard resize: arrow keys nudge the split 2% at a time.
      gutter.addEventListener("keydown", (e) => {
        if (state.hidden) return;
        let d = 0;
        if (e.key === "ArrowLeft") d = -0.02;
        else if (e.key === "ArrowRight") d = 0.02;
        else return;
        e.preventDefault();
        state.ratio = clampRatio(state.ratio + d);
        applyLayout();
        saveLayout();
      });
    }

    // Collapse toggles. At most one pane hidden at a time — collapsing one
    // un-collapses the other so the view never goes fully blank.
    const setHidden = (which) => {
      state.hidden = state.hidden === which ? null : which;
      applyLayout();
      saveLayout();
    };
    if (toggleLeftBtn) toggleLeftBtn.addEventListener("click", () => setHidden("left"));
    if (togglePreviewBtn) togglePreviewBtn.addEventListener("click", () => setHidden("right"));
  }

  // --- Boot --------------------------------------------------------------

  // Boot:
  //   - hydrate() loads /api/thread events into the chat — chat-pane only.
  //   - attachSSE() runs in BOTH modes so save-flow events (save_started /
  //     save_succeeded / save_failed) can still drive toasts in terminal
  //     mode when the user clicks Save in the header. dispatchEnvelope's
  //     chat-pane render branches no-op cleanly when thread/composer
  //     don't exist (scrollToBottom + setComposerBusy are guarded).
  (async () => {
    if (hasChatPane) await hydrate();
    attachSSE();
  })();
})();
