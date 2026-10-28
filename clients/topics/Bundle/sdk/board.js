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

  // Kept across redraws so a half-typed answer survives the helper's updates.
  const stripAnswers = new Map();

  function renderMasthead() {
    const items = [];
    for (const id of stripAnswers.keys()) if (!state.proposals.some((p) => p.id === id)) stripAnswers.delete(id);
    for (const p of state.proposals) {
      // A question not tied to a row has no card to answer it on, so answer it here.
      const inline = !p.ref ? stripAnswers.get(p.id) ?? inlineAnswer(p) : null;
      if (inline) stripAnswers.set(p.id, inline);
      items.push(inline
        ? el("div", { class: "tp-need-inline" }, el("b", {}, p.title), p.summary ? el("span", {}, p.summary) : null, inline)
        : el("button", { class: "tp-need", type: "button", onclick: () => openProposal(p.id) },
          el("b", {}, p.title), el("span", {}, needsSummary(p))));
    }
    // Suggestions from Veetbot (instructions, schedule and reminder ideas)
    // will appear here with Accept / Dismiss once the server API lands.
    for (const g of state.suggestions || []) {
      items.push(el("span", { class: "tp-need" }, el("b", {}, g.title), g.detail ? el("span", {}, g.detail) : null, " ",
        el("button", { type: "button", class: "t-textbutton t-helper", onclick: () => call("suggestion.accept", { id: g.id }).catch(report) }, "Accept"), " ",
        el("button", { type: "button", class: "t-textbutton", onclick: () => call("suggestion.dismiss", { id: g.id }).catch(report) }, "Dismiss")));
    }
    for (const d of state.dueToday) {
      items.push(el("span", { class: "tp-due" }, el("b", {}, d.label), " ", el("span", {}, "today")));
    }
    masthead.replaceChildren(
      el("p", { class: "eyebrow tp-eyebrow" }, el("span", { class: "tp-swatch" }),
        `Topic${topic.subtitle ? ` · ${topic.subtitle}` : ""}`),
      el("h1", { class: "display tp-title" }, topic.name),
      el("button", { type: "button", class: "tp-summary", onclick: openAbout },
        layout.summary || `What ${topic.name} covers`, el("span", {}, " About this board →")),
      items.length ? el("div", { class: "tp-needs" }, el("span", { class: "eyebrow" }, "Needs you"), items) : "",
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
      const card = el("section", { class: "tp-card rise", "aria-label": m.title, "data-module": m.id, style: { gridColumn: `span ${Math.max(1, Math.min(12, m.span))}` } },
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

  // ---------- about panel ----------

  /** What the board is about, the facts the helper keeps, and what each card is for. */
  async function openAbout() {
    const close = () => overlay.replaceChildren();
    const facts = await call("db.query", { sql: "SELECT title, detail FROM items WHERE card = 'about' ORDER BY position IS NULL, position, id", params: [] }).catch(() => []);
    const sheet = el("aside", { class: "tp-sheet", role: "dialog", "aria-modal": "true", onclick: (e) => e.stopPropagation() },
      el("header", {},
        el("div", { style: { flex: "1" } },
          el("p", { class: "eyebrow" }, "About this board"),
          el("h2", { class: "display" }, topic.name)),
        el("button", { class: "tp-close", type: "button", "aria-label": "Close", onclick: close }, "✕")),
      el("div", { class: "tp-sheet-body tp-about" },
        layout.summary ? el("p", { class: "tp-about-summary" }, layout.summary) : null,
        facts.length ? [el("p", { class: "eyebrow" }, `What ${helper} knows`),
          el("ul", {}, facts.map((f) => el("li", {}, f.title, f.detail ? el("span", {}, ` · ${f.detail}`) : null)))] : null,
        el("p", { class: "eyebrow" }, "On this board"),
        layout.modules.length ? el("ul", { class: "tp-about-cards" }, layout.modules.map((m) =>
          el("li", {}, el("button", { type: "button", onclick: () => { close(); scrollToCard(m.id); } }, m.title),
            el("p", {}, m.about || "")))) : el("p", { class: "muted" }, `${helper} hasn't added any cards yet.`),
        el("p", { class: "tp-fine" }, `Ask ${helper} to change what this board covers.`)));
    overlay.replaceChildren(el("div", { class: "tp-scrim", onclick: close }, sheet));
  }

  function scrollToCard(id) {
    document.querySelector(`[data-module="${CSS.escape(id)}"]`)?.scrollIntoView({ behavior: "smooth", block: "start" });
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
    const fields = p.fields ?? [];
    const answers = {};
    const answered = (f) => {
      const v = answers[f.key];
      return v !== undefined && v !== null && v !== "" && !(Array.isArray(v) && v.length === 0);
    };
    const complete = () => fields.every((f) => f.optional || answered(f));
    const primaryLabel = () => {
      const o = picked !== null ? p.options[picked] : null;
      if (fields.length) return hasOptions ? "Choose and send" : "Send";
      if (!hasOptions) return "Send answer";
      if (p.kind === "purchase") return `Put in cart${o && typeof o.price === "number" ? ` · ${money(o.price)}` : ""}`;
      return `Choose${o && typeof o.price === "number" ? ` · ${money(o.price)}` : " this"}`;
    };
    const primary = el("button", { class: "tp-btn primary", type: "button" });
    const syncPrimary = () => {
      primary.textContent = primaryLabel();
      primary.disabled = fields.length ? !complete() : !hasOptions && !note.trim();
    };
    const fieldNodes = fields.map((f) => fieldInput(f, answers, syncPrimary));
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
    const noteOptional = hasOptions || fields.length > 0;
    const noteInput = el("input", { class: "tp-note-input", placeholder: hasOptions ? "e.g. closer to me, cheapest is fine" : fields.length ? "Anything else" : "Your answer", value: note });
    noteInput.addEventListener("input", () => { note = noteInput.value; syncPrimary(); });
    const chips = hasOptions && !fields.length ? el("div", { class: "tp-chips" }, ["closer to me", "cheapest is fine", "not this time"].map((s) =>
      el("button", { type: "button", onclick: () => { note = s; noteInput.value = s; syncPrimary(); } }, s))) : null;
    const recommended = p.recommended !== null && p.recommended !== undefined ? p.options[p.recommended] : null;

    primary.addEventListener("click", async () => {
      primary.disabled = true;
      const sent = Object.fromEntries(fields.filter(answered).map((f) => [f.key, answers[f.key]]));
      await call("proposal.accept", { id: p.id, option: hasOptions ? picked : null, note: note.trim() || null, answers: sent }).catch(report);
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
        fieldNodes,
        el("label", { class: "tp-label" }, noteOptional ? "Note for " : "Your answer for ", helper, noteOptional ? el("span", {}, " (optional)") : null),
        noteInput, chips,
        p.kind === "purchase" ? el("p", { class: "tp-fine" }, "Choosing puts it in your cart. Nothing is bought until you say so.") : null),
      el("footer", {},
        el("button", { class: "tp-btn ghost", type: "button", onclick: async () => { await call("proposal.decline", { id: p.id, note: note.trim() || null }).catch(report); close(); } }, hasOptions ? "Neither" : "Not now"),
        primary));
    overlay.replaceChildren(el("div", { class: "tp-scrim", onclick: close }, sheet));
    (hasOptions ? optionNodes[picked ?? 0] : fields.length ? sheet.querySelector(".tp-field button, .tp-field input") ?? noteInput : noteInput).focus();
  }

  // ---------- answer fields: pickers instead of typing ----------

  const integrationNames = { calendar: "Calendar", apple_health: "Apple Health", rent_the_runway: "Rent the Runway" };

  // ---------- answering on the row ----------

  const inlineTypes = new Set(["date", "daterange", "number", "pick", "multi", "text", "connect", "signin"]);

  /** Whether `p` is light enough to answer without the sidebar. */
  function answersInline(p) {
    if (p.kind === "purchase") return false;
    const fields = p.fields ?? [];
    if (fields.length) return !p.options.length && fields.length <= 2 && fields.every((f) => inlineTypes.has(f.type));
    if (!p.options.length) return p.kind === "question";
    return p.options.length <= 4 && p.options.every((o) => o.label.length <= 40 && typeof o.price !== "number");
  }

  /** Controls to answer `p` in place, or null when it needs the sidebar. */
  function inlineAnswer(p) {
    if (!answersInline(p)) return null;
    const send = (args) => call("proposal.accept", { id: p.id, option: null, note: null, answers: {}, ...args }).catch(report);
    const details = el("button", { type: "button", class: "t-textbutton", onclick: () => openProposal(p.id) }, "More");
    const fields = p.fields ?? [];
    let body;
    if (fields.length) {
      const answers = {};
      const answered = (f) => { const v = answers[f.key]; return v !== undefined && v !== null && v !== "" && !(Array.isArray(v) && !v.length); };
      const complete = () => fields.every((f) => f.optional || answered(f));
      // One tap is the whole answer for a single pick or a connect button.
      const oneTap = fields.length === 1 && (fields[0].type === "connect" || fields[0].type === "signin" || (fields[0].type === "pick" && !fields[0].other));
      const submit = el("button", { type: "button", class: "t-textbutton t-helper tp-inline-send", onclick: () => {
        submit.disabled = true;
        send({ answers: Object.fromEntries(fields.filter(answered).map((f) => [f.key, answers[f.key]])) });
      } }, "Send");
      const changed = () => {
        submit.disabled = !complete();
        if (oneTap && complete()) submit.click();
      };
      body = el("div", { class: "tp-inline" },
        fields.map((f) => fieldInput(f, answers, changed, { inline: true })),
        el("div", { class: "tp-inline-actions" }, oneTap ? null : submit, details));
      submit.disabled = !complete();
    } else if (p.options.length) {
      body = el("div", { class: "tp-inline" },
        el("div", { class: "tp-chips tp-pick" }, p.options.map((o, i) =>
          el("button", { type: "button", title: o.detail ?? "", class: p.recommended === i ? "rec" : "", onclick: (e) => {
            e.currentTarget.classList.add("on");
            e.currentTarget.parentElement.querySelectorAll("button").forEach((b) => { b.disabled = true; });
            send({ option: i });
          } }, o.label))),
        el("div", { class: "tp-inline-actions" }, details));
    } else {
      const input = el("input", { class: "tp-note-input", placeholder: "Your answer, then Enter" });
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && input.value.trim()) { input.disabled = true; send({ note: input.value.trim() }); }
      });
      body = el("div", { class: "tp-inline" }, input, el("div", { class: "tp-inline-actions" }, details));
    }
    return body;
  }

  /** One field of a question; writes its answer into `answers[f.key]` and calls `changed`. */
  function fieldInput(f, answers, changed, { inline = false } = {}) {
    const set = (v) => { answers[f.key] = v; changed(); };
    if (f.value !== null && f.value !== undefined) answers[f.key] = f.value;
    let body;
    switch (f.type) {
      case "date":
      case "daterange": {
        const calendar = calendarPicker(f.type === "daterange", f.value, set);
        if (!inline) { body = calendar; break; }
        // On a row the calendar folds away behind the current choice.
        calendar.hidden = true;
        const caption = calendar.querySelector(".tp-cal-caption");
        const toggle = el("button", { type: "button", class: "t-textbutton tp-date-toggle", onclick: () => { calendar.hidden = !calendar.hidden; } });
        const sync = () => { toggle.textContent = caption?.textContent ?? "Pick a day"; };
        new MutationObserver(() => { sync(); }).observe(calendar, { childList: true, subtree: true });
        sync();
        body = el("div", {}, toggle, calendar);
        break;
      }
      case "number":
        body = stepper(f, set);
        break;
      case "pick":
      case "multi":
        body = chipPicker(f, set);
        break;
      case "connect":
        body = connectButton(f, set);
        break;
      case "signin":
        body = signInChoice(f, set);
        break;
      default: {
        const input = el("input", { class: "tp-note-input", value: f.value ?? "", placeholder: f.label });
        input.addEventListener("input", () => set(input.value.trim()));
        body = input;
      }
    }
    // A lone connect or sign-in choice on a row says enough without a label.
    if (inline && (f.type === "connect" || f.type === "signin")) return el("div", { class: "tp-field tp-field-inline" }, body);
    return el("div", { class: inline ? "tp-field tp-field-inline" : "tp-field" },
      el("label", { class: "tp-label" }, f.label, f.optional ? el("span", {}, " (optional)") : null,
        inline && f.hint ? el("span", {}, ` · ${f.hint}`) : null),
      !inline && f.hint ? el("p", { class: "tp-hint" }, f.hint) : null,
      body);
  }

  function calendarPicker(range, value, set) {
    const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    const parse = (s) => { const [y, m, d] = s.split("-").map(Number); return new Date(y, m - 1, d); };
    const nice = (s) => parse(s).toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
    let start = range ? value?.start ?? null : typeof value === "string" ? value : null;
    let end = range ? value?.end ?? null : null;
    const first = start ? parse(start) : new Date();
    let month = new Date(first.getFullYear(), first.getMonth(), 1);
    const today = iso(new Date());
    const node = el("div", { class: "tp-cal" });
    const draw = () => {
      const days = [];
      for (let i = 0; i < month.getDay(); i++) days.push(el("span"));
      const count = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
      for (let d = 1; d <= count; d++) {
        const day = iso(new Date(month.getFullYear(), month.getMonth(), d));
        const ends = day === start || day === end;
        const inside = range && start && end && day > start && day < end;
        days.push(el("button", {
          type: "button", class: `${ends ? "on" : ""}${inside ? " in" : ""}${day === today ? " today" : ""}`,
          "aria-pressed": String(ends), onclick: () => pick(day),
        }, String(d)));
      }
      const caption = range
        ? start && end ? `${nice(start)} – ${nice(end)}` : start ? `${nice(start)} – pick the last day` : "Pick the first day"
        : start ? nice(start) : "Pick a day";
      const step = (n) => { month = new Date(month.getFullYear(), month.getMonth() + n, 1); draw(); };
      node.replaceChildren(
        el("div", { class: "tp-cal-head" },
          el("button", { type: "button", "aria-label": "Previous month", onclick: () => step(-1) }, "‹"),
          el("b", {}, month.toLocaleDateString(undefined, { month: "long", year: "numeric" })),
          el("button", { type: "button", "aria-label": "Next month", onclick: () => step(1) }, "›")),
        el("div", { class: "tp-cal-grid" }, ["S", "M", "T", "W", "T", "F", "S"].map((d) => el("i", {}, d)), days),
        el("p", { class: "tp-cal-caption" }, caption));
    };
    const pick = (day) => {
      if (!range) { start = day; set(day); }
      else if (!start || end || day < start) { start = day; end = null; set(null); }
      else { end = day; set({ start, end }); }
      draw();
    };
    draw();
    return node;
  }

  function stepper(f, set) {
    const step = f.step ?? 1;
    const clamp = (n) => Math.min(f.max ?? Infinity, Math.max(f.min ?? -Infinity, n));
    const input = el("input", { type: "number", value: f.value ?? "", min: f.min ?? "", max: f.max ?? "", step });
    const update = (n) => { input.value = String(n); set(n); };
    input.addEventListener("input", () => set(input.value === "" ? null : clamp(Number(input.value))));
    const bump = (dir) => update(clamp((input.value === "" ? f.min ?? 0 : Number(input.value)) + dir * step));
    return el("div", { class: "tp-stepper" },
      el("button", { type: "button", "aria-label": "Less", onclick: () => bump(-1) }, "−"),
      input,
      el("button", { type: "button", "aria-label": "More", onclick: () => bump(1) }, "+"),
      f.unit ? el("span", {}, f.unit) : null);
  }

  function chipPicker(f, set) {
    const multi = f.type === "multi";
    let chosen = multi ? (Array.isArray(f.value) ? [...f.value] : []) : f.value ?? null;
    const other = el("input", { class: "tp-note-input", placeholder: "Something else", hidden: true });
    const extra = () => other.value.trim();
    const emit = () => {
      if (multi) set([...chosen.filter((c) => f.options.includes(c)), ...(extra() ? [extra()] : [])]);
      else set(chosen === "\u0000other" ? extra() : chosen);
    };
    if (multi && Array.isArray(f.value)) { const custom = f.value.filter((v) => !f.options.includes(v)); if (custom.length) { other.value = custom.join(", "); other.hidden = false; } }
    if (!multi && f.value && !f.options.includes(f.value)) { other.value = f.value; other.hidden = false; chosen = "\u0000other"; }
    other.addEventListener("input", emit);
    const chips = el("div", { class: "tp-chips tp-pick" });
    const draw = () => chips.replaceChildren(
      ...f.options.map((o) => {
        const on = multi ? chosen.includes(o) : chosen === o;
        return el("button", { type: "button", class: on ? "on" : "", "aria-pressed": String(on), onclick: () => {
          if (multi) chosen = on ? chosen.filter((c) => c !== o) : [...chosen, o];
          else { chosen = o; other.hidden = true; }
          draw(); emit();
        } }, o);
      }),
      f.other ? el("button", { type: "button", class: other.hidden ? "" : "on", onclick: () => {
        other.hidden = !other.hidden;
        if (!multi) chosen = other.hidden ? null : "\u0000other";
        if (other.hidden) other.value = "";
        draw(); emit();
        if (!other.hidden) other.focus();
      } }, "Other…") : "");
    draw();
    return el("div", {}, chips, other);
  }

  /** The first booking on a site: book it yourself from the link, or sign in once so the helper can. */
  function signInChoice(f, set) {
    const site = (() => { try { return new URL(f.url).host.replace(/^www\./, ""); } catch { return null; } })();
    const name = f.name || site || "this site";
    const node = el("div", { class: "tp-signin" });
    const show = (status) => {
      if (status === "signed_in") {
        set("signed_in");
        node.replaceChildren(el("p", {}, el("b", {}, `Signed in to ${name}.`), ` ${helper} can book there after your OK.`));
      } else if (status === "unavailable") {
        // Stays on the row until the owner takes the link, which is booking it themselves.
        node.replaceChildren(el("p", {}, `Signing in isn't set up on this Mac yet. `,
          el("a", { class: "t-link", href: f.url, onclick: (e) => { e.preventDefault(); call("open", { url: f.url }); set("link"); } }, `Book it on ${name} yourself`), "."));
      } else {
        const signIn = el("button", { class: "tp-btn outline", type: "button", onclick: async () => {
          signIn.disabled = true;
          const result = await call("site.signin", { url: f.url, name }).catch((e) => { report(e); return null; });
          if (result === "cancelled" || result === null) { signIn.disabled = false; return; }
          show(result);
        } }, `Sign in to ${name}`);
        node.replaceChildren(
          el("div", { class: "tp-signin-row" },
            el("button", { class: "tp-btn outline", type: "button", onclick: () => { call("open", { url: f.url }); set("link"); } }, `Book it on ${name} myself`),
            signIn),
          el("p", { class: "tp-hint" }, `Sign in once and ${helper} books ${name} for you from now on, always after your OK. Your password goes to ${name} only.`));
      }
    };
    show(state.sites?.[site] === "signed_in" ? "signed_in" : null);
    return node;
  }

  function connectButton(f, set) {
    const name = integrationNames[f.integration] ?? f.integration ?? "this";
    const node = el("div", { class: "tp-connect" });
    const show = (status) => {
      if (status === "connected") {
        set("connected");
        node.replaceChildren(el("p", {}, el("b", {}, `${name} connected.`), ` ${helper} will read it instead of asking you.`));
      } else if (status === "denied") {
        set("denied");
        node.replaceChildren(el("p", {}, `Topics doesn't have access to ${name}. Turn it on in System Settings → Privacy & Security → Calendars, then ask ${helper} again.`));
      } else if (status === "unavailable") {
        set("unavailable");
        node.replaceChildren(el("p", {}, `Topics can't connect to ${name} yet. Send this and ${helper} will work without it.`));
      } else {
        const button = el("button", { class: "tp-btn outline", type: "button", onclick: async () => {
          button.disabled = true;
          show(await call("integration.connect", { name: f.integration }).catch((e) => { report(e); return null; }) ?? "unavailable");
        } }, `Connect ${name}`);
        node.replaceChildren(button, el("p", { class: "tp-hint" }, "Read only. Nothing is changed or shared outside your helpers."));
      }
    };
    show(f.integration === "calendar" ? state.integrations?.calendar ?? "not_connected" : "unavailable");
    return node;
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

  window.__board = { openProposal, inlineAnswer, toast, confirm: confirmAction, setMeta, renderModule, renderAll };

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
