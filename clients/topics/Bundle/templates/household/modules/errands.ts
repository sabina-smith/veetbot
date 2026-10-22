// Groceries and errands: a quick list to tick off.

interface Errand { id: number; text: string; tag: string | null; done: number }

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const items = await db.query<Errand>("SELECT * FROM errands ORDER BY done, id DESC LIMIT 30");
  t.card.meta(`${items.filter((i) => !i.done).length} to get`);
  root.append(
    ui.stack(items.map((i) => ui.item([ui.row([
      ui.checkbox(!!i.done, (checked) => db.exec("UPDATE errands SET done = ? WHERE id = ?", [checked ? 1 : 0, i.id])),
      ui.el("span", { style: { flex: "1", fontSize: "14.5px", textDecoration: i.done ? "line-through" : "none", color: i.done ? "var(--faint)" : "inherit" } }, i.text),
      i.tag ? ui.el("span", { class: "muted", style: { fontSize: "12.5px" } }, i.tag) : null,
    ], { gap: 12 })])), { gap: 0 }),
    ui.inlineAdd("Add something", (text) => db.exec("INSERT INTO errands (text) VALUES (?)", [text])),
  );
}
