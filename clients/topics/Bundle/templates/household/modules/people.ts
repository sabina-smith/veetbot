// The people who help with the house, and how this household deals with
// each of them.

interface Person { id: number; name: string; role: string | null; how: string | null; note: string | null }

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const people = await db.query<Person>("SELECT * FROM people ORDER BY name");
  t.card.meta("How Household deals with them");
  root.append(
    ui.table<Person>([
      { label: "Who", render: (p) => ui.el("span", {}, p.name, ui.el("span", { class: "t-sub" }, p.role ?? "")) },
      { label: "How", render: (p) => ui.el("span", { style: { color: "var(--topic)", fontWeight: "550", fontSize: "13.5px" } }, p.how ?? "–") },
      { label: "Notes", render: (p) => ui.el("span", { class: "muted", style: { fontSize: "13.5px" } }, p.note ?? "") },
    ], people),
    ui.inlineAdd("Add a person", (name) => db.exec("INSERT INTO people (name) VALUES (?)", [name])),
  );
}
