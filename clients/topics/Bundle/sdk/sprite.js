// Pixel helpers: each topic's helper is a small pixel person, wearing the
// topic's colour, with a look (hair, skin) derived from its name so Fern
// always looks like Fern. `Topics.sprite(name, tint)` returns an element;
// the board animates it with CSS (idle bob, blink, busy bounce).
(() => {
  "use strict";
  const SVG = "http://www.w3.org/2000/svg";

  // 12 x 16 pixels. H hair, S skin, E eye, M mouth, T shirt, D shirt shade,
  // P trousers, B shoes, K cap brim.
  const BODY = [
    "............",
    "............",
    "...HHHHHH...",
    "..HHHHHHHH..",
    "..HSSSSSSH..",
    "..SSESSESS..",
    "..SSSSSSSS..",
    "...SSMMSS...",
    "....SSSS....",
    "..TTTTTTTT..",
    ".TTTTTTTTTT.",
    ".STTDTTDTTS.",
    "..TTTTTTTT..",
    "..PPPPPPPP..",
    "..PPP..PPP..",
    "..BBB..BBB..",
  ];
  const HAIR = {
    short: {},
    long: { 4: "..HSSSSSSH..", 5: ".HSSESSESSH.", 6: ".HSSSSSSSSH.", 7: ".H.SSMMSS.H.", 8: ".H..SSSS..H." },
    bun: { 0: ".....HH.....", 1: "....HHHH...." },
    cap: { 1: "...KKKKKK...", 2: "..KKKKKKKK..", 3: "..KKKKKKKKKK" },
    curly: { 1: "..H.H..H.H..", 2: "..HHHHHHHH..", 3: ".HHHHHHHHHH.", 4: ".HHSSSSSSHH." },
  };
  const STYLES = Object.keys(HAIR);
  const HAIRS = ["#2b1d14", "#5a3a22", "#a8652e", "#d9b26b", "#1a1a1a", "#7a3b2e"];
  const SKINS = ["#f2d1b3", "#e0b48f", "#b9835c", "#8a5a3b"];

  function hash(text) {
    let h = 2166136261;
    for (const c of text) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
    return h >>> 0;
  }

  function shade(hex, amount) {
    const v = parseInt(hex.replace("#", ""), 16);
    const ch = (s) => Math.max(0, Math.min(255, Math.round(((v >> s) & 255) * (1 - amount))));
    return `rgb(${ch(16)}, ${ch(8)}, ${ch(0)})`;
  }

  function sprite(name, tint, opts = {}) {
    const h = hash(name.toLowerCase());
    const style = STYLES[h % STYLES.length];
    const hair = HAIRS[(h >> 4) % HAIRS.length];
    const skin = SKINS[(h >> 8) % SKINS.length];
    const shirt = tint === "#0F0F0E" || tint === "#0f0f0e" ? "#3d3d39" : tint;
    const colours = { H: hair, S: skin, E: "#0f0f0e", M: "#7a2f22", T: shirt, D: shade(shirt, 0.25), P: "#3d3d39", B: "#0f0f0e", K: shade(shirt, 0.35) };
    const rows = BODY.map((row, i) => HAIR[style][i] ?? row);
    const scale = opts.scale ?? 4;
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 12 16");
    svg.setAttribute("width", String(12 * scale));
    svg.setAttribute("height", String(16 * scale));
    svg.setAttribute("shape-rendering", "crispEdges");
    svg.setAttribute("class", "px-sprite");
    svg.setAttribute("aria-hidden", "true");
    const eyes = document.createElementNS(SVG, "g");
    eyes.setAttribute("class", "px-eyes");
    rows.forEach((row, y) => [...row].forEach((c, x) => {
      if (c === ".") return;
      const r = document.createElementNS(SVG, "rect");
      r.setAttribute("x", String(x));
      r.setAttribute("y", String(y));
      r.setAttribute("width", "1");
      r.setAttribute("height", "1");
      r.setAttribute("fill", colours[c] ?? "#0f0f0e");
      if (c === "E") {
        // Skin under the eye, so a blink shows a closed lid.
        const lid = r.cloneNode();
        lid.setAttribute("fill", skin);
        svg.append(lid);
        eyes.append(r);
      } else svg.append(r);
    }));
    svg.append(eyes);
    return svg;
  }

  window.Topics = Object.assign(window.Topics || {}, { sprite });
})();
