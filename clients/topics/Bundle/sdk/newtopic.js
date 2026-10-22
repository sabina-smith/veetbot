// New topic: name it, pick a colour and a helper name, decide whether it's
// private, then answer two questions. The app creates the topic and hands
// the answers to its helper, which sketches the first board for real.
(() => {
  "use strict";
  const call = (op, args = {}) => window.webkit.messageHandlers.topics.postMessage({ op, args });
  const { el } = window.Topics;
  const COLOURS = [["Clay", "#B4531A"], ["Plum", "#7A2E6E"], ["Teal", "#0E7C86"], ["Cobalt", "#2347C8"], ["Ochre", "#A77A00"], ["Ink", "#0F0F0E"]];
  const HELPERS = ["Wren", "Juno", "Otis", "Mara", "Ezra", "Iris"];
  const QUESTIONS = [
    { q: "Who’s this for, or what is it about?", hint: "A name and a few words is plenty.", example: "Juniper, our 4-year-old border collie" },
    { q: "What do you want off your mind?", hint: "The things you keep forgetting or putting off.", example: "Vet visits and meds, ordering food, finding a sitter when we travel" },
  ];
  const taken = new Set((window.__existingHelpers || []).map((h) => h.toLowerCase()));
  const s = {
    step: "name", name: "", colour: COLOURS[2][1], helper: HELPERS.find((h) => !taken.has(h.toLowerCase())) || "Wren",
    sealed: false, qi: 0, answers: [], draft: "", touched: false, error: "",
  };
  const root = document.getElementById("root");

  function steps() {
    const idx = s.step === "name" ? 0 : s.step === "talk" ? 1 : 2;
    const labels = ["Name", `Tell ${s.helper.trim() || "your helper"}`, "First board"];
    return el("ol", { class: "t-row", style: { gap: "24px", listStyle: "none", margin: 0, padding: "0 0 12px", borderBottom: "1px solid var(--line)", fontSize: "13px" } },
      labels.map((label, i) => el("li", { class: "t-row", style: { gap: "8px", fontWeight: i === idx ? 650 : 400, color: i <= idx ? "var(--ink)" : "var(--faint)" } },
        el("span", { class: "tabular", style: { width: "20px", height: "20px", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "11px", fontWeight: 650, background: i <= idx ? s.colour : "#ededE9", color: i <= idx ? "#fff" : "var(--muted)" } }, i < idx ? "✓" : String(i + 1)),
        label)));
  }

  function nameStep() {
    const nameError = s.touched && !s.name.trim() ? "Give it a name, even a rough one." : "";
    const name = el("input", { class: "display", value: s.name, placeholder: "Name it", "aria-label": "Topic name", style: { marginTop: "8px", fontSize: "80px", lineHeight: 1, borderBottom: `2px solid ${nameError ? "var(--bad)" : s.colour}`, paddingBottom: "8px" } });
    name.addEventListener("input", () => { s.name = name.value; });
    name.addEventListener("blur", () => { s.touched = true; });
    const helperInput = el("input", { class: "display", value: s.helper, "aria-label": "Helper name", style: { marginTop: "8px", fontSize: "28px" } });
    helperInput.addEventListener("input", () => { s.helper = helperInput.value; });
    const form = el("form", { class: "rise", style: { marginTop: "40px" } },
      el("p", { class: "eyebrow muted" }, "New topic"),
      name,
      el("p", { style: { marginTop: "8px", fontSize: "13.5px", color: nameError ? "var(--bad)" : "var(--muted)" } }, nameError || "A part of your life: Pets, Car, Moving, Kids’ school…"),
      el("div", { style: { marginTop: "40px", display: "grid", gap: "40px", gridTemplateColumns: "1fr 1fr" } },
        el("div", { class: "tp-card", role: "radiogroup", "aria-label": "Colour" },
          el("p", { class: "eyebrow", style: { margin: "0 0 12px" } }, "Colour"),
          el("div", { class: "t-row", style: { gap: "8px", flexWrap: "wrap" } }, COLOURS.map(([label, hex]) =>
            el("button", { type: "button", "aria-label": label, "aria-pressed": String(s.colour === hex), onclick: () => { s.colour = hex; render(); },
              style: { width: "40px", height: "40px", background: hex, boxShadow: s.colour === hex ? "0 0 0 2px #fff, 0 0 0 4px #0F0F0E" : "none" } })))),
        el("div", { class: "tp-card", style: { borderTopWidth: "2px" } },
          el("label", { class: "eyebrow" }, "Its helper is called"),
          helperInput,
          el("p", { class: "t-small muted", style: { marginTop: "6px" } }, "Same helper every time you come back. You can rename it later."))),
      el("div", { class: "tp-card", style: { marginTop: "40px" } },
        el("label", { class: "t-row", style: { gap: "16px", alignItems: "flex-start", cursor: "pointer" } },
          el("input", { type: "checkbox", checked: s.sealed, onchange: (e) => { s.sealed = e.target.checked; render(); }, style: { width: "18px", height: "18px" } }),
          el("span", {},
            el("span", { style: { fontSize: "16px", fontWeight: 650 } }, "🔒 Private topic"),
            el("span", { style: { display: "block", marginTop: "4px", maxWidth: "56ch", fontSize: "14px", color: "var(--ink-2)" } },
              s.sealed
                ? `Sealed. Nothing from ${s.name.trim() || "this topic"} shows on Home, in other topics or in notifications. Its time shows only as “Busy”.`
                : `${s.name.trim() || "This topic"}’s scheduled items show on Home as short labels, like “${s.name.trim() || "Pets"}: vet, Thu”.`)))),
      el("button", { class: "t-button t-primary", type: "submit", style: { marginTop: "40px", height: "48px", padding: "0 24px", fontSize: "15px" } }, `Next: tell ${s.helper.trim() || "your helper"} about it →`));
    form.addEventListener("submit", (e) => {
      e.preventDefault();
      s.touched = true;
      if (!s.name.trim()) return render();
      if (!s.helper.trim()) s.helper = "Wren";
      s.step = "talk";
      render();
    });
    return form;
  }

  function talkStep() {
    const helper = s.helper.trim();
    const items = QUESTIONS.slice(0, s.qi + 1).map((q, i) => {
      if (s.answers[i]) {
        return el("li", { class: "rise" }, el("p", { class: "display", style: { margin: 0, fontSize: "44px", lineHeight: 1.1 } }, q.q),
          el("p", { style: { marginTop: "8px", borderLeft: `3px solid ${s.colour}`, paddingLeft: "12px", fontSize: "17px", color: "var(--ink-2)" } }, s.answers[i]));
      }
      const input = el("input", { value: s.draft, placeholder: q.hint, "aria-label": q.q, style: { fontSize: "18px", border: 0, padding: "8px 0" } });
      input.addEventListener("input", () => { s.draft = input.value; });
      const form = el("form", { style: { marginTop: "16px" } },
        el("div", { class: "t-row", style: { gap: "12px", borderBottom: "2px solid var(--ink)", paddingBottom: "4px" } }, input,
          el("button", { type: "submit", class: "tp-send", style: { background: "var(--ink)", color: "#fff" }, "aria-label": "Answer" }, "↑")),
        el("button", { type: "button", class: "t-small muted", style: { marginTop: "8px", textDecoration: "underline", textDecorationColor: "#c9c9c3", textUnderlineOffset: "3px" }, onclick: () => { s.draft = q.example; render(); } }, `e.g. “${q.example}”`));
      form.addEventListener("submit", (e) => {
        e.preventDefault();
        if (!s.draft.trim()) return;
        s.answers.push(s.draft.trim());
        s.draft = "";
        if (s.qi + 1 < QUESTIONS.length) { s.qi += 1; render(); }
        else create();
      });
      setTimeout(() => input.focus(), 0);
      return el("li", { class: "rise" }, el("p", { class: "display", style: { margin: 0, fontSize: "44px", lineHeight: 1.1 } }, q.q), form);
    });
    return el("div", { class: "rise", style: { marginTop: "40px" } },
      el("p", { class: "eyebrow", style: { color: s.colour } }, `${helper} · ${s.name.trim()}`),
      el("ol", { style: { listStyle: "none", padding: 0, margin: "16px 0 0", display: "flex", flexDirection: "column", gap: "32px" } }, items),
      s.error ? el("p", { style: { color: "var(--bad)", marginTop: "24px" } }, s.error) : null,
      el("button", { type: "button", class: "t-small muted", style: { marginTop: "40px" }, onclick: () => { s.step = "name"; s.qi = 0; s.answers = []; render(); } }, "← Back"));
  }

  async function create() {
    s.step = "creating";
    render();
    try {
      await call("newtopic.create", { name: s.name.trim(), colour: s.colour, helper: s.helper.trim(), sealed: s.sealed, answers: QUESTIONS.map((q, i) => ({ q: q.q, a: s.answers[i] })) });
    } catch (e) {
      s.error = String((e && e.message) || e);
      s.step = "talk";
      s.qi = 0;
      s.answers = [];
      render();
    }
  }

  function render() {
    root.replaceChildren(el("div", { class: "tp-page", style: { maxWidth: "880px" } }, steps(),
      s.step === "name" ? nameStep()
        : s.step === "talk" ? talkStep()
        : el("p", { class: "t-helper-note rise", style: { marginTop: "64px", fontSize: "17px", color: s.colour } }, `${s.helper.trim()} is getting ready…`)));
  }
  render();
})();
