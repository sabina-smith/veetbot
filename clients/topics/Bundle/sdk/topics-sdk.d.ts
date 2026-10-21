// Topics module SDK. Ambient types: modules use them without importing.
//
// A module is one file, modules/<id>.ts, that default-exports a render
// function. The runtime calls it with an empty element and the SDK, and
// calls it again whenever any module or the agent changes the topic's
// data. Render fresh from the database each time; keep no other state.
//
//   export default async function render(root: HTMLElement, t: Topics): Promise<void> {
//     const rows = await t.db.query<{ id: number; title: string }>("SELECT id, title FROM tasks");
//     root.append(t.ui.list(rows, (r) => t.ui.text(r.title)));
//   }
//
// Rules: erasable TypeScript only (types, interfaces, `as`; no enums,
// namespaces, parameter properties or decorators); no imports at run time;
// no network (the card's content policy blocks it). Use the building blocks
// so every board looks like one app.

type Child = Node | string | number | null | undefined | false | Child[];
type Tone = "neutral" | "accent" | "good" | "warn" | "bad";
type SQLValue = string | number | null;

interface FormField {
  name: string;
  label?: string;
  type?: "text" | "number" | "date" | "datetime-local" | "select" | "textarea";
  /** For selects: values, or [value, label] pairs. */
  options?: (string | [string, string])[];
  placeholder?: string;
  required?: boolean;
  value?: string | number;
  /** Take a full row of the form. */
  wide?: boolean;
}

interface Column<Row> {
  key?: keyof Row & string;
  label: string;
  align?: "left" | "right" | "center";
  render?: (row: Row) => Child;
}

interface UI {
  el(tag: string, props?: Record<string, unknown>, ...children: Child[]): HTMLElement;
  stack(children: Child[], opts?: { gap?: number }): HTMLElement;
  row(children: Child[], opts?: { gap?: number; align?: string; justify?: string; wrap?: boolean }): HTMLElement;
  spacer(): HTMLElement;
  heading(text: string, opts?: { level?: 1 | 2 }): HTMLElement;
  text(text: string, opts?: { muted?: boolean; small?: boolean; strong?: boolean }): HTMLElement;
  badge(text: string, tone?: Tone): HTMLElement;
  /** The button disables itself while an async onClick runs. */
  button(label: string, onClick: (e: Event) => unknown, opts?: { kind?: "primary" | "secondary" | "ghost"; small?: boolean; title?: string; disabled?: boolean }): HTMLElement;
  section(title: string, children: Child[], opts?: { action?: Child }): HTMLElement;
  list<T>(items: T[], render: (item: T, index: number) => Child, opts?: { empty?: string }): HTMLElement;
  table<Row>(columns: Column<Row>[], rows: Row[], opts?: { empty?: string }): HTMLElement;
  /** Number fields arrive as numbers (or null), the rest as trimmed strings. */
  form(fields: FormField[], onSubmit: (values: Record<string, any>) => unknown, opts?: { submitLabel?: string; inline?: boolean; reset?: boolean }): HTMLElement;
  checkbox(checked: boolean, onChange: (checked: boolean) => unknown, label?: string): HTMLElement;
  select(options: (string | [string, string])[], value: string, onChange: (value: string) => unknown): HTMLElement;
  empty(text: string): HTMLElement;
  stat(label: string, value: string | number): HTMLElement;
  /** 0 to 1. */
  progress(value: number): HTMLElement;
  split(left: Child, right: Child, opts?: { columns?: string }): HTMLElement;
  /** The agent's mark on the board: a small chip, e.g. on a row it has worked on. `attention` fills it, for "needs you". */
  agentChip(text: string, onClick?: (e: Event) => unknown, opts?: { attention?: boolean; title?: string }): HTMLElement;
  /** A web link; opens in the owner's browser. */
  link(text: string, url: string): HTMLElement;
}

interface Shape {
  fill?: string;
  stroke?: string;
  strokeWidth?: number;
  opacity?: number;
  title?: string;
  onClick?: (e: Event) => unknown;
}

interface Draw {
  /** Palette entries; `var(...)` values follow light and dark mode. */
  colors: { accent: string; text: string; muted: string; line: string; surface: string; soil: string; leaf: string; water: string; sun: string; bloom: string };
  /** Scales to the card's width; coordinates are in viewBox units. */
  svg(width: number, height: number, children: Child[], opts?: { viewBox?: string }): SVGSVGElement;
  group(children: Child[], opts?: { transform?: string; opacity?: number }): SVGGElement;
  rect(o: Shape & { x: number; y: number; w: number; h: number; r?: number }): SVGRectElement;
  circle(o: Shape & { cx: number; cy: number; r: number }): SVGCircleElement;
  line(o: { x1: number; y1: number; x2: number; y2: number; stroke?: string; strokeWidth?: number; dash?: string }): SVGLineElement;
  path(o: Shape & { d: string }): SVGPathElement;
  text(o: { x: number; y: number; text: string; size?: number; anchor?: "start" | "middle" | "end"; baseline?: string; fill?: string; weight?: number | string; onClick?: (e: Event) => unknown }): SVGTextElement;
}

interface DB {
  /** One statement; `?` placeholders. Rows are plain objects. */
  query<Row = Record<string, SQLValue>>(sql: string, params?: SQLValue[]): Promise<Row[]>;
  one<Row = Record<string, SQLValue>>(sql: string, params?: SQLValue[]): Promise<Row | null>;
  /** One write statement. Every module re-renders afterwards. */
  exec(sql: string, params?: SQLValue[]): Promise<{ changes: number; lastInsertRowid: number }>;
}

interface ScheduleEntryInput {
  kind: "block" | "task" | "reminder";
  /** ISO date or date-time. */
  start: string;
  end?: string;
  /** All other topics and Home ever see. Keep it short and non-sensitive. */
  label: string;
  /** Points back at this topic's own record, e.g. "tasks/12". Never shared. */
  ref?: string;
  visibility?: "labeled" | "busy" | "hidden";
}

interface ScheduleEntry {
  id: string;
  kind: "block" | "task" | "reminder";
  start: string;
  end?: string;
  label: string;
  /** Present only on this topic's own entries. */
  ref?: string;
  isOwn: boolean;
}

interface Schedule {
  add(entry: ScheduleEntryInput): Promise<{ id: string }>;
  remove(id: string): Promise<void>;
  /** This topic's entries in full, other topics' as labels, sealed ones as "Busy". */
  list(days?: number): Promise<ScheduleEntry[]>;
}

interface ProposalOption {
  label: string;
  detail?: string;
  url?: string;
  price?: number;
  /** Column values written to the proposal's row if the owner picks this option. */
  set?: Record<string, SQLValue>;
}

interface Proposal {
  id: number;
  /** "<table>/<row id>", e.g. "shopping/2". */
  ref: string | null;
  kind: "purchase" | "choice" | "question" | "change";
  title: string;
  summary: string | null;
  options: ProposalOption[];
  recommended: number | null;
}

/**
 * Decisions the agent is waiting on. The agent creates them (with SQL in the
 * `proposals` table); the owner opens one from its row and resolves it in the
 * app's sidebar, which writes the chosen option into the row.
 */
interface Proposals {
  /** Open proposals keyed by ref, for showing a chip on each row. */
  byRef(): Promise<Record<string, Proposal>>;
  list(): Promise<Proposal[]>;
  /** Opens the proposal in the sidebar. */
  open(id: number): Promise<void>;
}

interface Agent {
  /** Sends a message to this topic's agent, as if the owner typed it. */
  ask(text: string): Promise<void>;
  /** Hands a piece of work to the agent; `ref` names the record, e.g. "tasks/12". */
  assign(task: string, ref?: string): Promise<void>;
}

interface Topics {
  topic: { id: string; name: string; accent: string; agentName: string };
  module: { id: string; title: string };
  ui: UI;
  draw: Draw;
  db: DB;
  schedule: Schedule;
  agent: Agent;
  proposals: Proposals;
  toast(text: string): void;
  /** Re-renders this module, e.g. after changing module-local selection state. */
  refresh(): void;
  /** YYYY-MM-DD, local. */
  today(): string;
  formatDate(iso: string | null | undefined, opts?: Intl.DateTimeFormatOptions): string;
}
