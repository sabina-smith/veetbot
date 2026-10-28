// First run: connect Gmail, answer a few questions while the helper scans
// the inbox, then keep the topics it proposes. State lives in the app
// (onboarding.status); this page polls it.
(() => {
  "use strict";
  const call = (op, args = {}) => window.webkit.messageHandlers.topics.postMessage({ op, args });
  const { el } = window.Topics;
  const COLOURS = ["#0E7C86", "#B4531A", "#2347C8", "#7A2E6E", "#A77A00", "#0F0F0E"];
  const HELPERS = ["Wren", "Juno", "Otis", "Mara", "Ezra", "Iris", "Theo", "Nell"];
  const ACCENT = "#0E7C86";
  const QUESTIONS = [
    { q: "What should your helpers call you?", hint: "Your first name is fine.", example: "Sabina" },
    { q: "What do you do for work?", hint: "A few words.", example: "Investor at a venture firm" },
    { q: "Who's at home with you?", hint: "People and pets. Or skip.", example: "My partner Sam and our dog Juniper", optional: true },
    { q: "What would you most like off your plate?", hint: "Separate things with commas.", example: "Founder follow-ups, school emails, the leaky roof" },
  ];
  const s = { step: "connect", started: false, qi: 0, answers: [], draft: "", sent: false, status: { phase: "idle" }, picks: null, error: "" };
  const root = document.getElementById("root");

  async function poll() {
    try {
      const next = await call("onboarding.status");
      const changed = JSON.stringify(next) !== JSON.stringify(s.status);
      const before = s.step;
      s.status = next;
      if (s.step === "connect" && ["scanning", "scanned", "proposing", "proposed"].includes(next.phase)) s.step = "about";
      if (s.step === "about" && next.phase === "proposed") { s.step = "choose"; s.picks = defaultPicks(next); }
      if (!changed || s.step === "creating") return;
      // Mid-question, only the scan panel changes, so typing isn't interrupted.
      const panel = document.getElementById("scan-panel");
      if (before === s.step && s.step === "about" && !s.sent && panel) panel.replaceWith(scanPanel());
      else render();
    } catch (e) { /* the next poll tries again */ }
  }
  setInterval(poll, 1500);

  function defaultPicks(status) {
    const picks = {};
    status.core.forEach((p) => { picks[p.name] = { on: true, name: p.name }; });
    status.more.forEach((p) => { picks[p.name] = { on: false, name: p.name }; });
    return picks;
  }

  function steps() {
    const idx = s.step === "connect" ? 0 : s.step === "about" ? 1 : 2;
    return el("ol", { class: "t-row", style: { gap: "24px", listStyle: "none", margin: 0, padding: "0 0 12px", borderBottom: "1px solid var(--line)", fontSize: "13px" } },
      ["Connect Gmail", "About you", "Your topics"].map((label, i) => el("li", { class: "t-row", style: { gap: "8px", fontWeight: i === idx ? 650 : 400, color: i <= idx ? "var(--ink)" : "var(--faint)" } },
        el("span", { class: "tabular", style: { width: "20px", height: "20px", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "11px", fontWeight: 650, background: i <= idx ? ACCENT : "#ededE9", color: i <= idx ? "#fff" : "var(--muted)" } }, i < idx ? "✓" : String(i + 1)),
        label)));
  }

  function connectStep() {
    const phase = s.status.phase;
    const checking = s.started && (phase === "idle" || phase === "connecting");
    const start = () => { s.started = true; s.error = ""; call("onboarding.start"); render(); };
    return el("div", { class: "rise", style: { marginTop: "40px" } },
      el("p", { class: "eyebrow muted" }, "Welcome to Topics"),
      el("h1", { class: "display tp-title", style: { fontSize: "64px", lineHeight: 1.02, margin: "8px 0 0" } }, "Let’s start with your inbox."),
      el("p", { style: { marginTop: "20px", fontSize: "17px", lineHeight: 1.5, maxWidth: "620px", color: "var(--ink-2)" } },
        "Your helper looks over subject lines and senders from the last three months of Gmail to see what’s going on: work, home, the dog, the kids’ school. Then it sets up your first topics from that."),
      el("p", { class: "t-small muted", style: { marginTop: "8px", maxWidth: "620px" } }, "It only reads. Nothing is sent, moved or labelled, and your mail stays with your own Veetbot."),
      phase === "unavailable" ? unavailable()
        : checking ? el("p", { class: "t-helper-note", style: { marginTop: "40px", fontSize: "17px", color: ACCENT } }, "Checking your Gmail…")
        : el("div", { class: "t-row", style: { gap: "16px", marginTop: "40px" } },
          el("button", { class: "t-button t-primary", type: "button", style: { height: "48px", padding: "0 24px", fontSize: "15px" }, onclick: start }, "Connect Gmail →"),
          skipButton()));
  }

  function unavailable() {
    const retry = () => { s.started = true; call("onboarding.start"); render(); };
    return el("div", { class: "tp-card rise", style: { marginTop: "40px", maxWidth: "640px", borderTop: "2px solid var(--bad)" } },
      el("p", { class: "eyebrow", style: { margin: "0 0 8px" } }, "Gmail isn’t connected"),
      el("p", { style: { margin: 0, fontSize: "15px" } }, s.status.error || "Your helper couldn’t read Gmail."),
      el("ol", { style: { margin: "16px 0 0", paddingLeft: "20px", fontSize: "14px", lineHeight: 1.6, color: "var(--ink-2)" } },
        el("li", {}, "In the veetbot folder, run ", el("code", {}, "uv run python -m gmail_mcp bootstrap"), " and approve each Google prompt."),
        el("li", {}, "Point Veetbot’s ", el("code", {}, "GMAIL_*_CREDENTIAL_FILE"), " settings at the new files and restart Veetbot."),
        el("li", {}, "Come back here and try again.")),
      el("div", { class: "t-row", style: { gap: "16px", marginTop: "20px" } },
        el("button", { class: "t-button t-primary", type: "button", onclick: retry }, "Try again"),
        skipButton()));
  }

  function skipButton() {
    return el("button", { type: "button", class: "t-small muted", style: { textDecoration: "underline", textUnderlineOffset: "3px" }, onclick: () => call("onboarding.skip") }, "Set up a topic by hand instead");
  }

  function aboutStep() {
    return el("div", { class: "rise", style: { marginTop: "40px", display: "grid", gap: "48px", gridTemplateColumns: "minmax(0,7fr) minmax(0,4fr)", alignItems: "start" } },
      s.sent ? waiting() : question(),
      scanPanel());
  }

  function question() {
    const q = QUESTIONS[s.qi];
    const asked = QUESTIONS.slice(0, s.qi).map((x, i) => el("li", { style: { display: "flex", flexDirection: "column", gap: "4px" } },
      el("span", { class: "muted", style: { fontSize: "14px" } }, x.q),
      el("span", { style: { fontSize: "17px", borderLeft: `3px solid ${ACCENT}`, paddingLeft: "12px" } }, s.answers[i] || "—")));
    const input = el("input", { value: s.draft, placeholder: q.hint, "aria-label": q.q, style: { fontSize: "18px", border: 0, padding: "8px 0", flex: 1 } });
    input.addEventListener("input", () => { s.draft = input.value; });
    const next = (answer) => {
      s.answers[s.qi] = answer;
      s.draft = "";
      if (s.qi + 1 < QUESTIONS.length) { s.qi += 1; return render(); }
      s.sent = true;
      call("onboarding.answer", { answers: QUESTIONS.map((x, i) => ({ q: x.q, a: s.answers[i] || "" })) });
      render();
    };
    const form = el("form", { style: { marginTop: "18px" } },
      el("div", { class: "t-row", style: { gap: "12px", borderBottom: "2px solid var(--ink)", paddingBottom: "4px" } }, input,
        el("button", { type: "submit", class: "tp-send", style: { background: "var(--ink)", color: "#fff" }, "aria-label": "Answer" }, "↑")),
      el("div", { class: "t-row", style: { gap: "16px", marginTop: "8px" } },
        el("button", { type: "button", class: "t-small muted", style: { textDecoration: "underline", textDecorationColor: "#c9c9c3", textUnderlineOffset: "3px" }, onclick: () => { s.draft = q.example; render(); } }, `e.g. “${q.example}”`),
        q.optional ? el("button", { type: "button", class: "t-small", style: { fontWeight: 650 }, onclick: () => next("") }, "Skip") : null));
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      if (s.draft.trim()) next(s.draft.trim());
    });
    setTimeout(() => input.focus(), 0);
    return el("div", {},
      el("div", { class: "t-row", style: { gap: "24px", alignItems: "flex-end" } },
        el("div", { class: "px-body", style: { flex: "none" } }, window.Topics.sprite("Wren", ACCENT, { scale: 6 })),
        el("div", { class: "px-bubble", style: { maxWidth: "460px", marginBottom: "32px", fontSize: "24px", fontWeight: 650, letterSpacing: "-0.02em", padding: "14px 18px", lineHeight: 1.2 } },
          s.qi === 0 ? el("span", { style: { display: "block", fontSize: "14px", fontWeight: 500, letterSpacing: 0, color: "var(--muted)", marginBottom: "6px" } }, "While I read, a few quick questions.") : null,
          q.q)),
      asked.length ? el("ol", { style: { listStyle: "none", padding: 0, margin: "28px 0 0", display: "flex", flexDirection: "column", gap: "16px" } }, asked) : null,
      form);
  }

  function waiting() {
    const name = s.answers[0] ? `, ${s.answers[0]}` : "";
    const phase = s.status.phase;
    return el("div", {},
      el("h2", { class: "display", style: { fontSize: "40px", margin: 0, lineHeight: 1.1 } }, `Thanks${name}.`),
      el("p", { class: "t-helper-note", style: { marginTop: "16px", fontSize: "17px", color: ACCENT } },
        phase === "proposing" ? "Putting your first topics together…" : "Finishing up with your inbox…"),
      phase === "failed" ? failed() : null);
  }

  function failed() {
    return el("div", { style: { marginTop: "24px" } },
      el("p", { style: { color: "var(--bad)", margin: 0 } }, s.status.error || "Something went wrong."),
      el("div", { class: "t-row", style: { gap: "16px", marginTop: "12px" } },
        el("button", { class: "t-button t-primary", type: "button", onclick: () => { s.sent = false; s.qi = 0; s.answers = []; s.step = "connect"; s.started = true; call("onboarding.start"); render(); } }, "Start over"),
        skipButton()));
  }

  function scanPanel() {
    const st = s.status;
    const done = ["scanned", "proposing", "proposed"].includes(st.phase);
    return el("aside", { id: "scan-panel", class: "tp-card", style: { borderTop: `2px solid ${ACCENT}`, position: "sticky", top: "24px" } },
      el("p", { class: "eyebrow", style: { margin: "0 0 12px" } }, done ? "Read your inbox" : "Reading your inbox"),
      el("p", { class: "display tabular", style: { margin: 0, fontSize: "44px", lineHeight: 1 } }, done ? String(st.threadsScanned || "—") : String(st.searches || 0)),
      el("p", { class: "t-small muted", style: { marginTop: "4px" } }, done ? "threads from the last 3 months" : "steps so far · this takes a few minutes"),
      done && st.areas.length ? el("div", { style: { marginTop: "20px" } },
        el("p", { class: "eyebrow muted", style: { margin: "0 0 8px" } }, "What came up"),
        el("div", { class: "t-row", style: { gap: "6px", flexWrap: "wrap" } }, st.areas.map((a) => el("span", { style: { fontSize: "13px", padding: "4px 8px", background: "#f1f1ee" } }, a))))
        : null);
  }

  function chooseStep() {
    const st = s.status;
    const kept = [...st.core, ...st.more].filter((p) => s.picks[p.name].on);
    const create = async () => {
      const used = new Set();
      const topics = kept.map((p, i) => {
        const helper = HELPERS.find((h) => !used.has(h)) || "Wren";
        used.add(helper);
        return { source: p.name, name: s.picks[p.name].name.trim(), colour: COLOURS[i % COLOURS.length], helper };
      });
      s.step = "creating";
      s.error = "";
      render();
      try { await call("onboarding.create", { topics }); } catch (e) { s.error = String((e && e.message) || e); s.step = "choose"; render(); }
    };
    return el("div", { class: "rise", style: { marginTop: "40px" } },
      el("p", { class: "eyebrow muted" }, `From ${st.threadsScanned || "your"} threads and what you told me`),
      el("h1", { class: "display tp-title", style: { fontSize: "56px", lineHeight: 1.05, margin: "8px 0 0" } }, "Here’s where I’d start."),
      el("div", { style: { marginTop: "32px", display: "grid", gap: "24px", gridTemplateColumns: `repeat(${Math.max(st.core.length, 1)}, minmax(0,1fr))` } },
        st.core.map((p, i) => coreCard(p, COLOURS[i % COLOURS.length]))),
      st.more.length ? el("section", { style: { marginTop: "48px" } },
        el("h2", { class: "eyebrow", style: { margin: "0 0 4px" } }, "Also in your mail"),
        el("p", { class: "t-small muted", style: { margin: "0 0 12px" } }, "Add any now, or later from New topic."),
        el("ul", { class: "t-list", style: { listStyle: "none", padding: 0, margin: 0 } }, st.more.map(moreRow)))
        : null,
      s.error ? el("p", { style: { color: "var(--bad)", marginTop: "24px" } }, s.error) : null,
      el("div", { class: "t-row", style: { gap: "16px", marginTop: "40px" } },
        el("button", { class: "t-button t-primary", type: "button", disabled: kept.length === 0, style: { height: "48px", padding: "0 24px", fontSize: "15px" }, onclick: create },
          kept.length === 1 ? "Set up 1 topic →" : `Set up ${kept.length} topics →`),
        skipButton()));
  }

  function coreCard(p, colour) {
    const pick = s.picks[p.name];
    const name = el("input", { class: "display", value: pick.name, "aria-label": "Topic name", style: { fontSize: "32px", border: 0, padding: 0, width: "100%", background: "transparent" } });
    name.addEventListener("input", () => { pick.name = name.value; });
    return el("article", { class: "tp-card", style: { borderTop: `3px solid ${colour}`, opacity: pick.on ? 1 : 0.5 } },
      el("div", { class: "t-row", style: { justifyContent: "space-between", alignItems: "center" } },
        el("p", { class: "eyebrow", style: { margin: 0, color: colour } }, "First topic"),
        el("label", { class: "t-row t-small", style: { gap: "6px" } },
          el("input", { type: "checkbox", checked: pick.on, onchange: (e) => { pick.on = e.target.checked; render(); } }), "Keep")),
      name,
      p.why ? el("p", { style: { margin: "8px 0 0", fontSize: "14.5px", color: "var(--ink-2)", lineHeight: 1.45 } }, p.why) : null,
      p.onYourMind.length ? el("div", { style: { marginTop: "16px" } },
        el("p", { class: "eyebrow muted", style: { margin: "0 0 6px" } }, "On your mind"),
        el("ul", { style: { margin: 0, paddingLeft: "18px", fontSize: "14px", lineHeight: 1.55 } }, p.onYourMind.map((x) => el("li", {}, x))))
        : null,
      p.people.length ? el("p", { class: "t-small muted", style: { marginTop: "12px" } }, p.people.join(" · ")) : null);
  }

  function moreRow(p) {
    const pick = s.picks[p.name];
    return el("li", { class: "t-item t-row", style: { gap: "16px", padding: "12px 0", alignItems: "baseline", borderTop: "1px solid var(--line)" } },
      el("b", { style: { fontSize: "16px", fontWeight: 650, minWidth: "160px" } }, p.name),
      el("span", { class: "muted", style: { flex: 1, fontSize: "14px" } }, p.why),
      el("button", { type: "button", class: pick.on ? "t-button t-primary" : "t-button", "aria-pressed": String(pick.on), onclick: () => { pick.on = !pick.on; render(); } }, pick.on ? "Added ✓" : "Add"));
  }

  function render() {
    root.replaceChildren(el("div", { class: "tp-page", style: { maxWidth: "1040px" } }, steps(),
      s.step === "connect" ? connectStep()
        : s.step === "about" ? aboutStep()
        : s.step === "choose" ? chooseStep()
        : el("p", { class: "t-helper-note rise", style: { marginTop: "64px", fontSize: "17px", color: ACCENT } }, "Setting up your topics…")));
  }
  render();
  poll();
})();
