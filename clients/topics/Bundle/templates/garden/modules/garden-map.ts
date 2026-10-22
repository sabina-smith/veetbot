// The garden from above: beds placed on a 120 x 80 yard. Click a bed to see
// and edit what's growing in it.

interface Bed { id: number; name: string; x: number; y: number; w: number; h: number; sun: string; soil: string | null; notes: string | null }
interface Plant { id: number; bed_id: number | null; name: string; variety: string | null; status: string; planted_on: string | null; notes: string | null }

const SUN: Record<string, string> = { full: "Full sun", part: "Afternoon shade", shade: "Shade" };
let selectedBed: number | null = null;

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const beds = await db.query<Bed>("SELECT * FROM beds ORDER BY id");
  const plants = await db.query<Plant>("SELECT * FROM plants WHERE status NOT IN ('removed', 'harvested') ORDER BY name");
  t.card.meta(`${beds.length} beds`);
  if (selectedBed === null || !beds.some((b) => b.id === selectedBed)) selectedBed = beds[0]?.id ?? null;

  const yard = ui.el("div", { style: { position: "relative", aspectRatio: "3 / 2", background: "var(--surface)" } });
  for (const bed of beds) {
    const count = plants.filter((p) => p.bed_id === bed.id).length;
    const on = bed.id === selectedBed;
    const empty = count === 0;
    yard.append(ui.el("button", {
      type: "button",
      "aria-pressed": String(on),
      onclick: () => { selectedBed = bed.id; t.refresh(); },
      style: {
        position: "absolute", left: `${(bed.x / 120) * 100}%`, top: `${(bed.y / 80) * 100}%`,
        width: `${(bed.w / 120) * 100}%`, height: `${(bed.h / 80) * 100}%`,
        display: "flex", flexDirection: "column", justifyContent: "space-between", alignItems: "flex-start", padding: "8px 10px",
        background: empty ? "repeating-linear-gradient(135deg,#fff 0 6px,#EDEDE9 6px 7px)" : on ? "var(--topic)" : "#D9EADF",
        color: on && !empty ? "#fff" : "var(--ink)", boxShadow: on ? "inset 0 0 0 2px #0F0F0E" : "none", textAlign: "left",
      },
    },
      ui.el("span", { style: { fontSize: "13px", fontWeight: "650", lineHeight: "1.15" } }, bed.name),
      ui.el("span", { class: "tabular", style: { fontSize: "12px", opacity: "0.75" } }, empty ? "Empty" : `${count} plant${count === 1 ? "" : "s"}`)));
  }

  const bed = beds.find((b) => b.id === selectedBed);
  const detail = bed
    ? ui.stack([
        ui.eyebrow(SUN[bed.sun] ?? bed.sun),
        ui.el("h3", { class: "display", style: { margin: "2px 0 0", fontSize: "28px", lineHeight: "1" } }, bed.name),
        bed.soil || bed.notes ? ui.text([bed.soil, bed.notes].filter(Boolean).join(" · "), { small: true, muted: true }) : null,
        ui.stack(plants.filter((p) => p.bed_id === bed.id).map((p) =>
          ui.item([ui.row([
            ui.text(`${p.name}${p.variety ? ` · ${p.variety}` : ""}`),
            ui.spacer(),
            ui.select(["planned", "growing", "dormant", "harvested", "removed"], p.status, (status) =>
              db.exec("UPDATE plants SET status = ? WHERE id = ?", [status, p.id])),
          ])])), { gap: 0 }),
        plants.some((p) => p.bed_id === bed.id) ? null : ui.text("Nothing planted yet.", { muted: true, small: true }),
        ui.inlineAdd(`Add to ${bed.name}`, (name) => db.exec(
          "INSERT INTO plants (bed_id, name, status, planted_on) VALUES (?, ?, 'growing', ?)", [bed.id, name, t.today()]), { button: "Add" }),
      ], { gap: 6 })
    : ui.empty("No beds yet.");

  root.append(ui.split(yard, detail, { columns: "1.3fr 1fr" }));
}
