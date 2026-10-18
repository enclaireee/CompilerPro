// Mermaid mode: live preview on a pan/zoom canvas, last-good-render on errors, SVG/PNG export.
import { basename, pickSave, writeBytes, writeText } from "../api";
import { icon } from "../icons";
import { renderMermaid, svgToPng } from "../render/mermaid";
import { esc, h } from "../shell";
import type { MountFn } from "../types";
import "./mermaid.css";

interface View { x: number; y: number; k: number }
const MIN = 0.1, MAX = 8, PAD = 32;

export const mount: MountFn = (ctx) => {
  const root = h("div", "mmd-preview");
  root.tabIndex = 0;
  root.setAttribute("aria-label", "Diagram preview. Arrow keys pan, plus and minus zoom, zero fits.");
  const canvas = h("div", "mmd-canvas");
  const empty = h("div", "empty", "<p>Type a Mermaid diagram on the left to see it here.</p>");
  const banner = h("div", "banner error");
  banner.setAttribute("role", "alert");
  banner.hidden = true;
  root.append(canvas, empty, banner);
  // `click A href "..."` in a diagram must not navigate the app window away.
  canvas.addEventListener("click", (e) => { if ((e.target as Element).closest("a")) e.preventDefault(); });
  ctx.preview.replaceChildren(root);

  // ----- toolbar + status -----
  const btn = (ic: string, label: string, on: () => void) => {
    const b = h("button", "btn", `${icon(ic, 14)}${label}`);
    b.type = "button";
    b.setAttribute("aria-label", label);
    b.addEventListener("click", on);
    return b;
  };
  const zoomBtn = h("button", "btn mmd-zoom", "100%");
  zoomBtn.type = "button";
  zoomBtn.title = "Fit to window (⌘0)";
  zoomBtn.setAttribute("aria-label", "Zoom level, click to fit to window");
  zoomBtn.addEventListener("click", () => fit());
  const svgBtn = btn("download", "Export SVG", () => exportAs("svg"));
  const pngBtn = btn("download", "Export PNG", () => exportAs("png"));
  const white = h("input");
  white.type = "checkbox";
  white.checked = ctx.state<boolean>("white") ?? false;
  white.addEventListener("change", () => ctx.setState("white", white.checked));
  const whiteLabel = h("label", "", "White background");
  whiteLabel.prepend(white);
  const tools = h("div", "mmd-tools");
  tools.append(zoomBtn, svgBtn, pngBtn, whiteLabel);
  ctx.toolbar.append(tools);
  const chip = h("span", "chip");
  ctx.status.append(chip);

  // ----- pan / zoom -----
  let view: View = { x: 0, y: 0, k: 1 };
  let size = { w: 0, h: 0 }; // natural diagram size
  let needFit = true;
  let saveT = 0;
  const paint = () => {
    canvas.style.transform = `translate(${view.x}px,${view.y}px) scale(${view.k})`;
    zoomBtn.textContent = Math.round(view.k * 100) + "%";
    clearTimeout(saveT);
    saveT = window.setTimeout(() => { const f = ctx.file(); if (f && size.w) ctx.setState("view:" + f, view); }, 250);
  };
  const zoomAt = (k: number, cx: number, cy: number) => {
    k = Math.min(MAX, Math.max(MIN, k));
    const r = k / view.k;
    view = { x: cx - (cx - view.x) * r, y: cy - (cy - view.y) * r, k };
    paint();
  };
  const centre = (f: number) => { const r = root.getBoundingClientRect(); zoomAt(view.k * f, r.width / 2, r.height / 2); };
  const fit = () => {
    const r = root.getBoundingClientRect();
    if (!size.w || !r.width) return;
    const k = Math.min(MAX, Math.max(MIN, Math.min((r.width - 2 * PAD) / size.w, (r.height - 2 * PAD) / size.h, 2)));
    view = { x: (r.width - size.w * k) / 2, y: (r.height - size.h * k) / 2, k };
    paint();
  };
  const local = (e: { clientX: number; clientY: number }) => { const r = root.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };

  const onWheel = (e: WheelEvent) => {
    e.preventDefault();
    if (e.ctrlKey) { const [x, y] = local(e); zoomAt(view.k * Math.exp(-e.deltaY * 0.01), x, y); }
    else { view = { ...view, x: view.x - e.deltaX, y: view.y - e.deltaY }; paint(); }
  };
  root.addEventListener("wheel", onWheel, { passive: false });

  // Safari/WKWebView reports trackpad pinch as gesture events, not ctrl+wheel.
  let k0 = 1;
  const gStart = (e: Event) => { e.preventDefault(); k0 = view.k; };
  const gChange = (e: Event) => { e.preventDefault(); const g = e as Event & { scale: number; clientX: number; clientY: number }; const [x, y] = local(g); zoomAt(k0 * g.scale, x, y); };
  root.addEventListener("gesturestart", gStart);
  root.addEventListener("gesturechange", gChange);

  root.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || (e.target as Element).closest(".banner")) return;
    root.setPointerCapture(e.pointerId);
    root.classList.add("panning");
    root.focus();
    let px = e.clientX, py = e.clientY;
    const move = (ev: PointerEvent) => { view = { ...view, x: view.x + ev.clientX - px, y: view.y + ev.clientY - py }; px = ev.clientX; py = ev.clientY; paint(); };
    const up = () => { root.classList.remove("panning"); root.removeEventListener("pointermove", move); };
    root.addEventListener("pointermove", move);
    root.addEventListener("pointerup", up, { once: true });
    root.addEventListener("pointercancel", up, { once: true });
  });
  root.addEventListener("keydown", (e) => {
    const d: Record<string, [number, number]> = { ArrowLeft: [40, 0], ArrowRight: [-40, 0], ArrowUp: [0, 40], ArrowDown: [0, -40] };
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (d[e.key]) { view = { ...view, x: view.x + d[e.key][0], y: view.y + d[e.key][1] }; paint(); e.preventDefault(); }
    else if (e.key === "+" || e.key === "=") centre(1.25);
    else if (e.key === "-") centre(0.8);
    else if (e.key === "0") fit();
  });

  const offKeys = [
    ctx.shortcut("Mod-0", fit),
    ctx.shortcut("Mod-=", () => centre(1.25)),
    ctx.shortcut("Mod-Shift-=", () => centre(1.25)),
    ctx.shortcut("Mod--", () => centre(0.8)),
  ];

  // ----- rendering -----
  let good = { svg: "", code: "" }; // last successful render
  let seq = 0;
  let timer = 0;
  const setGood = (svg: string, code: string) => {
    good = { svg, code };
    svgBtn.disabled = pngBtn.disabled = !svg;
  };
  async function render(code: string) {
    const my = ++seq;
    if (!code.trim()) {
      setGood("", "");
      canvas.replaceChildren();
      size = { w: 0, h: 0 };
      empty.hidden = false;
      banner.hidden = true;
      chip.className = "chip";
      chip.textContent = "";
      return;
    }
    empty.hidden = true;
    try {
      const svg = await renderMermaid(code, ctx.theme());
      if (my !== seq) return;
      canvas.innerHTML = svg;
      const el = canvas.querySelector("svg")!;
      const vb = el.viewBox.baseVal;
      size = { w: vb.width || el.getBoundingClientRect().width, h: vb.height || el.getBoundingClientRect().height };
      el.setAttribute("width", String(size.w));
      el.setAttribute("height", String(size.h));
      el.style.maxWidth = "none";
      canvas.style.width = size.w + "px";
      canvas.style.height = size.h + "px";
      setGood(svg, code);
      banner.hidden = true;
      chip.className = "chip ok";
      chip.textContent = "✓ Rendered";
      if (needFit) { needFit = false; fit(); } // only first render without a saved view
      else paint();
    } catch (e) {
      if (my !== seq) return;
      // keep the previous good diagram; trim mermaid's noise to the first few lines
      const lines = String(e instanceof Error ? e.message : e).split("\n").map((l) => l.trimEnd())
        .filter((l) => l.trim() && !/^mermaid version/i.test(l));
      banner.innerHTML = esc(lines.slice(0, 4).join("\n"));
      banner.hidden = false;
      chip.className = "chip err";
      chip.textContent = "✗ Syntax error";
    }
  }

  // ----- export -----
  async function exportAs(kind: "svg" | "png") {
    if (!good.svg) return;
    const f = ctx.file();
    const stem = f ? basename(f).replace(/\.[^.]+$/, "") : "diagram";
    try {
      let svg = await renderMermaid(good.code, white.checked ? "light" : ctx.theme());
      svg = svg.replace(/background-color:[^;"]*;?/, ""); // transparent unless the PNG fill adds white
      if (!/<svg[^>]*\sxmlns=/.test(svg)) svg = svg.replace("<svg", '<svg xmlns="http://www.w3.org/2000/svg"');
      const path = await pickSave(`${stem}.${kind}`, [kind], "export-mermaid");
      if (!path) return;
      if (kind === "svg") await writeText(path, svg);
      else await writeBytes(path, await svgToPng(svg, 2, white.checked ? "#ffffff" : undefined));
      ctx.toast(`Exported ${basename(path)}`);
    } catch (e) {
      ctx.toast(`Export failed: ${e}`, "error");
    }
  }

  setGood("", "");
  const offs = [
    ctx.onChange((text) => { clearTimeout(timer); timer = window.setTimeout(() => render(text), 300); }),
    ctx.onThemeChange(() => render(ctx.editor.text())),
    ctx.onFileOpened((path, text) => {
      clearTimeout(timer);
      const saved = ctx.state<View>("view:" + path);
      needFit = !saved;
      if (saved) view = saved;
      setGood("", ""); // don't show or export the previous file's diagram
      canvas.replaceChildren();
      size = { w: 0, h: 0 };
      render(text).then(() => { if (saved && size.w) paint(); });
    }),
  ];

  return {
    unmount() {
      clearTimeout(timer);
      clearTimeout(saveT);
      seq++;
      [...offs, ...offKeys].forEach((f) => f());
      root.removeEventListener("wheel", onWheel);
      root.removeEventListener("gesturestart", gStart);
      root.removeEventListener("gesturechange", gChange);
      tools.remove();
      chip.remove();
      root.remove();
    },
  };
};
