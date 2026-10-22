// Things to buy, moving from needed to arrived. The helper researches items
// and brings back options as a decision on the row; nothing is bought until
// the owner says so, and buying means opening the store's page.

interface Item { id: number; item: string; qty: string | null; status: string; source: string | null; url: string | null; price: number | null; task_id: number | null; notes: string | null; added_by: string }

const LABEL: Record<string, string> = { needed: "Needed", researching: "Looking", in_cart: "In cart", ordered: "Ordered", arrived: "Arrived" };
let showArrived = false;

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const helper = t.topic.agentName;
  const items = await db.query<Item>("SELECT * FROM shopping ORDER BY CASE status WHEN 'arrived' THEN 1 ELSE 0 END, id DESC");
  const proposals = await t.proposals.byRef();
  const open = items.filter((i) => i.status !== "arrived");
  const arrived = items.filter((i) => i.status === "arrived");
  t.card.meta(`${open.length} open`);

  const summary = (p: Proposal) => {
    const prices = p.options.map((o) => o.price).filter((x): x is number => typeof x === "number");
    if (p.options.length > 1) return prices.length ? `${p.options.length} options from ${t.money(Math.min(...prices))}` : `${p.options.length} options`;
    return prices.length ? `${t.money(prices[0])}, your OK` : "Take a look";
  };

  const buy = async (i: Item) => {
    if (!i.url) return t.toast("There's no store link for this yet.");
    const ok = await t.confirm({
      title: `Open checkout at ${i.source ?? "the store"}?`,
      rows: [["Item", `${i.item}${i.qty ? `, ${i.qty}` : ""}`], ["Store", i.source ?? "–"], ["Price", i.price != null ? t.money(i.price) : "–"]],
      explainer: `This opens the store's page with the item. You pay on their site. ${helper} won't buy anything on its own.`,
      confirm: "Open checkout",
    });
    if (!ok) return;
    await t.openLink(i.url);
    await db.exec("UPDATE shopping SET status = 'ordered' WHERE id = ?", [i.id]);
    t.toast(`Opened ${i.source ?? "the store"} in your browser.`, { undo: () => db.exec("UPDATE shopping SET status = 'in_cart' WHERE id = ?", [i.id]) });
  };

  const row = (i: Item) => {
    const p = proposals[`shopping/${i.id}`];
    const looking = i.status === "researching" && !p;
    const status = p ? "Your call" : LABEL[i.status] ?? i.status;
    return ui.item([ui.row([
      ui.stack([
        ui.row([
          ui.el("span", { style: { fontSize: "15px", fontWeight: "550", textDecoration: i.status === "arrived" ? "line-through" : "none", color: i.status === "arrived" ? "var(--faint)" : "inherit" } }, i.item),
          i.qty ? ui.el("span", { class: "tabular faint", style: { fontSize: "13px" } }, i.qty) : null,
        ], { gap: 8, align: "baseline" }),
        p ? ui.row([ui.needsButton(summary(p), () => t.proposals.open(p.id))], { gap: 0 })
          : looking ? ui.helperNote(`${helper} is looking`)
          : i.source ? ui.row([
              ui.el("span", { class: "muted", style: { fontSize: "13px", display: "-webkit-box", webkitLineClamp: "1", webkitBoxOrient: "vertical", overflow: "hidden" } }, i.source),
              i.price != null ? ui.el("span", { class: "tabular", style: { fontSize: "13px" } }, t.money(i.price)) : null,
              i.url ? ui.link(i.url.replace(/^https?:\/\/(www\.)?/, "").split("/")[0], i.url) : null,
            ], { gap: 8, wrap: true, align: "baseline" })
          : null,
        i.notes && !p && !looking ? ui.text(i.notes, { small: true, muted: true, clamp: true }) : null,
      ], { gap: 3 }),
      ui.spacer(),
      ui.stack([
        ui.badge(status, p ? "attention" : "neutral"),
        i.status === "needed" ? ui.textButton(`${helper}, find it`, async () => {
          await db.exec("UPDATE shopping SET status = 'researching' WHERE id = ?", [i.id]);
          await t.agent.assign(`Shopping item #${i.id}: research "${i.item}"${i.qty ? ` (${i.qty})` : ""}${i.notes ? `; ${i.notes}` : ""}. Bring back options as a proposal on its row.`, `shopping/${i.id}`);
        }, { helper: true }) : null,
        i.status === "in_cart" ? ui.textButton("Buy…", () => buy(i)) : null,
        i.status === "ordered" ? ui.textButton("Mark arrived", () => db.exec("UPDATE shopping SET status = 'arrived' WHERE id = ?", [i.id])) : null,
      ], { gap: 4 }),
    ], { align: "flex-start", gap: 16 })], { needs: !!p, looking });
  };

  root.append(
    ui.stack((showArrived ? items : open).map(row), { gap: 0 }),
    arrived.length ? ui.row([ui.textButton(showArrived ? "Hide arrived" : `${arrived.length} arrived`, () => { showArrived = !showArrived; t.refresh(); })]) : null,
    ui.inlineAdd("Add something to buy", (item) => db.exec("INSERT INTO shopping (item, qty) VALUES (?, '1')", [item])),
  );
}
