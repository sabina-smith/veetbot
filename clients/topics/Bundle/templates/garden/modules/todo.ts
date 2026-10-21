// The garden to-do list. Tasks belong to the owner or to the agent; due
// dates go on the shared schedule as a short label.

interface Task { id: number; title: string; notes: string | null; assignee: string; status: string; due_on: string | null; agent_note: string | null; schedule_id: string | null }

let showDone = false;

export default async function render(root: HTMLElement, t: Topics): Promise<void> {
  const { ui, db } = t;
  const agentName = t.topic.agentName;
  const open = await db.query<Task>(
    "SELECT * FROM tasks WHERE status != 'done' ORDER BY due_on IS NULL, due_on, id",
  );
  const done = await db.query<Task>("SELECT * FROM tasks WHERE status = 'done' ORDER BY done_at DESC, id DESC LIMIT 20");
  const today = t.today();
  const proposals = await t.proposals.byRef();

  const statusBadge = (task: Task) => {
    if (task.status === "in_progress") return ui.badge("working", "accent");
    if (task.status === "waiting") return ui.badge("needs you", "warn");
    return null;
  };

  const dueBadge = (task: Task) => {
    if (!task.due_on) return null;
    const overdue = task.due_on < today;
    return ui.badge(overdue ? `overdue · ${t.formatDate(task.due_on)}` : t.formatDate(task.due_on), overdue ? "bad" : "neutral");
  };

  const row = (task: Task) =>
    ui.row([
      ui.checkbox(task.status === "done", async (checked) => {
        await db.exec(
          "UPDATE tasks SET status = ?, done_at = ? WHERE id = ?",
          [checked ? "done" : "open", checked ? new Date().toISOString() : null, task.id],
        );
        if (checked && task.schedule_id) await t.schedule.remove(task.schedule_id);
      }),
      ui.stack([
        ui.text(task.title, { strong: task.status !== "done" }),
        task.notes ? ui.text(task.notes, { muted: true, small: true }) : null,
        proposals[`tasks/${task.id}`]
          ? ui.row([ui.agentChip(
              proposals[`tasks/${task.id}`].kind === "question" ? `${agentName} has a question` : `${agentName} needs you`,
              () => t.proposals.open(proposals[`tasks/${task.id}`].id),
              { attention: true, title: proposals[`tasks/${task.id}`].title },
            )])
          : task.assignee === "agent" && task.status !== "done"
            ? ui.row([ui.agentChip(task.status === "waiting" ? `${agentName} is waiting` : `${agentName} is on it`, undefined, { title: task.agent_note ?? "" })])
            : null,
        ui.row([
          task.assignee === "me" ? statusBadge(task) : null,
          dueBadge(task),
        ], { gap: 4, wrap: true }),
      ], { gap: 2 }),
      ui.spacer(),
      task.due_on && !task.schedule_id && task.status !== "done"
        ? ui.button("Put on schedule", async () => {
            const entry = await t.schedule.add({ kind: "task", start: task.due_on as string, label: task.title, ref: `tasks/${task.id}` });
            await db.exec("UPDATE tasks SET schedule_id = ? WHERE id = ?", [entry.id, task.id]);
            t.toast(`Scheduled for ${t.formatDate(task.due_on)}`);
          }, { kind: "ghost", small: true, title: "Add the due date to the shared schedule" })
        : null,
      task.assignee === "me" && task.status !== "done"
        ? ui.button(`Ask ${agentName}`, async () => {
            await db.exec("UPDATE tasks SET assignee = 'agent', status = 'open' WHERE id = ?", [task.id]);
            await t.agent.assign(`Task #${task.id}: ${task.title}${task.notes ? ` (${task.notes})` : ""}`, `tasks/${task.id}`);
          }, { kind: "ghost", small: true, title: `Hand this task to ${agentName}` })
        : null,
    ], { align: "flex-start" });

  root.append(
    ui.list(open, row, { empty: "Nothing to do. Enjoy the garden." }),
    ui.form(
      [
        { name: "title", placeholder: "New task", required: true, wide: true },
        { name: "due_on", type: "date" },
        { name: "assignee", type: "select", options: [["me", "Me"], ["agent", agentName]], value: "me" },
      ],
      async (v) => {
        const { lastInsertRowid: id } = await db.exec(
          "INSERT INTO tasks (title, assignee, due_on) VALUES (?, ?, ?)",
          [v.title, v.assignee, v.due_on || null],
        );
        if (v.due_on) {
          const entry = await t.schedule.add({ kind: "task", start: v.due_on, label: v.title, ref: `tasks/${id}` });
          await db.exec("UPDATE tasks SET schedule_id = ? WHERE id = ?", [entry.id, id]);
        }
        if (v.assignee === "agent") await t.agent.assign(`Task #${id}: ${v.title}`, `tasks/${id}`);
      },
    ),
    done.length
      ? ui.stack([
          ui.button(showDone ? "Hide done" : `Show ${done.length} done`, () => { showDone = !showDone; t.refresh(); }, { kind: "ghost", small: true }),
          showDone ? ui.list(done, row) : null,
        ], { gap: 4 })
      : null,
  );
}
