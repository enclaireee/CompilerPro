// pdf.js viewer: lazy canvas pages, fit-width/zoom, flash-free swaps, SyncTeX click + highlight.
// Page sizes are in PDF points; CSS px on screen = pt * scale (y down, so no convertToViewportPoint).
import { GlobalWorkerOptions, getDocument, type PDFDocumentProxy, type RenderTask } from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import { h } from "./shell";
import type { Spot } from "./api";

GlobalWorkerOptions.workerSrc = workerUrl;

const GAP = 12, PAD = 16, MIN = 0.25, MAX = 6;

export interface ViewState { page: number; zoom: number | null }
export interface PdfViewer {
  load(bytes: Uint8Array): Promise<void>;
  zoomBy(factor: number): void;
  fit(): void;
  /** Scroll the first spot to the centre and flash a highlight on every spot. */
  flash(spots: Spot[]): void;
  destroy(): void;
}
export interface PdfOpts extends Partial<ViewState> {
  onView(s: ViewState): void;
  /** Double-click / Cmd+click, in PDF points on a 1-based page. */
  onEdit(page: number, x: number, y: number): void;
}

export function createPdfViewer(host: HTMLElement, o: PdfOpts): PdfViewer {
  const root = h("div", "pdf-scroll");
  root.tabIndex = 0;
  root.setAttribute("aria-label", "PDF preview");
  const pagesEl = h("div", "pdf-pages");
  const readout = h("div", "pdf-zoom");
  root.append(pagesEl);
  host.append(root, readout);

  let doc: PDFDocumentProxy | null = null;
  let sizes: [number, number][] = [];
  let scale = 1;
  let manual = o.zoom ?? 1;
  let fitMode = o.zoom == null;
  let restorePage: number | undefined = o.page; // applied once, on the first load
  let gen = 0; // bumps on every load/zoom so stale work bails out
  const tasks = new Map<HTMLElement, RenderTask>();
  const busy = new Set<HTMLElement>();
  const timers = new Set<number>();
  const later = (fn: () => void, ms: number) => {
    const t = window.setTimeout(() => { timers.delete(t); fn(); }, ms);
    timers.add(t);
    return t;
  };

  const fitScale = () => Math.min(MAX, Math.max(MIN, (root.clientWidth - 2 * PAD) / Math.max(1, ...sizes.map((s) => s[0]))));

  async function paint(d: PDFDocumentProxy, div: HTMLElement, s: number, g: number) {
    if (busy.has(div) || div.querySelector("canvas")) return;
    busy.add(div);
    try {
      const page = await d.getPage(Number(div.dataset.page));
      if (g !== gen) return;
      const vp = page.getViewport({ scale: s * (devicePixelRatio || 1) });
      const canvas = document.createElement("canvas");
      canvas.width = Math.floor(vp.width);
      canvas.height = Math.floor(vp.height);
      const task = page.render({ canvas, canvasContext: canvas.getContext("2d")!, viewport: vp });
      tasks.set(div, task);
      await task.promise;
      div.prepend(canvas);
    } catch { /* cancelled or document destroyed */ } finally {
      busy.delete(div);
      tasks.delete(div);
    }
  }

  // Render pages near the viewport; drop canvases that scrolled far away.
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      const div = e.target as HTMLElement;
      if (e.isIntersecting) { if (doc) paint(doc, div, scale, gen); }
      else { tasks.get(div)?.cancel(); div.querySelector("canvas")?.remove(); }
    }
  }, { root, rootMargin: "800px 0px" });

  // Build the new page boxes, render the visible ones off-screen, then swap in and restore scroll.
  async function show(g: number, page?: number) {
    const d = doc!, s = scale;
    const divs = sizes.map(([w, hh], i) => {
      const div = h("div", "pdf-page");
      div.dataset.page = String(i + 1);
      div.style.width = w * s + "px";
      div.style.height = hh * s + "px";
      return div;
    });
    const tops: number[] = [];
    let y = PAD;
    sizes.forEach(([, hh]) => { tops.push(y); y += hh * s + GAP; });
    const total = y - GAP + PAD;
    const target = page ? Math.max(0, tops[Math.min(page, tops.length) - 1] - PAD)
      : root.scrollHeight ? (root.scrollTop / root.scrollHeight) * total : 0;
    const view = root.clientHeight;
    await Promise.all(divs.filter((_, i) => tops[i] + sizes[i][1] * s > target - 300 && tops[i] < target + view + 300)
      .map((div) => paint(d, div, s, g)));
    if (g !== gen) return;
    io.disconnect();
    pagesEl.replaceChildren(...divs);
    root.scrollTop = target;
    divs.forEach((div) => io.observe(div));
    report();
  }

  const curPage = () => {
    const top = root.getBoundingClientRect().top + 8;
    const kids = [...pagesEl.children];
    const i = kids.findIndex((k) => k.getBoundingClientRect().bottom > top);
    return Math.max(1, (i < 0 ? kids.length : i + 1));
  };
  const state = (): ViewState => ({ page: curPage(), zoom: fitMode ? null : manual });
  const report = () => o.onView(state());

  function setScale(next: number | null) {
    if (!doc) return;
    fitMode = next === null;
    if (next !== null) manual = Math.min(MAX, Math.max(MIN, next));
    const ns = fitMode ? fitScale() : manual;
    readout.textContent = `${Math.round(ns * 75)}%${fitMode ? " (fit)" : ""}`; // 100% = 4/3 px per pt
    readout.classList.add("on");
    clearTimeout(hideT);
    hideT = later(() => readout.classList.remove("on"), 1000);
    if (Math.abs(ns - scale) < 0.001) return;
    scale = ns;
    show(++gen);
  }
  let hideT = 0;

  let scrollT = 0;
  root.addEventListener("scroll", () => { clearTimeout(scrollT); scrollT = later(report, 250); }, { passive: true });
  root.addEventListener("wheel", (e) => { // trackpad pinch arrives as ctrl+wheel
    if (!e.ctrlKey) return;
    e.preventDefault();
    setScale(scale * Math.exp(-e.deltaY * 0.01));
  }, { passive: false });

  let fitT = 0;
  const ro = new ResizeObserver(() => {
    if (!fitMode || !doc) return;
    clearTimeout(fitT);
    fitT = later(() => setScale(null), 150);
  });
  ro.observe(root);

  const onEdit = (e: MouseEvent) => {
    if (e.type === "click" && !e.metaKey) return;
    const div = (e.target as HTMLElement).closest<HTMLElement>(".pdf-page");
    if (!div) return;
    const r = div.getBoundingClientRect();
    o.onEdit(Number(div.dataset.page), (e.clientX - r.left) / scale, (e.clientY - r.top) / scale);
  };
  pagesEl.addEventListener("dblclick", onEdit);
  pagesEl.addEventListener("click", onEdit);

  return {
    async load(bytes) {
      const g = ++gen;
      const nd = await getDocument({ data: bytes.slice() }).promise; // pdf.js transfers the buffer, so hand it a copy
      const sz = await Promise.all(Array.from({ length: nd.numPages }, async (_, i) => {
        const v = (await nd.getPage(i + 1)).getViewport({ scale: 1 });
        return [v.width, v.height] as [number, number];
      }));
      if (g !== gen) { nd.loadingTask.destroy(); return; }
      const old = doc;
      doc = nd;
      sizes = sz;
      scale = fitMode ? fitScale() : manual;
      const page = restorePage;
      restorePage = undefined;
      await show(g, page);
      old?.loadingTask.destroy();
    },
    zoomBy: (f) => setScale(scale * f),
    fit: () => setScale(null),
    flash(spots) {
      const first = pagesEl.children[spots[0]?.page - 1] as HTMLElement | undefined;
      if (!first) return;
      const dy = first.getBoundingClientRect().top - root.getBoundingClientRect().top + spots[0].y * scale;
      root.scrollTo({ top: root.scrollTop + dy - root.clientHeight / 2, behavior: "smooth" });
      for (const sp of spots) {
        const div = pagesEl.children[sp.page - 1] as HTMLElement | undefined;
        if (!div) continue;
        const hl = h("div", "pdf-hl");
        hl.style.cssText = `left:${sp.x * scale}px;top:${sp.y * scale}px;width:${sp.w * scale}px;height:${Math.max(sp.h * scale, 10)}px`;
        div.append(hl);
        later(() => hl.classList.add("fade"), 1500);
        later(() => hl.remove(), 2100);
      }
    },
    destroy() {
      gen++;
      io.disconnect();
      ro.disconnect();
      timers.forEach(clearTimeout);
      tasks.forEach((t) => t.cancel());
      doc?.loadingTask.destroy();
      root.remove();
      readout.remove();
    },
  };
}
