// The Topics module runtime. Loaded into every module card before the
// module's own code. It provides the building blocks (`ui`), graphics
// (`draw`) and the primitives that cross into the app through the
// `topics` message handler (`db`, `schedule`, `agent`). Types for module
// authors are in topics-sdk.d.ts.
(() => {
  "use strict";

  const call = (op, args = {}) =>
    window.webkit.messageHandlers.topics.postMessage({ op, args });

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
      else if (key.startsWith("on") && typeof value === "function")
        node.addEventListener(key.slice(2).toLowerCase(), value);
      else if (key in node && typeof value !== "string") node[key] = value;
      else node.setAttribute(key, value === true ? "" : String(value));
    }
    append(node, children);
    return node;
  }

  // ---------- building blocks ----------

  const ui = {
    el,
    stack(children, opts = {}) {
      return el("div", { class: "t-stack", style: { gap: `${opts.gap ?? 10}px` } }, children);
    },
    row(children, opts = {}) {
      return el(
        "div",
        {
          class: "t-row",
          style: {
            gap: `${opts.gap ?? 8}px`,
            alignItems: opts.align ?? "center",
            justifyContent: opts.justify ?? "flex-start",
            flexWrap: opts.wrap ? "wrap" : "nowrap",
          },
        },
        children,
      );
    },
    spacer() {
      return el("div", { class: "t-spacer" });
    },
    heading(text, opts = {}) {
      return el(opts.level === 2 ? "h3" : "h2", { class: "t-heading" }, text);
    },
    text(text, opts = {}) {
      const cls = ["t-text", opts.muted && "t-muted", opts.small && "t-small", opts.strong && "t-strong"];
      return el("p", { class: cls.filter(Boolean).join(" ") }, text);
    },
    badge(text, tone = "neutral") {
      return el("span", { class: `t-badge t-tone-${tone}` }, text);
    },
    button(label, onClick, opts = {}) {
      const node = el(
        "button",
        {
          class: `t-button t-${opts.kind ?? "secondary"}${opts.small ? " t-small" : ""}`,
          title: opts.title,
          disabled: opts.disabled,
        },
        label,
      );
      node.addEventListener("click", async (event) => {
        event.preventDefault();
        if (node.disabled) return;
        node.disabled = true;
        try {
          await onClick(event);
        } catch (e) {
          report(e);
        } finally {
          if (node.isConnected) node.disabled = false;
        }
      });
      return node;
    },
    section(title, children, opts = {}) {
      return el(
        "section",
        { class: "t-section" },
        ui.row([el("h3", { class: "t-section-title" }, title), ui.spacer(), opts.action]),
        children,
      );
    },
    list(items, render, opts = {}) {
      if (!items.length) return ui.empty(opts.empty ?? "Nothing here yet.");
      return el("ul", { class: "t-list" }, items.map((item, i) => el("li", {}, render(item, i))));
    },
    table(columns, rows, opts = {}) {
      if (!rows.length) return ui.empty(opts.empty ?? "Nothing here yet.");
      return el(
        "table",
        { class: "t-table" },
        el("thead", {}, el("tr", {}, columns.map((c) => el("th", { style: { textAlign: c.align ?? "left" } }, c.label)))),
        el(
          "tbody",
          {},
          rows.map((row) =>
            el(
              "tr",
              {},
              columns.map((c) =>
                el("td", { style: { textAlign: c.align ?? "left" } }, c.render ? c.render(row) : row[c.key] ?? ""),
              ),
            ),
          ),
        ),
      );
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
          input = el("input", {
            name: f.name,
            type: f.type ?? "text",
            placeholder: f.placeholder ?? "",
            required: f.required,
            value: f.value ?? "",
            step: f.type === "number" ? "any" : undefined,
          });
        }
        inputs[f.name] = input;
        return el("label", { class: `t-field${f.wide ? " t-wide" : ""}` }, f.label ? el("span", {}, f.label) : null, input);
      });
      const form = el(
        "form",
        { class: `t-form${opts.inline ? " t-inline" : ""}` },
        controls,
        el("button", { class: "t-button t-primary", type: "submit" }, opts.submitLabel ?? "Add"),
      );
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
    checkbox(checked, onChange, label) {
      const input = el("input", { type: "checkbox", checked: !!checked });
      input.addEventListener("change", () => onChange(input.checked));
      return el("label", { class: "t-check" }, input, label ? el("span", {}, label) : null);
    },
    select(options, value, onChange) {
      const node = el("select", { class: "t-select" }, options.map((o) => {
        const [v, label] = Array.isArray(o) ? o : [o, o];
        return el("option", { value: v, selected: String(v) === String(value) }, label);
      }));
      node.addEventListener("change", () => onChange(node.value));
      return node;
    },
    empty(text) {
      return el("div", { class: "t-empty" }, text);
    },
    stat(label, value) {
      return el("div", { class: "t-stat" }, el("div", { class: "t-stat-value" }, value), el("div", { class: "t-stat-label" }, label));
    },
    progress(value) {
      const pct = Math.max(0, Math.min(1, value)) * 100;
      return el("div", { class: "t-progress" }, el("div", { style: { width: `${pct}%` } }));
    },
    agentChip(text, onClick, opts = {}) {
      const node = el(
        "button",
        { class: `t-agent-chip${opts.attention ? " t-attention" : ""}`, title: opts.title },
        el("span", { class: "t-agent-spark" }, "\u2726"),
        el("span", {}, text),
      );
      node.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();
        Promise.resolve(onClick && onClick(event)).catch(report);
      });
      return node;
    },
    link(text, url) {
      return el("a", { href: url, class: "t-link", title: url }, text);
    },
    split(left, right, opts = {}) {
      return el("div", { class: "t-split", style: { gridTemplateColumns: opts.columns ?? "3fr 2fr" } }, left, right);
    },
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
      } else if (typeof value === "string" && value.startsWith("var(")) {
        node.style.setProperty(key, value);
      } else node.setAttribute(key, String(value));
    }
    append(node, children);
    return node;
  }

  const draw = {
    colors: {
      accent: "var(--accent)",
      text: "var(--fg)",
      muted: "var(--muted)",
      line: "var(--border)",
      surface: "var(--surface)",
      soil: "#8a6a4f",
      leaf: "#4f9a58",
      water: "#4a8fd1",
      sun: "#e3b23c",
      bloom: "#d1608a",
    },
    svg(width, height, children, opts = {}) {
      return svgNode(
        "svg",
        { viewBox: opts.viewBox ?? `0 0 ${width} ${height}`, class: "t-svg", preserveAspectRatio: "xMidYMid meet" },
        children,
      );
    },
    group(children, opts = {}) {
      return svgNode("g", { transform: opts.transform, opacity: opts.opacity }, children);
    },
    rect(o) {
      return svgNode("rect", {
        x: o.x, y: o.y, width: o.w, height: o.h, rx: o.r ?? 0,
        fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.strokeWidth, opacity: o.opacity,
        onClick: o.onClick, title: o.title,
      });
    },
    circle(o) {
      return svgNode("circle", {
        cx: o.cx, cy: o.cy, r: o.r, fill: o.fill ?? "none", stroke: o.stroke,
        "stroke-width": o.strokeWidth, opacity: o.opacity, onClick: o.onClick, title: o.title,
      });
    },
    line(o) {
      return svgNode("line", {
        x1: o.x1, y1: o.y1, x2: o.x2, y2: o.y2, stroke: o.stroke ?? "var(--border)",
        "stroke-width": o.strokeWidth ?? 1, "stroke-dasharray": o.dash,
      });
    },
    path(o) {
      return svgNode("path", {
        d: o.d, fill: o.fill ?? "none", stroke: o.stroke, "stroke-width": o.strokeWidth, onClick: o.onClick, title: o.title,
      });
    },
    text(o) {
      const node = svgNode("text", {
        x: o.x, y: o.y, "font-size": o.size ?? 12, "text-anchor": o.anchor ?? "start",
        "dominant-baseline": o.baseline ?? "middle", fill: o.fill ?? "var(--fg)",
        "font-weight": o.weight, onClick: o.onClick,
      });
      node.textContent = o.text;
      return node;
    },
  };

  // ---------- primitives ----------

  const listeners = new Set();
  window.__topicsChanged = () => listeners.forEach((f) => f());

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
    open: (id) => call("proposals.open", { id }),
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

  function toast(text) {
    call("toast", { text }).catch(() => {});
  }

  const t = {
    topic: window.__topic,
    module: window.__module,
    ui,
    draw,
    db,
    schedule,
    agent,
    proposals,
    toast,
    onChange: (f) => listeners.add(f),
    refresh: () => rerender(),
    today() {
      const d = new Date();
      return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
    },
    formatDate(iso, opts = { weekday: "short", month: "short", day: "numeric" }) {
      if (!iso) return "";
      const d = new Date(iso.length === 10 ? `${iso}T12:00:00` : iso);
      return isNaN(d) ? iso : d.toLocaleDateString(undefined, opts);
    },
  };

  // ---------- boot ----------

  let renderFn = null;
  let rendering = false;
  let pending = false;

  async function rerender() {
    if (!renderFn) return;
    if (rendering) {
      pending = true;
      return;
    }
    rendering = true;
    const root = document.getElementById("root");
    try {
      const next = document.createElement("div");
      next.className = "t-module";
      await renderFn(next, t);
      const scroll = document.scrollingElement.scrollTop;
      root.replaceChildren(next);
      document.scrollingElement.scrollTop = scroll;
    } catch (e) {
      root.replaceChildren(el("div", { class: "t-error" }, el("strong", {}, "This module failed to render."), el("pre", {}, String((e && e.stack) || e))));
      call("log", { level: "error", message: String((e && e.stack) || e) }).catch(() => {});
    } finally {
      rendering = false;
      if (pending) {
        pending = false;
        rerender();
      }
    }
  }

  window.__boot = (fn) => {
    renderFn = typeof fn === "function" ? fn : fn && fn.render;
    listeners.add(rerender);
    rerender();
  };
  window.addEventListener("error", (e) => call("log", { level: "error", message: String(e.message) }).catch(() => {}));
  window.addEventListener("unhandledrejection", (e) => report(e.reason));
  window.Topics = t;
})();
