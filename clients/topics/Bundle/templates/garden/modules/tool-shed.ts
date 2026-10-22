// What's in the shed and what shape it's in. Worn or broken tools go onto
// the shopping list with one click.

interface Tool { id: number; name: string; category: string; condition: string; location: string | null; notes: string | null }

const COLOR: Record<string, string> = { good: "var(--muted)", worn: "var(--attention-text)", broken: "var(--bad)" };
const NEXT: Record<string, string> = { good: "worn", worn: "broken", broken: "good" };

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const tools = await db.query<Tool>("SELECT * FROM tools ORDER BY condition = 'good', category, name");
  const onList = new Set((await db.query<{ item: string }>("SELECT lower(item) AS item FROM shopping WHERE status != 'arrived'")).map((r) => r.item));
  t.card.meta(`${tools.length} tools`);

  root.append(
    ui.table<Tool>([
      { label: "Tool", render: (x) => ui.el("span", {}, x.name, ui.el("span", { class: "t-sub" }, x.category)) },
      {
        label: "Condition",
        render: (x) => ui.el("button", {
          type: "button", title: "Change condition",
          onclick: () => db.exec("UPDATE tools SET condition = ? WHERE id = ?", [NEXT[x.condition] ?? "good", x.id]),
          style: { fontSize: "13.5px", fontWeight: "600", textTransform: "capitalize", color: COLOR[x.condition] ?? "var(--muted)" },
        }, x.condition),
      },
      {
        label: "", align: "right",
        render: (x) => onList.has(x.name.toLowerCase())
          ? ui.el("span", { class: "muted", style: { fontSize: "12.5px" } }, "On the list")
          : x.condition !== "good" ? ui.textButton("Replace", async () => {
              const { lastInsertRowid } = await db.exec("INSERT INTO shopping (item, qty, notes) VALUES (?, '1', ?)", [x.name, `Replacing a ${x.condition} one.`]);
              t.toast(`${x.name} added to Shopping.`, { undo: () => db.exec("DELETE FROM shopping WHERE id = ?", [lastInsertRowid]) });
            }) : null,
      },
    ], tools),
    ui.inlineAdd("Add a tool", (name) => db.exec("INSERT INTO tools (name) VALUES (?)", [name])),
  );
}
