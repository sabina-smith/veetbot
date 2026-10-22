// Home: what needs the owner across topics, and the shared week, by label.
// Data comes from the app as window.__home.
(() => {
  "use strict";
  const call = (op, args = {}) => window.webkit.messageHandlers.topics.postMessage({ op, args });
  const { el } = window.Topics;
  let data = window.__home;
  let view = "week";
  const hidden = new Set();
  let focus = null;
  const root = document.getElementById("root");
  const START = 7, END = 21, HOURS = [8, 10, 12, 14, 16, 18, 20];
  const pct = (h) => ((h - START) / (END - START)) * 100;
  const fmt = (h) => {
    const hh = Math.floor(h), m = Math.round((h - hh) * 60), h12 = hh % 12 === 0 ? 12 : hh % 12;
    return `${h12}${m ? `:${String(m).padStart(2, "0")}` : ""}${hh >= 12 ? "p" : "a"}`;
  };
  const money = (n) => `$${Number(n).toLocaleString("en-US", { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
  const topicOf = (id) => data.topics.find((t) => t.id === id);

  function needsCard(a) {
    const p = a.proposal;
    const rec = p.recommended !== null && p.recommended !== undefined ? p.options[p.recommended] : null;
    const detail = p.summary || (p.options.length ? `${p.options.length} options` : "");
    const primaryText = rec
      ? `Take ${a.helper}’s pick${typeof rec.price === "number" ? ` · ${money(rec.price)}` : ""}`
      : p.options.length === 1 ? `Approve${typeof p.options[0].price === "number" ? ` · ${money(p.options[0].price)}` : ""}` : "Open";
    const primary = el("button", { class: "t-button t-primary", type: "button" }, primaryText);
    primary.addEventListener("click", async () => {
      primary.disabled = true;
      if (rec || p.options.length === 1) await call("home.accept", { topicId: a.topicId, id: p.id, option: rec ? p.recommended : 0 });
      else await call("home.compare", { topicId: a.topicId, id: p.id });
    });
    return el("li", { class: "t-item t-needs-tab rise", style: { padding: "16px 0" } },
      el("div", { class: "t-row", style: { gap: "8px", alignItems: "baseline", fontSize: "12.5px" } },
        el("b", { style: { color: a.tint, fontWeight: 650 } }, a.name),
        el("span", { class: "faint" }, `from ${a.helper}`),
        p.kind === "purchase" ? el("span", { class: "eyebrow", style: { marginLeft: "auto" } }, "Needs your OK") : null),
      el("p", { class: "display", style: { margin: "4px 0 0", fontSize: "21px", lineHeight: 1.2 } }, p.title),
      detail ? el("p", { style: { margin: "4px 0 0", fontSize: "14px", color: "var(--ink-2)" } }, detail) : null,
      el("div", { class: "t-row", style: { gap: "8px", marginTop: "12px", flexWrap: "wrap" } },
        primary,
        el("button", { class: "t-button", type: "button", onclick: () => call("home.compare", { topicId: a.topicId, id: p.id }) }, p.options.length > 1 ? "Compare" : "Open")));
  }

  function render() {
    const asks = data.asks;
    const days = view === "week" ? data.days : data.days.slice(0, 1);
    const slots = data.slots.filter((s) => !hidden.has(s.topicId ?? "") && s.day < days.length);
    const now = data.nowHour;
    root.replaceChildren(el("div", { class: "tp-page", style: { paddingBottom: "80px" } },
      el("header", {},
        el("p", { class: "eyebrow muted" }, data.date),
        el("h1", { class: "display tp-title", style: { fontSize: "64px" } }, "At a glance")),
      el("div", { style: { marginTop: "40px", display: "grid", gap: "40px 48px", gridTemplateColumns: "minmax(0,5fr) minmax(0,7fr)" } },
        el("section", { class: "tp-card", style: { borderTopWidth: "1px" } },
          el("h2", { class: "eyebrow t-row", style: { margin: 0, justifyContent: "space-between" } }, "Needs you", el("span", { class: "muted tabular" }, String(asks.length))),
          asks.length
            ? el("ol", { class: "t-list", style: { marginTop: "8px", paddingLeft: "14px", marginLeft: "-14px" } }, asks.map(needsCard))
            : el("p", { class: "muted", style: { padding: "40px 0" } }, "All clear. Anything new from your helpers lands here."),
          null),
        el("section", { class: "tp-card", style: { borderTopWidth: "1px" } },
          el("div", { class: "t-row", style: { alignItems: "baseline", gap: "16px" } },
            el("h2", { class: "eyebrow", style: { margin: 0, flex: 1 } }, "Coming up"),
            ["today", "week"].map((v) => el("button", {
              type: "button", onclick: () => { view = v; render(); },
              style: { fontSize: "13px", fontWeight: view === v ? 650 : 400, textDecoration: view === v ? "underline" : "none", textUnderlineOffset: "5px", color: view === v ? "var(--ink)" : "var(--muted)" },
            }, v === "week" ? "This week" : "Today"))),
          el("div", { class: "t-row", style: { gap: "16px", marginTop: "12px", flexWrap: "wrap" } }, data.topics.map((t) => {
            const key = t.id;
            const off = hidden.has(key);
            return el("button", { type: "button", onclick: () => { off ? hidden.delete(key) : hidden.add(key); render(); }, style: { display: "inline-flex", alignItems: "center", gap: "6px", fontSize: "13px", color: off ? "#b3b3ad" : "var(--ink)", textDecoration: off ? "line-through" : "none" } },
              el("span", { style: { width: "10px", height: "10px", background: off ? "#d6d6d0" : t.tint } }),
              t.name);
          })),
          el("div", { style: { marginTop: "16px", display: "grid", gridTemplateColumns: `40px repeat(${days.length}, minmax(0,1fr))` } },
            el("div"),
            days.map((d) => el("div", { style: { borderBottom: "1px solid var(--ink)", padding: "0 0 8px 8px" } },
              el("span", { style: { fontSize: "12px", fontWeight: d.today ? 650 : 400, color: d.today ? "var(--ink)" : "var(--muted)" } }, d.short),
              el("span", { class: "display tabular", style: { marginLeft: "6px", fontSize: "20px", color: d.today ? "var(--ink)" : "var(--muted)" } }, d.date))),
            el("div", { style: { position: "relative", height: "500px" } }, HOURS.map((h) =>
              el("span", { class: "tabular faint", style: { position: "absolute", right: "8px", top: `${pct(h)}%`, transform: "translateY(-50%)", fontSize: "11px" } }, fmt(h)))),
            days.map((d, di) => el("div", { style: { position: "relative", height: "500px", borderLeft: "1px solid #efefeb" } },
              HOURS.map((h) => el("div", { style: { position: "absolute", left: 0, right: 0, top: `${pct(h)}%`, borderTop: "1px solid #f3f3f0" } })),
              d.today && now >= START && now <= END ? el("div", { style: { position: "absolute", left: 0, right: 0, top: `${pct(now)}%`, height: "2px", background: "var(--attention)", zIndex: 1 } }) : null,
              slots.filter((s) => s.day === di).map((s) => {
                const t = s.topicId ? topicOf(s.topicId) : null;
                const priv = !t;
                const sel = focus && focus.id === s.id;
                const start = Math.max(START, Math.min(END - 0.5, s.start));
                return el("button", {
                  type: "button", onclick: () => { focus = sel ? null : s; render(); },
                  style: {
                    position: "absolute", left: "4px", right: "4px", top: `${pct(start)}%`, height: `${(Math.max(s.len, 0.75) / (END - START)) * 100}%`,
                    display: "flex", flexDirection: "column", overflow: "hidden", padding: "4px 6px", fontSize: "12px", lineHeight: 1.2, textAlign: "left",
                    background: priv ? "repeating-linear-gradient(135deg,#F1F1EF 0 5px,#E4E4E0 5px 10px)" : sel ? t.tint : s.kind === "block" ? t.soft : "#fff",
                    borderLeft: `3px solid ${priv ? "#9A9A94" : t.tint}`, outline: !priv && s.kind !== "block" && !sel ? `1px solid ${t.soft}` : "none",
                    color: sel && !priv ? "#fff" : "var(--ink)",
                  },
                }, el("span", { style: { fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" } }, s.label),
                  !priv && s.len >= 1 ? el("span", { style: { fontSize: "11px", opacity: 0.7 } }, `${s.kind === "task" ? "due " : s.kind === "reminder" ? "reminder " : ""}${fmt(s.start)}`) : null);
              })))),
          el("div", { style: { marginTop: "12px", minHeight: "44px", borderTop: "1px solid var(--line)", paddingTop: "12px", fontSize: "13.5px" } },
            !focus ? el("p", { class: "muted", style: { margin: 0 } }, "Home shows labels only. Tap one to open it in its topic.")
              : !focus.topicId ? el("p", { style: { margin: 0, color: "var(--ink-2)" } }, `${focus.label}, ${data.days[focus.day].short} ${fmt(focus.start)}`)
              : el("p", { class: "t-row rise", style: { margin: 0, gap: "12px", flexWrap: "wrap" } },
                  el("b", { style: { color: topicOf(focus.topicId).tint } }, topicOf(focus.topicId).name),
                  el("span", {}, `${focus.label}, ${data.days[focus.day].short} ${fmt(focus.start)}`),
                  el("button", { type: "button", class: "t-textbutton", onclick: () => call("home.openTopic", { topicId: focus.topicId }) }, `Open in ${topicOf(focus.topicId).name} →`)))))));
  }

  window.__homeData = (next) => { data = next; render(); };
  render();
})();
