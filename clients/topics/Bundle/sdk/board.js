// A topic's board page: the masthead, the "Needs you" strip, the grid of
// cards (one module each), and the helper's ask bar, decision sheet,
// approval dialog and toasts. State about the helper comes from the app
// through window.__topicsState(); everything the owner does goes back
// through the `topics` message handler.
(() => {
  "use strict";
  const { el, report, call, forModule } = window.Topics;
  const topic = window.__topic;
  const layout = window.__layout;
  const helper = topic.agentName;

  let state = { helper: { working: false }, proposals: [], dueToday: [], thread: [], recent: null };
  let threadOpen = false;
  let draft = "";
  let toastTimer;
  let lastToastID = null;
  const metas = {};
  const rendering = {};

  // ---------- skeleton ----------

  const root = document.getElementById("root");
  const masthead = el("header");
  const grid = el("div", { class: "tp-grid" });
  const page = el("div", { class: "tp-page" }, masthead, grid);
  const dock = el("div", { class: "tp-dock" });
  const overlay = el("div");
  root.append(page, dock, overlay);

  // ---------- masthead ----------

  function renderMasthead() {
    const items = [];
    for (const p of state.proposals) {
      items.push(el("button", { class: "tp-need", type: "button", onclick: () => openProposal(p.id) },
        el("b", {}, p.title), el("span", {}, needsSummary(p))));
    }
    for (const d of state.dueToday) {
      items.push(el("span", { class: "tp-due" }, el("b", {}, d.label), " ", el("span", {}, "today")));
    }
    masthead.replaceChildren(
      el("p", { class: "eyebrow tp-eyebrow" }, el("span", { class: "tp-swatch" }),
        `Topic${topic.subtitle ? ` · ${topic.subtitle}` : ""}`, topic.sealed ? " · Private" : ""),
      el("h1", { class: "display tp-title" }, topic.name),
      items.length ? el("div", { class: "tp-needs" }, el("span", { class: "eyebrow" }, "Needs you"), items) : null,
    );
  }

  function needsSummary(p) {
    const prices = p.options.map((o) => o.price).filter((x) => typeof x === "number");
    const money = (n) => `$${n.toLocaleString("en-US", { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
    if (p.options.length > 1) return prices.length ? `${p.options.length} options from ${money(Math.min(...prices))}` : `${p.options.length} options`;
    if (p.kind === "purchase") return prices.length ? `${money(prices[0])}, your OK` : "needs your OK";
    if (p.kind === "question") return "a question for you";
    return "take a look";
  }

  // ---------- cards ----------

  const cards = {};

  function buildCards() {
    grid.replaceChildren();
    if (!layout.modules.length) {
      grid.style.display = "block";
      grid.append(state.helper.working
        ? el("div", { class: "rise" },
            el("p", { class: "t-helper-note", style: { fontSize: "17px" } }, `${helper} is sketching a first board for ${topic.name}…`),
            el("div", { class: "tp-sketch" }, [0, 1, 2, 3].map(() => el("div", {}, el("i", { style: { width: "50%", height: "22px" } }), el("i"), el("i", { style: { width: "75%" } })))))
        : el("div", { class: "tp-invite rise" },
            el("h2", { class: "display" }, `Tell ${helper} about ${topic.name}.`),
            el("p", {}, `${helper} will sketch a first board from what you say: what's in it, what you keep forgetting, what you'd like off your mind. Every change can be undone.`)));
      return;
    }
    grid.style.display = "";
    for (const m of layout.modules) {
      const body = el("div", { class: "t-module" });
      const meta = el("span", { class: "tp-card-meta tabular" }, metas[m.id] ?? "");
      const flag = el("div");
      const card = el("section", { class: "tp-card rise", "aria-label": m.title, style: { gridColumn: `span ${Math.max(1, Math.min(12, m.span))}` } },
        flag, el("header", { class: "tp-card-head" }, el("h2", { class: "display" }, m.title), meta), body);
      cards[m.id] = { card, body, meta, flag, module: m };
      grid.append(card);
    }
  }

  function renderFlags() {
    const recent = state.recent;
    for (const [id, c] of Object.entries(cards)) {
      const isNew = recent && recent.modules.includes(id);
      c.card.classList.toggle("tp-new", !!isNew);
      c.flag.replaceChildren(isNew
        ? el("p", { class: "tp-card-flag" }, el("b", {}, recent.label ?? `Changed by ${helper} just now`),
            recent.commit ? el("button", { type: "button", onclick: () => call("undo", { commit: recent.commit }) }, "Undo") : null)
        : "");
    }
  }

  async function renderModule(id) {
    const c = cards[id];
    if (!c) return;
    const builtIn = c.module.kind && c.module.kind !== "custom";
    const fn = builtIn ? (window.__cards || {})[c.module.kind] : window.__modules[id];
    if (rendering[id]) { rendering[id] = "again"; return; }
    rendering[id] = true;
    try {
      if (!fn) throw new Error(builtIn ? `unknown card kind ${c.module.kind}` : `modules/${id}.ts did not load`);
      const next = el("div", { class: "t-module" });
      // Cards often pass optional parts as null; DOM append would print "null".
      const clean = (nodes) => nodes.flat(Infinity).filter((n) => n !== null && n !== undefined && n !== false);
      next.append = (...nodes) => Element.prototype.append.apply(next, clean(nodes));
      next.replaceChildren = (...nodes) => Element.prototype.replaceChildren.apply(next, clean(nodes));
      await fn(next, forModule({ id, title: c.module.title, kind: c.module.kind ?? "custom", columns: c.module.columns ?? null }));
      c.body.replaceWith(next);
      c.body = next;
    } catch (e) {
      const broken = el("div", { class: "tp-broken" },
        el("p", { class: "t-strong" }, "This card couldn’t load."),
        el("p", { class: "t-small t-muted", style: { marginTop: "4px", maxWidth: "32ch" } }, `${helper} will fix it on the next visit. The rest of the board is fine.`));
      c.body.replaceWith(broken);
      c.body = broken;
      call("log", { level: "error", message: `${id}: ${String((e && e.stack) || e)}`, module: id }).catch(() => {});
    } finally {
      const again = rendering[id] === "again";
      rendering[id] = false;
      if (again) renderModule(id);
    }
  }

  function renderAll() {
    for (const id of Object.keys(cards)) renderModule(id);
  }

  function setMeta(id, text) {
    metas[id] = text;
    if (cards[id]) cards[id].meta.textContent = text ?? "";
  }

  // ---------- dock: toast, thread, ask bar, and the pixel helper ----------

  const toastSlot = el("div", { style: { display: "flex", justifyContent: "center" } });
  const threadSlot = el("div");
  const formSlot = el("div");
  const bubbleSlot = el("div");
  const helperBody = el("button", { class: "px-body", type: "button", "aria-label": `${helper}: show the conversation`, onclick: () => { threadOpen = !threadOpen; renderDock(); } },
    window.Topics.sprite(helper, topic.accent));
  const helperEl = el("div", { class: "px-helper" }, bubbleSlot, helperBody);
  dock.append(el("div", { class: "tp-dock-inner" }, toastSlot, threadSlot, formSlot, helperEl));

  let toastNode = null;
  function toast(text, undo) {
    window.clearTimeout(toastTimer);
    toastNode = el("div", { class: "tp-toast", role: "status" }, text,
      undo ? el("button", { type: "button", onclick: () => { hideToast(); Promise.resolve(undo()).catch(report); } }, "Undo") : null);
    toastSlot.replaceChildren(toastNode);
    toastTimer = window.setTimeout(hideToast, 6000);
  }
  function hideToast() { toastNode = null; toastSlot.replaceChildren(); }

  // What the helper says in its bubble.
  let said = null;            // { text, undo?, until } after finishing something
  let phraseIndex = 0;
  let phraseTimer;
  const genericPhrases = [
    "Thinking it over…", `Looking over the ${topic.name} board…`, "Remembering where we left off…",
    "Weighing it up…", "Jotting things down…", "Nearly there…",
  ];
  const lookupPhrases = ["Looking things up…", "Reading a few pages…", "Comparing options…", "Checking prices…"];
  const jargon = /\.(md|ts|json|sql)\b|workspace|database|handoff|module|schema|commit|sql|table/i;

  function phrases() {
    const own = [];
    if (state.helper.thinking && !jargon.test(state.helper.thinking)) own.push(`${state.helper.thinking.replace(/[.…]+$/, "")}…`);
    if (state.helper.doing === "Looking things up") return [...own, ...lookupPhrases];
    if (state.helper.doing === "Waiting for your OK") return ["I need your OK on something."];
    return [...own, ...genericPhrases];
  }

  function renderHelper() {
    const working = state.helper.working;
    helperEl.classList.toggle("busy", working);
    window.clearTimeout(phraseTimer);
    if (working) {
      const list = phrases();
      const text = list[phraseIndex % list.length];
      bubbleSlot.replaceChildren(el("div", { class: "px-bubble", role: "status" }, state.helper.stopping ? "Stopping…" : text));
      phraseTimer = window.setTimeout(() => { phraseIndex += 1; renderHelper(); }, 2600);
      return;
    }
    if (said && Date.now() < said.until) {
      bubbleSlot.replaceChildren(el("div", { class: "px-bubble", role: "status" }, said.text,
        said.undo ? el("span", {}, " ", el("button", { type: "button", onclick: () => { said.undo(); said = null; renderHelper(); } }, "Undo")) : null));
      phraseTimer = window.setTimeout(renderHelper, said.until - Date.now());
      return;
    }
    const waiting = state.proposals[0];
    bubbleSlot.replaceChildren(waiting
      ? el("div", { class: "px-bubble attention" },
          el("button", { type: "button", style: { textDecoration: "none", fontWeight: 600, textAlign: "left" }, onclick: () => openProposal(waiting.id) },
            state.proposals.length > 1 ? `${state.proposals.length} things need your call` : `Your call: ${waiting.title}`, " →"))
      : "");
  }

  function helperSays(text, undo) {
    said = { text, undo, until: Date.now() + 7000 };
    helperEl.classList.remove("hop");
    void helperEl.offsetWidth;
    helperEl.classList.add("hop");
    renderHelper();
  }

  function renderDock() {
    const working = state.helper.working;
    const input = el("input", {
      value: draft, "aria-label": `Ask ${helper}`,
      placeholder: working ? "Busy — you can keep working on the board" : `Ask ${helper}, or hand something over…`,
    });
    input.addEventListener("input", () => { draft = input.value; send.disabled = !draft.trim() || working; });
    input.addEventListener("focus", () => { if (state.thread.length && !threadOpen) { threadOpen = true; renderThread(); } });
    const send = el("button", { class: "tp-send", type: "submit", disabled: !draft.trim() || working, "aria-label": `Send to ${helper}` }, "↑");
    const form = el("form", { class: "tp-ask" },
      input,
      !draft && !working && topic.suggestion ? el("button", { class: "tp-suggest", type: "button", onclick: () => ask(topic.suggestion) }, `“${topic.suggestion}”`) : null,
      working ? el("button", { class: "tp-stop", type: "button", onclick: () => call("stop"), disabled: state.helper.stopping }, state.helper.stopping ? "Stopping" : "Stop") : send);
    form.addEventListener("submit", (event) => { event.preventDefault(); ask(draft); });
    const hadFocus = document.activeElement && document.activeElement.closest && document.activeElement.closest(".tp-ask");
    formSlot.replaceChildren(form);
    renderThread();
    renderHelper();
    if (hadFocus) focusAsk();
  }

  function renderThread() {
    const working = state.helper.working;
    threadSlot.replaceChildren(threadOpen && (state.thread.length || working)
      ? el("div", { class: "tp-thread" },
          el("div", { class: "tp-thread-head" }, el("span", { class: "eyebrow" }, helper),
            el("button", { type: "button", "aria-label": "Hide conversation", onclick: () => { threadOpen = false; renderThread(); } }, "✕")),
          el("ul", {}, state.thread.slice(-4).map((m) => el("li", { class: m.from === "you" ? "you" : "" }, m.text)),
            working ? el("li", {}, el("div", { class: "tp-dots" }, el("span"), el("span"), el("span"))) : null))
      : "");
  }

  function focusAsk() {
    const input = dock.querySelector(".tp-ask input");
    if (input) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
  }

  function ask(text) {
    if (!text.trim() || state.helper.working) return;
    call("ask", { text: text.trim() });
    state.thread = [...state.thread, { from: "you", text: text.trim() }];
    draft = "";
    renderDock();
  }

  // ---------- decision sheet ----------

  function openProposal(id) {
    const p = state.proposals.find((x) => x.id === id);
    if (!p) return;
    let picked = p.recommended ?? (p.options.length ? 0 : null);
    let note = "";
    const close = () => overlay.replaceChildren();
    const money = (n) => `$${Number(n).toLocaleString("en-US", { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
    const hasOptions = p.options.length > 0;
    const primaryLabel = () => {
      const o = picked !== null ? p.options[picked] : null;
      if (!hasOptions) return "Send answer";
      if (p.kind === "purchase") return `Put in cart${o && typeof o.price === "number" ? ` · ${money(o.price)}` : ""}`;
      return `Choose${o && typeof o.price === "number" ? ` · ${money(o.price)}` : " this"}`;
    };
    const primary = el("button", { class: "tp-btn primary", type: "button" });
    const syncPrimary = () => {
      primary.textContent = primaryLabel();
      primary.disabled = !hasOptions && !note.trim();
    };
    const optionNodes = p.options.map((o, i) => {
      const node = el("button", { class: `tp-option${picked === i ? " on" : ""}`, type: "button", role: "radio", "aria-checked": String(picked === i) },
        el("span", { class: "tp-radio" }, "✓"),
        el("span", { class: "tp-option-body" },
          p.recommended === i ? el("span", { class: "eyebrow tp-suggested" }, "Suggested") : null,
          el("span", { class: "tp-option-top" }, el("b", {}, o.label), typeof o.price === "number" ? el("span", { class: "tp-price tabular" }, money(o.price)) : null),
          o.detail ? el("p", {}, o.detail) : null,
          o.url ? el("p", {}, el("a", { class: "t-link", href: o.url, onclick: (e) => { e.preventDefault(); e.stopPropagation(); call("open", { url: o.url }); } }, hostOf(o.url))) : null));
      node.addEventListener("click", () => {
        picked = i;
        optionNodes.forEach((n, j) => { n.classList.toggle("on", j === i); n.setAttribute("aria-checked", String(j === i)); });
        syncPrimary();
      });
      return node;
    });
    const noteInput = el("input", { class: "tp-note-input", placeholder: hasOptions ? "e.g. closer to me, cheapest is fine" : "Your answer", value: note });
    noteInput.addEventListener("input", () => { note = noteInput.value; syncPrimary(); });
    const chips = hasOptions ? el("div", { class: "tp-chips" }, ["closer to me", "cheapest is fine", "not this time"].map((s) =>
      el("button", { type: "button", onclick: () => { note = s; noteInput.value = s; syncPrimary(); } }, s))) : null;
    const recommended = p.recommended !== null && p.recommended !== undefined ? p.options[p.recommended] : null;

    primary.addEventListener("click", async () => {
      primary.disabled = true;
      await call("proposal.accept", { id: p.id, option: hasOptions ? picked : null, note: note.trim() || null }).catch(report);
      close();
    });
    syncPrimary();
    const sheet = el("aside", { class: "tp-sheet", role: "dialog", "aria-modal": "true", onclick: (e) => e.stopPropagation() },
      el("header", {},
        el("div", { style: { flex: "1" } },
          el("p", { class: "eyebrow" }, p.kind === "purchase" ? "Your call · Shopping" : p.kind === "question" ? `${helper} asks` : "Your call"),
          el("h2", { class: "display" }, p.title),
          p.kind !== "question" && p.options.length > 1 ? el("p", {}, "Which one should it be?") : null),
        el("button", { class: "tp-close", type: "button", "aria-label": "Close", onclick: close }, "✕")),
      el("div", { class: "tp-sheet-body" },
        (p.summary || recommended) ? el("div", { class: "tp-why" }, el("span", { class: "tp-avatar display" }, helper[0]),
          el("p", { style: { margin: 0 } }, recommended ? el("b", {}, `Suggests ${recommended.label}. `) : null, p.summary ?? "")) : null,
        optionNodes,
        el("label", { class: "tp-label" }, hasOptions ? "Note for " : "Your answer for ", helper, hasOptions ? el("span", {}, " (optional)") : null),
        noteInput, chips,
        p.kind === "purchase" ? el("p", { class: "tp-fine" }, "Choosing puts it in your cart. Nothing is bought until you say so.") : null),
      el("footer", {},
        el("button", { class: "tp-btn ghost", type: "button", onclick: async () => { await call("proposal.decline", { id: p.id, note: note.trim() || null }).catch(report); close(); } }, hasOptions ? "Neither" : "Not now"),
        primary));
    overlay.replaceChildren(el("div", { class: "tp-scrim", onclick: close }, sheet));
    (hasOptions ? optionNodes[picked ?? 0] : noteInput).focus();
  }

  function hostOf(url) {
    try { return new URL(url).host.replace(/^www\./, ""); } catch { return url; }
  }

  // ---------- "Needs your OK" ----------

  function confirmAction(opts) {
    return new Promise((resolve) => {
      const done = (value) => { overlay.replaceChildren(); resolve(value); };
      const ok = el("button", { class: "tp-btn primary", type: "button", onclick: () => done(true) }, opts.confirm ?? "OK");
      overlay.replaceChildren(el("div", { class: "tp-scrim tp-center", onclick: () => done(false) },
        el("div", { class: "tp-dialog", role: "alertdialog", "aria-modal": "true", onclick: (e) => e.stopPropagation() },
          el("div", { class: "tp-dialog-bar" }, "Needs your OK"),
          el("div", { class: "tp-dialog-body" },
            el("h2", { class: "display" }, opts.title),
            opts.rows && opts.rows.length ? el("dl", {}, opts.rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)])) : null,
            opts.explainer ? el("p", {}, opts.explainer) : null),
          el("footer", {}, el("button", { class: "tp-btn outline", type: "button", onclick: () => done(false) }, "Not now"), ok))));
      ok.focus();
    });
  }

  document.addEventListener("keydown", (e) => { if (e.key === "Escape") overlay.replaceChildren(); });

  // ---------- app → page ----------

  window.__topicsChanged = () => renderAll();
  window.__topicsState = (next) => {
    const hadModules = layout.modules.length;
    const wasWorking = state.helper.working;
    state = { ...state, ...next };
    renderMasthead();
    if (!hadModules && wasWorking !== state.helper.working) buildCards();
    renderFlags();
    renderDock();
    if (next.toast && next.toast.id !== lastToastID) {
      lastToastID = next.toast.id;
      const undo = next.toast.commit ? () => call("undo", { commit: next.toast.commit }) : undefined;
      if (next.toast.fromHelper) helperSays(next.toast.text, undo);
      else toast(next.toast.text, undo);
    }
    if (next.openProposal) openProposal(next.openProposal);
  };

  window.__board = { openProposal, toast, confirm: confirmAction, setMeta, renderModule, renderAll };

  // ---------- start ----------

  try {
    renderMasthead();
    buildCards();
  } catch (e) {
    call("log", { level: "error", message: `board start: ${String((e && e.stack) || e)}`, module: "board" }).catch(() => {});
  }
  renderFlags();
  renderDock();
  renderAll();
  call("ready").catch(() => {});
})();
