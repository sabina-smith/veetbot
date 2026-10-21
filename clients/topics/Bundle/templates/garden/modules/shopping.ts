// Things to buy for the garden, moving from needed to arrived. The agent
// can research an item (what to get, where, roughly what it costs); it
// never buys without the owner approving that exact purchase.

interface Item { id: number; item: string; qty: string | null; status: string; source: string | null; url: string | null; price: number | null; task_id: number | null; notes: string | null; added_by: string }

const FLOW = ["needed", "researching", "in_cart", "ordered", "arrived"];
const LABEL: Record<string, string> = { needed: "needed", researching: "researching", in_cart: "in cart", ordered: "ordered", arrived: "arrived" };
const TONE: Record<string, Tone> = { needed: "neutral", researching: "accent", in_cart: "warn", ordered: "accent", arrived: "good" };

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const agentName = t.topic.agentName;
  const items = await db.query<Item>(
    "SELECT * FROM shopping ORDER BY CASE status WHEN 'arrived' THEN 1 ELSE 0 END, id",
  );
  const proposals = await t.proposals.byRef();
  const active = items.filter((i) => i.status !== "arrived");
  const total = active.reduce((sum, i) => sum + (i.price ?? 0), 0);

  const next = (status: string) => FLOW[Math.min(FLOW.indexOf(status) + 1, FLOW.length - 1)];

  root.append(
    ui.row([
      ui.stat("to get", active.length),
      ui.stat("priced so far", total ? `$${total.toFixed(2)}` : "–"),
      ui.spacer(),
      ui.text(`${agentName} never buys anything without your OK.`, { muted: true, small: true }),
    ], { gap: 6 }),
    ui.table<Item>(
      [
        {
          label: "Item",
          render: (i) => {
            const proposal = proposals[`shopping/${i.id}`];
            return ui.stack([
              ui.text(`${i.item}${i.qty ? ` · ${i.qty}` : ""}`, { strong: i.status !== "arrived" }),
              i.notes ? ui.text(i.notes, { muted: true, small: true }) : null,
              proposal
                ? ui.row([ui.agentChip(chipText(proposal), () => t.proposals.open(proposal.id), { attention: true, title: proposal.title })])
                : i.status === "researching"
                  ? ui.row([ui.agentChip(`${agentName} is looking`, undefined, { title: `${agentName} is researching this` })])
                  : null,
            ], { gap: 3 });
          },
        },
        { label: "Status", render: (i) => ui.badge(LABEL[i.status] ?? i.status, TONE[i.status]) },
        {
          label: "Where",
          render: (i) => i.source
            ? ui.stack([
                ui.text(i.source, { small: true }),
                i.url ? ui.link(i.url.replace(/^https?:\/\/(www\.)?/, "").slice(0, 36) + "…", i.url) : null,
              ], { gap: 0 })
            : ui.text("–", { muted: true }),
        },
        { label: "Price", align: "right", render: (i) => (i.price != null ? `$${i.price.toFixed(2)}` : "–") },
        {
          label: "",
          align: "right",
          render: (i) => ui.row([
            i.status === "needed"
              ? ui.button(`${agentName}, find it`, async () => {
                  await db.exec("UPDATE shopping SET status = 'researching' WHERE id = ?", [i.id]);
                  await t.agent.assign(
                    `Shopping item #${i.id}: research "${i.item}"${i.qty ? ` (${i.qty})` : ""}${i.notes ? `; ${i.notes}` : ""}. Record the best option's source, url and price.`,
                    `shopping/${i.id}`,
                  );
                }, { kind: "ghost", small: true })
              : null,
            i.status !== "arrived"
              ? ui.button(`→ ${LABEL[next(i.status)]}`, () =>
                  db.exec("UPDATE shopping SET status = ? WHERE id = ?", [next(i.status), i.id]), { small: true })
              : ui.button("Remove", () => db.exec("DELETE FROM shopping WHERE id = ?", [i.id]), { kind: "ghost", small: true }),
          ], { gap: 4, justify: "flex-end" }),
        },
      ],
      items,
      { empty: "The shopping list is empty." },
    ),
    ui.form(
      [
        { name: "item", placeholder: "Item", required: true },
        { name: "qty", placeholder: "How much" },
        { name: "notes", placeholder: "Notes" },
      ],
      (v) => db.exec("INSERT INTO shopping (item, qty, notes) VALUES (?, ?, ?)", [v.item, v.qty || null, v.notes || null]),
    ),
  );
}

function chipText(p: Proposal): string {
  const prices = p.options.map((o) => o.price).filter((x): x is number => typeof x === "number");
  if (p.options.length > 1) {
    return prices.length ? `${p.options.length} options from $${Math.min(...prices).toFixed(2)}` : `${p.options.length} options to pick from`;
  }
  if (p.kind === "purchase") return prices.length ? `Approve $${prices[0].toFixed(2)}?` : "Ready to approve";
  return p.kind === "question" ? "Question for you" : "Take a look";
}
