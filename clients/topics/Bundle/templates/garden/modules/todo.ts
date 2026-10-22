// Garden to-dos. Each belongs to the owner or to the helper; due dates can
// go on the shared schedule as a short label.

interface Task { id: number; title: string; notes: string | null; assignee: string; status: string; due_on: string | null; agent_note: string | null; schedule_id: string | null }

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const helper = t.topic.agentName;
  const tasks = await db.query<Task>(
    "SELECT * FROM tasks ORDER BY status = 'done', due_on IS NULL, due_on, id",
  );
  const proposals = await t.proposals.byRef();
  const today = t.today();
  const left = tasks.filter((x) => x.status !== "done");
  t.card.meta(`${left.length} left`);

  const due = (task: Task) => {
    if (!task.due_on) return "No date";
    if (task.due_on === today) return "Today";
    return t.formatDate(task.due_on);
  };

  const row = (task: Task) => {
    const done = task.status === "done";
    const p = proposals[`tasks/${task.id}`];
    const looking = task.assignee === "agent" && !done && task.status !== "waiting" && !p;
    const late = !done && task.due_on !== null && task.due_on <= today;
    return ui.item([ui.row([
      ui.checkbox(done, async (checked) => {
        await db.exec("UPDATE tasks SET status = ?, done_at = ? WHERE id = ?", [checked ? "done" : "open", checked ? new Date().toISOString() : null, task.id]);
        if (checked && task.schedule_id) await t.schedule.remove(task.schedule_id);
      }),
      ui.stack([
        ui.el("span", { style: { fontSize: "14.5px", lineHeight: "1.35", textDecoration: done ? "line-through" : "none", color: done ? "var(--faint)" : "inherit" } }, task.title),
        task.agent_note && !done ? ui.text(task.agent_note, { small: true, muted: true, clamp: true }) : null,
        p ? ui.row([ui.needsButton(p.kind === "question" ? `${helper} has a question` : `${helper} needs you`, () => t.proposals.open(p.id))]) : null,
        ui.row([
          ui.el("span", { style: { fontSize: "12.5px", fontWeight: late ? "650" : "400", color: late ? "var(--attention-text)" : "var(--muted)" } }, due(task)),
          task.assignee === "agent" && !done ? ui.el("span", { style: { fontSize: "12.5px", fontWeight: "600", color: "var(--topic)" } }, looking ? `${helper} is on it` : helper) : null,
          task.schedule_id ? ui.el("span", { class: "muted", style: { fontSize: "12.5px" } }, "On schedule") : null,
          !done && task.assignee === "me" ? ui.textButton(`Ask ${helper}`, async () => {
            await db.exec("UPDATE tasks SET assignee = 'agent', status = 'open' WHERE id = ?", [task.id]);
            await t.agent.assign(`Task #${task.id}: ${task.title}${task.notes ? ` (${task.notes})` : ""}`, `tasks/${task.id}`);
          }, { helper: true }) : null,
          !done && task.due_on && !task.schedule_id ? ui.textButton("Schedule", async () => {
            const entry = await t.schedule.add({ kind: "task", start: task.due_on as string, label: task.title, ref: `tasks/${task.id}` });
            await db.exec("UPDATE tasks SET schedule_id = ? WHERE id = ?", [entry.id, task.id]);
          }) : null,
        ], { gap: 12, wrap: true, align: "baseline" }),
      ], { gap: 2 }),
    ], { align: "flex-start", gap: 12 })], { needs: !!p, looking });
  };

  root.append(
    ui.stack(tasks.slice(0, 12).map(row), { gap: 0 }),
    ui.inlineAdd("Add a task", (title) => db.exec("INSERT INTO tasks (title) VALUES (?)", [title])),
  );
}
