// Topics module SDK. Ambient types: modules use them without importing.
//
// A module is one card on the board: modules/<id>.ts default-exports a
// render function. The board draws the card's frame (a heavy rule and the
// title from board.json); the module fills the body. It is called again
// whenever the topic's data changes, so render fresh from the database and
// keep only small view state (a selection) in module-level variables.
//
//   export default async function render(root: HTMLElement, t: Topics): Promise<void> {
//     const rows = await t.db.query<{ id: number; title: string }>("SELECT id, title FROM tasks");
//     t.card.meta(`${rows.length} left`);
//     root.append(...rows.map((r) => t.ui.item([t.ui.text(r.title)])));
//   }
//
// Look and feel: editorial, flat, square, ink on white with the topic's
// colour for the helper. Rows are `ui.item`s separated by hairlines; small
// uppercase labels are `ui.eyebrow`; actions are `ui.textButton`s, never
// big buttons, except `ui.needsButton` (orange) which is reserved for a
// decision waiting on the owner. Mark a row the helper is working on with
// `ui.item(..., { looking: true })` plus `ui.helperNote("Fern is looking")`,
// and a row with an open proposal with `{ needs: true }` plus a needsButton
// that calls `t.proposals.open(id)`.
//
// Rules: erasable TypeScript only (types, interfaces, `as`; no enums,
// namespaces, parameter properties or decorators); no imports at run time;
// no network (the page's content policy blocks it). Use the building blocks
// so every board looks like one app.

type Child = Node | string | number | null | undefined | false | Child[];
type Tone = "neutral" | "accent" | "good" | "warn" | "attention" | "bad" | "ink";
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
  /** Small uppercase label. */
  eyebrow(text: string, opts?: { tone?: Tone }): HTMLElement;
  /** `clamp` limits it to two lines. */
  text(text: string, opts?: { muted?: boolean; small?: boolean; strong?: boolean; tone?: Tone; clamp?: boolean }): HTMLElement;
  /** A row: hairline below; `needs` adds the orange tab, `looking` a shimmer while the helper works on it. */
  item(children: Child[], opts?: { needs?: boolean; looking?: boolean; changed?: boolean }): HTMLElement;
  /** A quiet underlined action. `helper: true` colours it as the helper's ("Fern, find it"). */
  textButton(label: string, onClick: (e: Event) => unknown, opts?: { helper?: boolean; title?: string }): HTMLElement;
  /** The orange "your call" button for an open proposal, e.g. "2 options from $24". */
  needsButton(label: string, onClick: (e: Event) => unknown): HTMLElement;
  /** A pulsing line in the helper's colour, e.g. "Fern is looking". */
  helperNote(text: string): HTMLElement;
  /** An underlined input that adds on Enter, e.g. "Add something to buy". */
  inlineAdd(placeholder: string, onSubmit: (value: string) => unknown, opts?: { button?: string }): HTMLElement;
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
  progress(value: number, opts?: { color?: string }): HTMLElement;
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
  /** This topic's entries in full, other topics' as labels. */
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
  /** A short message at the bottom of the board, optionally with Undo. */
  toast(text: string, opts?: { undo?: () => unknown }): void;
  /** The "Needs your OK" dialog for anything with real-world effects. Resolves true if the owner confirms. */
  confirm(opts: { title: string; rows?: [string, string][]; explainer?: string; confirm?: string }): Promise<boolean>;
  /** Opens a web page in the owner's browser. */
  openLink(url: string): Promise<void>;
  /** The card's frame. */
  card: { meta(text: string): void };
  /** "$24", "$31.50". */
  money(n: number | null | undefined): string;
  /** Re-renders this module, e.g. after changing module-local selection state. */
  refresh(): void;
  /** YYYY-MM-DD, local. */
  today(): string;
  formatDate(iso: string | null | undefined, opts?: Intl.DateTimeFormatOptions): string;
}
