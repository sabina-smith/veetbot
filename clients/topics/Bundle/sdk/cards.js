// Built-in cards. Each renders the rows of `items` whose `card` is the
// card's id, so a helper can add a whole card with one line in board.json
// and a few INSERTs. Custom cards (TypeScript modules) are for anything
// these don't cover.
(() => {
  "use strict";

  const rows = (t, order = "position IS NULL, position, id") =>
    t.db.query(`SELECT * FROM items WHERE card = ? ORDER BY ${order}`, [t.module.id]);
  const add = (t, fields) => {
    const keys = Object.keys(fields);
    return t.db.exec(
      `INSERT INTO items (card, ${keys.join(", ")}) VALUES (?, ${keys.map(() => "?").join(", ")})`,
      [t.module.id, ...keys.map((k) => fields[k])],
    );
  };
  const set = (t, id, fields) => {
    const keys = Object.keys(fields);
    return t.db.exec(`UPDATE items SET ${keys.map((k) => `${k} = ?`).join(", ")} WHERE id = ?`, [...keys.map((k) => fields[k]), id]);
  };
  const dataOf = (row) => { try { return JSON.parse(row.data || "{}") || {}; } catch { return {}; } };
  const proposalButton = (t, p) => t.ui.needsButton(
    p.options.length > 1 ? `${p.options.length} options${(() => { const ps = p.options.map((o) => o.price).filter((x) => typeof x === "number"); return ps.length ? ` from ${t.money(Math.min(...ps))}` : ""; })()}` : p.kind === "question" ? `${t.topic.agentName} has a question` : "Your call",
    () => t.proposals.open(p.id));

  // ---------- list: to-dos, errands, checklists ----------
  async function list(root, t) {
    const { ui } = t;
    const helper = t.topic.agentName;
    const items = await rows(t, "done, due_on IS NULL, due_on, position IS NULL, position, id");
    const proposals = await t.proposals.byRef();
    const today = t.today();
    t.card.meta(`${items.filter((i) => !i.done).length} left`);
    root.append(
      items.length ? ui.stack(items.slice(0, 15).map((i) => {
        const p = proposals[`items/${i.id}`];
        const late = !i.done && i.due_on && i.due_on <= today;
        const looking = i.assignee === "agent" && !i.done && !p;
        return ui.item([ui.row([
          ui.checkbox(!!i.done, (checked) => set(t, i.id, { done: checked ? 1 : 0 })),
          ui.stack([
            ui.el("span", { style: { fontSize: "14.5px", textDecoration: i.done ? "line-through" : "none", color: i.done ? "var(--faint)" : "inherit" } }, i.title),
            i.detail && !i.done ? ui.text(i.detail, { small: true, muted: true, clamp: true }) : null,
            p ? ui.row([proposalButton(t, p)]) : null,
            ui.row([
              i.due_on ? ui.el("span", { style: { fontSize: "12.5px", fontWeight: late ? "650" : "400", color: late ? "var(--attention-text)" : "var(--muted)" } }, i.due_on === today ? "Today" : t.formatDate(i.due_on)) : null,
              looking ? ui.el("span", { style: { fontSize: "12.5px", fontWeight: "600", color: "var(--topic)" } }, `${helper} is on it`) : null,
              !i.done && i.assignee === "me" ? ui.textButton(`Ask ${helper}`, async () => {
                await set(t, i.id, { assignee: "agent" });
                await t.agent.assign(`"${i.title}" on the ${t.module.title} card`, `items/${i.id}`);
              }, { helper: true }) : null,
            ], { gap: 12, wrap: true, align: "baseline" }),
          ], { gap: 2 }),
        ], { align: "flex-start", gap: 12 })], { needs: !!p, looking });
      }), { gap: 0 }) : ui.empty("Nothing yet."),
      ui.inlineAdd("Add", (title) => add(t, { title })),
    );
  }

  // ---------- table: people, inventories, anything with columns ----------
  async function table(root, t) {
    const { ui } = t;
    const columns = (t.module.columns && t.module.columns.length) ? t.module.columns : [{ key: "title", label: "Name" }, { key: "detail", label: "Notes" }];
    const items = await rows(t);
    const proposals = await t.proposals.byRef();
    t.card.meta(`${items.length}`);
    const value = (row, key) => (key in row && key !== "data" ? row[key] : dataOf(row)[key]) ?? "";
    root.append(
      ui.table(columns.map((c, ci) => ({
        label: c.label,
        render: (row) => {
          const p = ci === 0 ? proposals[`items/${row.id}`] : null;
          return ci === 0
            ? ui.stack([ui.el("span", { style: { fontWeight: "550" } }, String(value(row, c.key))), p ? ui.row([proposalButton(t, p)]) : null], { gap: 4 })
            : ui.el("span", { class: ci === 1 ? "" : "muted", style: { fontSize: "13.5px" } }, String(value(row, c.key)));
        },
      })), items, { empty: "Nothing yet." }),
      ui.inlineAdd("Add", (title) => add(t, { title })),
    );
  }

  // ---------- recurring: things that come around ----------
  async function recurring(root, t) {
    const { ui } = t;
    const helper = t.topic.agentName;
    const DAY = 86400000;
    const now = new Date(`${t.today()}T12:00:00`).getTime();
    const items = await rows(t);
    const proposals = await t.proposals.byRef();
    t.card.meta("Things that come around");
    const shaped = items.map((i) => {
      const every = Math.max(1, i.every_days || 30);
      const last = i.last_done ? new Date(`${i.last_done}T12:00:00`).getTime() : now - every * DAY;
      return { i, progress: (now - last) / (every * DAY), left: Math.round((last + every * DAY - now) / DAY) };
    }).sort((a, b) => b.progress - a.progress);
    root.append(
      shaped.length ? ui.stack(shaped.map(({ i, progress, left }) => {
        const p = proposals[`items/${i.id}`];
        const overdue = left < 0;
        const looking = i.assignee === "agent" && !p;
        return ui.item([
          ui.row([ui.el("span", { style: { fontSize: "15px", fontWeight: "550" } }, i.title), ui.spacer(),
            ui.el("span", { class: "tabular", style: { fontSize: "13px", fontWeight: overdue ? "650" : "400", color: overdue ? "var(--attention-text)" : "var(--ink-2)" } },
              overdue ? "Overdue" : left === 0 ? "Today" : `In ${left} day${left === 1 ? "" : "s"}`)], { align: "baseline" }),
          ui.el("div", { style: { marginTop: "6px" } }, ui.progress(Math.min(progress, 1), { color: overdue ? "var(--attention)" : progress > 0.85 ? "var(--topic)" : "var(--ink)" })),
          i.detail ? ui.text(i.detail, { small: true, muted: true, clamp: true }) : null,
          looking ? ui.helperNote(`${helper} is on it`) : null,
          ui.row([
            p ? proposalButton(t, p) : null,
            ui.textButton("Done today", () => set(t, i.id, { last_done: t.today(), assignee: "me" })),
            !looking && !p ? ui.textButton(`Ask ${helper}`, async () => {
              await set(t, i.id, { assignee: "agent" });
              await t.agent.assign(`"${i.title}" on the ${t.module.title} card`, `items/${i.id}`);
            }, { helper: true }) : null,
          ], { gap: 16, wrap: true }),
        ], { needs: !!p || overdue, looking });
      }), { gap: 0 }) : ui.empty("Nothing yet."),
      ui.inlineAdd("Add something that comes around", (title) => add(t, { title, every_days: 30, last_done: t.today() })),
    );
  }

  // ---------- shopping: needed → looking → in cart → ordered → arrived ----------
  async function shopping(root, t) {
    const { ui } = t;
    const helper = t.topic.agentName;
    const LABEL = { needed: "Needed", researching: "Looking", in_cart: "In cart", ordered: "Ordered", arrived: "Arrived" };
    const items = await rows(t, "status = 'arrived', id DESC");
    const proposals = await t.proposals.byRef();
    t.card.meta(`${items.filter((i) => i.status !== "arrived").length} open`);
    root.append(
      items.length ? ui.stack(items.slice(0, 15).map((i) => {
        const status = i.status || "needed";
        const p = proposals[`items/${i.id}`];
        const looking = status === "researching" && !p;
        return ui.item([ui.row([
          ui.stack([
            ui.row([ui.el("span", { style: { fontSize: "15px", fontWeight: "550", textDecoration: status === "arrived" ? "line-through" : "none" } }, i.title),
              i.qty ? ui.el("span", { class: "faint tabular", style: { fontSize: "13px" } }, i.qty) : null], { gap: 8, align: "baseline" }),
            p ? ui.row([proposalButton(t, p)]) : looking ? ui.helperNote(`${helper} is looking`)
              : i.source ? ui.row([ui.el("span", { class: "muted", style: { fontSize: "13px" } }, i.source),
                  i.price != null ? ui.el("span", { class: "tabular", style: { fontSize: "13px" } }, t.money(i.price)) : null,
                  i.url ? ui.link((i.url.replace(/^https?:\/\/(www\.)?/, "").split("/")[0]), i.url) : null], { gap: 8, wrap: true, align: "baseline" })
              : null,
          ], { gap: 3 }),
          ui.spacer(),
          ui.stack([
            ui.badge(p ? "Your call" : LABEL[status] || status, p ? "attention" : "neutral"),
            status === "needed" ? ui.textButton(`${helper}, find it`, async () => {
              await set(t, i.id, { status: "researching" });
              await t.agent.assign(`Find "${i.title}"${i.qty ? ` (${i.qty})` : ""} and bring back options as a proposal on its row.`, `items/${i.id}`);
            }, { helper: true }) : null,
            status === "in_cart" && i.url ? ui.textButton("Buy…", async () => {
              const ok = await t.confirm({ title: `Open checkout at ${i.source || "the store"}?`, rows: [["Item", i.title], ["Price", i.price != null ? t.money(i.price) : "–"]], explainer: `You pay on their site. ${helper} won't buy anything on its own.`, confirm: "Open checkout" });
              if (!ok) return;
              await t.openLink(i.url);
              await set(t, i.id, { status: "ordered" });
            }) : null,
            status === "ordered" ? ui.textButton("Mark arrived", () => set(t, i.id, { status: "arrived" })) : null,
          ], { gap: 4 }),
        ], { align: "flex-start", gap: 16 })], { needs: !!p, looking });
      }), { gap: 0 }) : ui.empty("Nothing to buy."),
      ui.inlineAdd("Add something to buy", (title) => add(t, { title, status: "needed" })),
    );
  }

  // ---------- notes: what the helper and owner know about this topic ----------
  async function notes(root, t) {
    const { ui } = t;
    const items = await rows(t);
    t.card.meta("");
    root.append(
      items.length ? ui.stack(items.map((i) => ui.item([
        ui.el("p", { style: { margin: 0, fontSize: "15px", fontWeight: i.detail ? "600" : "400", lineHeight: "1.4" } }, i.title),
        i.detail ? ui.text(i.detail, { small: true, muted: true }) : null,
      ])), { gap: 0 }) : ui.empty("Nothing yet."),
      ui.inlineAdd("Add a note", (title) => add(t, { title })),
    );
  }

  // ---------- schedule: this topic's time on the shared plane ----------
  async function schedule(root, t) {
    const { ui } = t;
    const entries = (await t.schedule.list(30)).filter((e) => e.isOwn && new Date(e.start) >= new Date(Date.now() - 86400000));
    t.card.meta(`Next 30 days`);
    const when = (iso) => new Date(iso).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
    const dateInput = ui.el("input", { type: "datetime-local", style: { width: "190px", fontSize: "13px" } });
    const form = ui.inlineAdd("Add a time", async (label) => {
      if (!dateInput.value) return t.toast("Pick a date and time first.");
      await t.schedule.add({ kind: "block", start: dateInput.value, label });
      dateInput.value = "";
      t.refresh();
    }, { button: "Add" });
    form.insertBefore(dateInput, form.lastChild);
    root.append(
      entries.length ? ui.stack(entries.slice(0, 10).map((e) => ui.item([ui.row([
        ui.el("span", { style: { fontSize: "14.5px", fontWeight: "550" } }, e.label), ui.spacer(),
        ui.el("span", { class: "muted tabular", style: { fontSize: "13px" } }, when(e.start)),
        ui.textButton("Remove", async () => { await t.schedule.remove(e.id); t.refresh(); }),
      ], { gap: 12, align: "baseline" })])), { gap: 0 }) : ui.empty("Nothing scheduled."),
      form,
    );
  }

  window.__cards = { list, table, recurring, shopping, notes, schedule };
})();
