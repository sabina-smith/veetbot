// The Topics module runtime: building blocks (`ui`), graphics (`draw`), and
// the primitives that cross into the app through the `topics` message
// handler (`db`, `schedule`, `proposals`, `agent`). Every card on a board
// is one module; the board page (board.js) lays the cards out and calls
// each module's render function. Types for module authors are in
// topics-sdk.d.ts.
(() => {
  "use strict";

  const call = (op, args = {}) => window.webkit.messageHandlers.topics.postMessage({ op, args });

  // ---------- elements ----------

  const SVG_NS = "http://www.w3.org/2000/svg";

  function append(parent, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) return child.forEach((c) => append(parent, c));
    parent.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }

  function el(tag, props = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (value === undefined || value === null || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "style" && typeof value === "object") Object.assign(node.style, value);
      else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2).toLowerCase(), value);
      else if (key in node && typeof value !== "string") node[key] = value;
      else node.setAttribute(key, value === true ? "" : String(value));
    }
    append(node, children);
    return node;
  }

  function guarded(onClick, node) {
    return async (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (node.disabled) return;
      node.disabled = true;
      try {
        await onClick(event);
      } catch (e) {
        report(e);
      } finally {
        if (node.isConnected) node.disabled = false;
      }
    };
  }

  // ---------- building blocks ----------

  const ui = {
    el,
    stack(children, opts = {}) {
      return el("div", { class: "t-stack", style: { gap: `${opts.gap ?? 10}px` } }, children);
    },
    row(children, opts = {}) {
      return el("div", {
        class: "t-row",
        style: { gap: `${opts.gap ?? 8}px`, alignItems: opts.align ?? "center", justifyContent: opts.justify ?? "flex-start", flexWrap: opts.wrap ? "wrap" : "nowrap" },
      }, children);
    },
    spacer: () => el("div", { class: "t-spacer" }),
    heading: (text, opts = {}) => el(opts.level === 2 ? "h3" : "h2", { class: "t-heading" }, text),
    eyebrow: (text, opts = {}) => el("p", { class: `eyebrow t-text${opts.tone ? ` t-tone-${opts.tone}` : " muted"}` }, text),
    text(text, opts = {}) {
      const cls = ["t-text", opts.muted && "t-muted", opts.small && "t-small", opts.strong && "t-strong", opts.tone && `t-tone-${opts.tone}`, opts.clamp && "t-clamp"];
      return el("p", { class: cls.filter(Boolean).join(" ") }, text);
    },
    badge: (text, tone = "neutral") => el("span", { class: `t-badge t-tone-${tone}` }, text),
    button(label, onClick, opts = {}) {
      const node = el("button", { class: `t-button t-${opts.kind ?? "secondary"}${opts.small ? " t-small" : ""}`, title: opts.title, disabled: opts.disabled, type: "button" }, label);
      node.addEventListener("click", guarded(onClick, node));
      return node;
    },
    textButton(label, onClick, opts = {}) {
      const node = el("button", { class: `t-textbutton${opts.helper ? " t-helper" : ""}`, title: opts.title, type: "button" }, label);
      node.addEventListener("click", guarded(onClick, node));
      return node;
    },
    needsButton(label, onClick) {
      const node = el("button", { class: "t-needs", type: "button" }, label);
      node.addEventListener("click", guarded(onClick, node));
      return node;
    },
    helperNote: (text) => el("p", { class: "t-helper-note" }, text),
    item(children, opts = {}) {
      const cls = ["t-item", opts.needs && "t-needs-tab", opts.looking && "t-looking", opts.changed && "t-changed"];
      return el("div", { class: cls.filter(Boolean).join(" ") }, children);
    },
    section(title, children, opts = {}) {
      return el("section", { class: "t-stack", style: { gap: "6px" } },
        ui.row([el("p", { class: "eyebrow t-text faint" }, title), ui.spacer(), opts.action]), children);
    },
    list(items, render, opts = {}) {
      if (!items.length) return ui.empty(opts.empty ?? "Nothing here yet.");
      return el("ul", { class: "t-list" }, items.map((item, i) => el("li", {}, render(item, i))));
    },
    table(columns, rows, opts = {}) {
      if (!rows.length) return ui.empty(opts.empty ?? "Nothing here yet.");
      return el("table", { class: "t-table" },
        el("thead", {}, el("tr", {}, columns.map((c) => el("th", { style: { textAlign: c.align ?? "left", width: c.width } }, c.label)))),
        el("tbody", {}, rows.map((row) => el("tr", {}, columns.map((c) =>
          el("td", { style: { textAlign: c.align ?? "left" } }, c.render ? c.render(row) : row[c.key] ?? ""))))));
    },
    form(fields, onSubmit, opts = {}) {
      const inputs = {};
      const controls = fields.map((f) => {
        let input;
        if (f.type === "select") {
          input = el("select", { name: f.name }, (f.options ?? []).map((o) => {
            const [value, label] = Array.isArray(o) ? o : [o, o];
            return el("option", { value, selected: String(f.value ?? "") === String(value) }, label);
          }));
        } else if (f.type === "textarea") {
          input = el("textarea", { name: f.name, placeholder: f.placeholder ?? "", rows: 2 }, f.value ?? "");
        } else {
          input = el("input", { name: f.name, type: f.type ?? "text", placeholder: f.placeholder ?? "", required: f.required, value: f.value ?? "", step: f.type === "number" ? "any" : undefined });
        }
        inputs[f.name] = input;
        return el("label", { class: `t-field${f.wide ? " t-wide" : ""}` }, f.label ? el("span", {}, f.label) : null, input);
      });
      const form = el("form", { class: "t-form" }, controls,
        el("button", { class: "t-button t-primary", type: "submit" }, opts.submitLabel ?? "Add"));
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const values = {};
        for (const f of fields) {
          const raw = inputs[f.name].value;
          values[f.name] = f.type === "number" ? (raw === "" ? null : Number(raw)) : raw.trim();
        }
        try {
          await onSubmit(values);
          if (opts.reset !== false) form.reset();
        } catch (e) {
          report(e);
        }
      });
      return form;
    },
    inlineAdd(placeholder, onSubmit, opts = {}) {
      const input = el("input", { placeholder, "aria-label": placeholder });
      const form = el("form", { class: "t-inline-add" }, input, opts.button ? el("button", { type: "submit" }, opts.button) : null);
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const value = input.value.trim();
        if (!value) return;
        try {
          await onSubmit(value);
          input.value = "";
        } catch (e) {
          report(e);
        }
      });
      return form;
    },
    checkbox(checked, onChange, label) {
      const input = el("input", { type: "checkbox", checked: !!checked });
      input.addEventListener("change", () => Promise.resolve(onChange(input.checked)).catch(report));
      return el("label", { class: "t-check" }, input, label ? el("span", {}, label) : null);
    },
    select(options, value, onChange) {
      const node = el("select", { class: "t-select" }, options.map((o) => {
        const [v, label] = Array.isArray(o) ? o : [o, o];
        return el("option", { value: v, selected: String(v) === String(value) }, label);
      }));
      node.addEventListener("change", () => Promise.resolve(onChange(node.value)).catch(report));
      return node;
    },
    empty: (text) => el("div", { class: "t-empty" }, text),
    stat: (label, value) => el("div", { class: "t-stat" }, el("div", { class: "t-stat-value tabular" }, value), el("div", { class: "t-stat-label" }, label)),
    progress(value, opts = {}) {
      const pct = Math.max(0, Math.min(1, value)) * 100;
      return el("div", { class: "t-progress" }, el("div", { style: { width: `${pct}%`, background: opts.color } }));
    },
    split: (left, right, opts = {}) => el("div", { class: "t-split", style: { gridTemplateColumns: opts.columns ?? "3fr 2fr" } }, left, right),
    agentChip(text, onClick, opts = {}) {
      const node = el("button", { class: `t-agent-chip${opts.attention ? " t-attention" : ""}`, title: opts.title, type: "button" }, text);
      if (onClick) node.addEventListener("click", guarded(onClick, node));
      return node;
    },
    link: (text, url) => el("a", { href: url, class: "t-link", title: url }, text),
  };

  // ---------- graphics ----------

  function svgNode(tag, attrs = {}, children = []) {
    const node = document.createElementNS(SVG_NS, tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null) continue;
      if (key === "onClick") {
        node.addEventListener("click", value);
        node.style.cursor = "pointer";
      } else if (key === "title") {
        const t = document.createElementNS(SVG_NS, "title");
        t.textContent = value;
        node.append(t);
      } else if (typeof value === "string" && value.startsWith("var(")) node.style.setProperty(key, value);
      else node.setAttribute(key, String(value));
    }
    append(node, children);
    return node;
  }

  const draw = {
    colors: {
      accent: "var(--topic)", text: "var(--ink)", muted: "var(--muted)", line: "var(--line)", surface: "var(--surface)",
      soil: "#8a6a4f", leaf: "#4f9a58", water: "#4a8fd1", sun: "#e3b23c", bloom: "#d1608a",
    },
    svg: (width, height, children, opts = {}) => svgNode("svg", { viewBox: opts.viewBox ?? `0 0 ${width} ${height}`, class: "t-svg", preserveAspectRatio: "xMidYMid meet" }, children),
    group: (children, opts = {}) => svgNode("g", { transform: opts.transform, opacity: opts.opacity }, children),
    rect: (o) => svgNode("rect", { x: o.x, y: o.y, width: o.w, height: o.h, rx: o.r ?? 0, fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.strokeWidth, opacity: o.opacity, onClick: o.onClick, title: o.title }),
    circle: (o) => svgNode("circle", { cx: o.cx, cy: o.cy, r: o.r, fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.strokeWidth, opacity: o.opacity, onClick: o.onClick, title: o.title }),
    line: (o) => svgNode("line", { x1: o.x1, y1: o.y1, x2: o.x2, y2: o.y2, stroke: o.stroke ?? "var(--line)", "stroke-width": o.strokeWidth ?? 1, "stroke-dasharray": o.dash }),
    path: (o) => svgNode("path", { d: o.d, fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.strokeWidth, onClick: o.onClick, title: o.title }),
    text(o) {
      const node = svgNode("text", { x: o.x, y: o.y, "font-size": o.size ?? 12, "text-anchor": o.anchor ?? "start", "dominant-baseline": o.baseline ?? "middle", fill: o.fill ?? "var(--ink)", "font-weight": o.weight, onClick: o.onClick });
      node.textContent = o.text;
      return node;
    },
  };

  // ---------- primitives ----------

  const db = {
    query: (sql, params = []) => call("db.query", { sql, params }),
    exec: (sql, params = []) => call("db.exec", { sql, params }),
    one: async (sql, params = []) => (await db.query(sql, params))[0] ?? null,
  };

  const schedule = {
    add: (entry) => call("schedule.add", entry),
    remove: (id) => call("schedule.remove", { id }),
    list: (days = 14) => call("schedule.list", { days }),
  };

  const proposals = {
    async byRef() {
      const map = {};
      for (const p of await call("proposals.list")) if (p.ref && !map[p.ref]) map[p.ref] = p;
      return map;
    },
    list: () => call("proposals.list"),
    open: (id) => (window.__board ? window.__board.openProposal(id) : call("proposals.open", { id })),
  };

  const agent = {
    ask: (text) => call("agent.ask", { text }),
    assign: (task, ref) => call("agent.assign", { task, ref }),
  };

  function report(error) {
    const message = error && error.stack ? error.stack : String(error);
    call("log", { level: "error", message }).catch(() => {});
    toast(String((error && error.message) || error));
  }

  function toast(text, opts = {}) {
    if (window.__board) window.__board.toast(text, opts.undo);
    else call("toast", { text }).catch(() => {});
  }

  function confirmAction(opts) {
    if (window.__board) return window.__board.confirm(opts);
    return Promise.resolve(window.confirm(opts.title));
  }

  function forModule(module) {
    return {
      topic: window.__topic,
      module,
      ui, draw, db, schedule, proposals, agent,
      toast,
      confirm: confirmAction,
      openLink: (url) => call("open", { url }),
      refresh: () => window.__board && window.__board.renderModule(module.id),
      card: { meta: (text) => window.__board && window.__board.setMeta(module.id, text) },
      today() {
        const d = new Date();
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
      },
      formatDate(iso, opts = { weekday: "short", month: "short", day: "numeric" }) {
        if (!iso) return "";
        const d = new Date(iso.length === 10 ? `${iso}T12:00:00` : iso);
        return isNaN(d) ? iso : d.toLocaleDateString(undefined, opts);
      },
      money(n) {
        if (n === null || n === undefined || n === "") return "";
        const v = Number(n);
        return `$${v.toLocaleString("en-US", { minimumFractionDigits: v % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;
      },
    };
  }

  window.Topics = { ui, draw, el, report, toast, call, forModule };
  window.__modules = {};
  window.__register = (id, fn) => {
    window.__modules[id] = typeof fn === "function" ? fn : fn && fn.render;
  };
  window.addEventListener("error", (e) => call("log", { level: "error", message: String(e.message) }).catch(() => {}));
  window.addEventListener("unhandledrejection", (e) => report(e.reason));
})();
