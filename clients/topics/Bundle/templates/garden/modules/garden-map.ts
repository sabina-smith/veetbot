// The garden as seen from above: beds placed on a 120 x 80 yard, plants
// dotted inside them. Click a bed to see and edit what's in it.

interface Bed { id: number; name: string; x: number; y: number; w: number; h: number; sun: string; soil: string | null; notes: string | null }
interface Plant { id: number; bed_id: number | null; name: string; variety: string | null; status: string; planted_on: string | null; notes: string | null }

const STATUS_TONE: Record<string, Tone> = { planned: "neutral", growing: "good", dormant: "accent", harvested: "warn", removed: "bad" };

let selectedBed: number | null = null;

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, draw, db } = t;
  const beds = await db.query<Bed>("SELECT * FROM beds ORDER BY id");
  const plants = await db.query<Plant>("SELECT * FROM plants WHERE status != 'removed' ORDER BY name");
  if (selectedBed === null && beds.length) selectedBed = beds[0].id;

  const plantColor = (status: string) =>
    status === "growing" ? draw.colors.leaf
      : status === "harvested" ? draw.colors.sun
      : status === "dormant" ? draw.colors.water
      : draw.colors.muted;

  const shapes: SVGElement[] = [
    draw.rect({ x: 0, y: 0, w: 120, h: 80, r: 3, fill: "#9cc58f", opacity: 0.35 }),
    draw.path({ d: "M 58 0 L 58 80", stroke: "#c9b08a", strokeWidth: 3 }),
  ];
  for (const bed of beds) {
    const inBed = plants.filter((p) => p.bed_id === bed.id);
    const selected = bed.id === selectedBed;
    shapes.push(
      draw.rect({
        x: bed.x, y: bed.y, w: bed.w, h: bed.h, r: 1.5, fill: draw.colors.soil, opacity: selected ? 1 : 0.8,
        stroke: selected ? draw.colors.accent : undefined, strokeWidth: selected ? 0.8 : undefined,
        title: bed.name, onClick: () => { selectedBed = bed.id; t.refresh(); },
      }),
    );
    // Lay plants out on a small grid inside the bed.
    const cols = Math.max(1, Math.floor(bed.w / 7));
    inBed.forEach((p, i) => {
      const cx = bed.x + 3.5 + (i % cols) * ((bed.w - 7) / Math.max(1, cols - 1) || 0);
      const cy = bed.y + 4 + Math.floor(i / cols) * 6;
      if (cy > bed.y + bed.h - 2) return;
      shapes.push(draw.circle({ cx, cy, r: 2.2, fill: plantColor(p.status), stroke: "white", strokeWidth: 0.3, title: `${p.name}${p.variety ? ` (${p.variety})` : ""}: ${p.status}` }));
    });
    shapes.push(draw.text({ x: bed.x + 1.5, y: bed.y + bed.h - 2.5, text: bed.name, size: 3, fill: "white", weight: 600 }));
  }
  const map = draw.svg(120, 80, shapes);

  const bed = beds.find((b) => b.id === selectedBed);
  const detail = bed
    ? ui.stack([
        ui.row([ui.heading(bed.name, { level: 2 }), ui.spacer(), ui.badge(`${bed.sun} sun`, "accent")]),
        bed.soil || bed.notes ? ui.text([bed.soil, bed.notes].filter(Boolean).join(" · "), { muted: true, small: true }) : null,
        ui.list(
          plants.filter((p) => p.bed_id === bed.id),
          (p) =>
            ui.row([
              ui.stack([
                ui.text(`${p.name}${p.variety ? ` · ${p.variety}` : ""}`, { strong: true }),
                p.notes ? ui.text(p.notes, { muted: true, small: true }) : null,
              ], { gap: 1 }),
              ui.spacer(),
              ui.select(["planned", "growing", "dormant", "harvested", "removed"], p.status, (status) =>
                db.exec("UPDATE plants SET status = ? WHERE id = ?", [status, p.id])),
            ]),
          { empty: "Nothing planted here yet." },
        ),
        ui.form(
          [
            { name: "name", placeholder: "Plant", required: true },
            { name: "variety", placeholder: "Variety" },
            { name: "status", type: "select", options: ["planned", "growing"], value: "planned" },
          ],
          (v) => db.exec(
            "INSERT INTO plants (bed_id, name, variety, status, planted_on) VALUES (?, ?, ?, ?, ?)",
            [bed.id, v.name, v.variety || null, v.status, v.status === "growing" ? t.today() : null],
          ),
          { submitLabel: "Add" },
        ),
      ], { gap: 8 })
    : ui.empty("Click a bed on the map.");

  const legend = ui.row(
    ["growing", "dormant", "harvested", "planned"].map((s) => ui.badge(s, STATUS_TONE[s])),
    { gap: 4, wrap: true },
  );

  root.append(ui.split(ui.stack([map, legend], { gap: 6 }), detail, { columns: "3fr 2fr" }));

}
