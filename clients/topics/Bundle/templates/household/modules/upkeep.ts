// Things that come around: how far through each interval we are, and who
// can do the work when it's due.

interface Upkeep { id: number; task: string; every: string; every_days: number; last_done: string | null; status: string; note: string | null }

const DAY = 86_400_000;

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const helper = t.topic.agentName;
  const items = await db.query<Upkeep>("SELECT * FROM upkeep");
  const proposals = await t.proposals.byRef();
  const now = new Date(`${t.today()}T12:00:00`).getTime();
  t.card.meta("Things that come around");

  const withProgress = items.map((u) => {
    const last = u.last_done ? new Date(`${u.last_done}T12:00:00`).getTime() : now - u.every_days * DAY;
    const progress = (now - last) / (u.every_days * DAY);
    const daysLeft = Math.round((last + u.every_days * DAY - now) / DAY);
    return { u, progress, daysLeft };
  }).sort((a, b) => b.progress - a.progress);

  root.append(ui.stack(withProgress.map(({ u, progress, daysLeft }) => {
    const p = proposals[`upkeep/${u.id}`];
    const overdue = daysLeft < 0;
    const looking = u.status === "looking" && !p;
    const next = overdue ? "Overdue" : daysLeft === 0 ? "Today" : daysLeft < 31 ? `In ${daysLeft} day${daysLeft === 1 ? "" : "s"}` : t.formatDate(new Date(now + daysLeft * DAY).toISOString().slice(0, 10), { month: "short", year: "numeric" });
    const color = overdue ? "var(--attention)" : u.status === "booked" || progress < 0.85 ? "var(--ink)" : "var(--topic)";
    return ui.item([
      ui.row([ui.el("span", { style: { fontSize: "15px", fontWeight: "550" } }, u.task), ui.spacer(),
        ui.el("span", { class: "tabular", style: { fontSize: "13px", fontWeight: overdue ? "650" : "400", color: overdue ? "var(--attention-text)" : "var(--ink-2)" } }, next)], { align: "baseline" }),
      ui.el("div", { style: { marginTop: "6px" } }, ui.progress(Math.min(progress, 1), { color })),
      ui.text(`${u.every} · last ${u.last_done ? t.formatDate(u.last_done, { month: "short", year: "numeric" }) : "never"}`, { small: true, muted: true }),
      u.note ? ui.text(u.note, { small: true, tone: u.status === "booked" ? "ink" : "accent" }) : null,
      looking ? ui.helperNote(`${helper} is getting quotes`) : null,
      ui.row([
        p ? ui.needsButton(p.options.length > 1 ? `${p.options.length} quotes` : "Take a look", () => t.proposals.open(p.id)) : null,
        ui.textButton("Done today", async () => {
          const before = u.last_done;
          await db.exec("UPDATE upkeep SET last_done = ?, status = 'ok', note = NULL WHERE id = ?", [t.today(), u.id]);
          t.toast(`${u.task}: marked done.`, { undo: () => db.exec("UPDATE upkeep SET last_done = ? WHERE id = ?", [before, u.id]) });
        }),
        !looking && !p && u.status !== "booked" && progress > 0.8 ? ui.textButton(`${helper}, find someone`, async () => {
          await db.exec("UPDATE upkeep SET status = 'looking' WHERE id = ?", [u.id]);
          await t.agent.assign(`Upkeep #${u.id}: find someone for "${u.task}" and bring back quotes as a proposal on its row.`, `upkeep/${u.id}`);
        }, { helper: true }) : null,
      ], { gap: 16, wrap: true }),
    ], { needs: !!p || overdue, looking });
  }), { gap: 0 }));
}
