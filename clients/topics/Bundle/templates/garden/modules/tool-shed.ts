// What's in the shed, grouped by kind, with condition. Worn or broken
// tools can go straight onto the shopping list.

interface Tool { id: number; name: string; category: string; condition: string; location: string | null; notes: string | null }

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const tools = await db.query<Tool>("SELECT * FROM tools ORDER BY category, name");
  const onList = new Set(
    (await db.query<{ item: string }>("SELECT lower(item) AS item FROM shopping WHERE status != 'arrived'")).map((r) => r.item),
  );

  const categories = [...new Set(tools.map((tool) => tool.category))];
  const counts = { good: 0, worn: 0, broken: 0 } as Record<string, number>;
  tools.forEach((tool) => (counts[tool.condition] = (counts[tool.condition] ?? 0) + 1));

  root.append(
    ui.row([
      ui.stat("tools", tools.length),
      ui.stat("worn", counts.worn),
      ui.stat("broken", counts.broken),
    ], { gap: 6 }),
    ...categories.map((category) =>
      ui.section(category, [
        ui.list(tools.filter((tool) => tool.category === category), (tool) =>
          ui.row([
            ui.stack([
              ui.text(tool.name, { strong: true }),
              tool.location || tool.notes
                ? ui.text([tool.location, tool.notes].filter(Boolean).join(" · "), { muted: true, small: true })
                : null,
            ], { gap: 1 }),
            ui.spacer(),
            tool.condition !== "good" && !onList.has(tool.name.toLowerCase())
              ? ui.button("Replace", () =>
                  db.exec(
                    "INSERT INTO shopping (item, qty, notes) VALUES (?, '1', ?)",
                    [tool.name, `Replacing a ${tool.condition} one from the shed.`],
                  ), { kind: "ghost", small: true, title: "Add to the shopping list" })
              : null,
            ui.select(["good", "worn", "broken"], tool.condition, (condition) =>
              db.exec("UPDATE tools SET condition = ? WHERE id = ?", [condition, tool.id])),
          ]),
        ),
      ]),
    ),
    ui.form(
      [
        { name: "name", placeholder: "Tool", required: true },
        { name: "category", placeholder: "Kind", value: "Hand tools" },
        { name: "location", placeholder: "Where it lives" },
      ],
      (v) => db.exec("INSERT INTO tools (name, category, location) VALUES (?, ?, ?)", [v.name, v.category || "Hand tools", v.location || null]),
    ),
  );
}
