// The month's bills: what's due, what changed, what nobody uses. Paying
// or cancelling always waits for the owner's OK.

interface Bill { id: number; name: string; due_on: string | null; amount: number; status: string; note: string | null }

const STATUS: Record<string, string> = { autopay: "Autopay", due: "Due", paid: "Paid", flag: "Worth a look", cancelled: "Cancelling" };

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const helper = t.topic.agentName;
  const bills = await db.query<Bill>("SELECT * FROM bills ORDER BY status = 'paid', due_on");
  const proposals = await t.proposals.byRef();
  const today = t.today();
  const total = bills.filter((b) => b.status !== "cancelled").reduce((s, b) => s + b.amount, 0);
  t.card.meta(`${t.money(Math.round(total))} this month`);

  const head = ui.el("div", { class: "eyebrow faint", style: { display: "grid", gridTemplateColumns: "minmax(0,1fr) 64px 84px 104px", gap: "12px", padding: "6px 0" } },
    ui.el("span", {}, "Bill"), ui.el("span", {}, "Due"), ui.el("span", { style: { textAlign: "right" } }, "Amount"), ui.el("span", { style: { textAlign: "right" } }, "Status"));

  const row = (b: Bill) => {
    const p = proposals[`bills/${b.id}`];
    const dueToday = b.status === "due" && b.due_on !== null && b.due_on <= today;
    const status = p ? "Your call" : STATUS[b.status] ?? b.status;
    const tone = p || b.status === "due" ? "var(--attention-text)" : b.status === "flag" ? "var(--topic)" : "var(--faint)";
    return ui.item([ui.el("div", { style: { display: "grid", gridTemplateColumns: "minmax(0,1fr) 64px 84px 104px", gap: "12px", alignItems: "start" } },
      ui.stack([
        ui.el("span", { style: { fontSize: "15px", fontWeight: "550", textDecoration: b.status === "cancelled" ? "line-through" : "none", color: b.status === "cancelled" ? "var(--faint)" : "inherit" } }, b.name),
        b.note ? ui.text(b.note, { small: true, tone: b.status === "flag" ? "accent" : undefined, muted: b.status !== "flag" }) : null,
        p ? ui.row([ui.needsButton(p.options.length > 1 ? `${p.options.length} options, from ${t.money(Math.min(...p.options.map((o) => o.price ?? Infinity)))}` : "Take a look", () => t.proposals.open(p.id))]) : null,
        b.status === "flag" ? ui.row([
          ui.textButton("Cancel it…", async () => {
            const ok = await t.confirm({ title: `Cancel ${b.name}?`, rows: [["Saves", `${t.money(b.amount)} a month`]], explainer: `${helper} will cancel it with you; nothing is cancelled until you confirm on their site.`, confirm: "Start cancelling" });
            if (ok) await db.exec("UPDATE bills SET status = 'cancelled' WHERE id = ?", [b.id]);
          }),
          ui.textButton("Keep it", () => db.exec("UPDATE bills SET status = 'autopay', note = NULL WHERE id = ?", [b.id])),
        ], { gap: 16 }) : null,
      ], { gap: 3 }),
      ui.el("span", { class: "tabular", style: { fontSize: "14px", fontWeight: dueToday ? "650" : "400", color: dueToday ? "var(--attention-text)" : "var(--ink-2)" } },
        b.due_on === today ? "Today" : b.due_on ? t.formatDate(b.due_on, { month: "short", day: "numeric" }) : "–"),
      ui.el("span", { class: "display tabular", style: { fontSize: "17px", textAlign: "right" } }, t.money(b.amount)),
      ui.stack([
        ui.el("span", { class: "eyebrow", style: { color: tone, textAlign: "right" } }, status),
        b.status === "due" && !p ? ui.textButton("Pay…", async () => {
          const ok = await t.confirm({ title: `Mark ${b.name} as paid?`, rows: [["Amount", t.money(b.amount)], ["Due", b.due_on ?? "–"]], explainer: "Pay it the way you usually do; this just records it.", confirm: "Mark paid" });
          if (ok) await db.exec("UPDATE bills SET status = 'paid' WHERE id = ?", [b.id]);
        }) : null,
      ], { gap: 4 }),
    )], { needs: !!p || dueToday });
  };

  root.append(head, ui.stack(bills.map(row), { gap: 0 }));
}
