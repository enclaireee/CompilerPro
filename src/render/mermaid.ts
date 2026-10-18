// Shared Mermaid renderer: strict security, no HTML labels (keeps PNG export canvas untainted).
import mermaid from "mermaid";
import type { Theme } from "../types";

let inited: Theme | null = null;
let seq = 0;
let queue: Promise<unknown> = Promise.resolve();
// ponytail: insertion-order LRU-ish cache, 50 entries; fine for one user's documents.
const cache = new Map<string, string>();

function init(theme: Theme) {
  if (inited === theme) return;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: theme === "dark" ? "dark" : "default",
    htmlLabels: false,
    flowchart: { htmlLabels: false },
    fontFamily: "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
  });
  inited = theme;
}

/** Render to an SVG string. Throws with mermaid's message on syntax errors. Calls are serialized. */
export function renderMermaid(code: string, theme: Theme): Promise<string> {
  const key = theme + "\0" + code;
  const hit = cache.get(key);
  if (hit) return Promise.resolve(hit);
  const job = queue.then(async () => {
    init(theme);
    const id = "cpm" + ++seq;
    try {
      const { svg } = await mermaid.render(id, code);
      cache.set(key, svg);
      if (cache.size > 50) cache.delete(cache.keys().next().value!);
      return svg;
    } finally {
      // mermaid leaves its scratch/error nodes in <body> on failure
      document.getElementById(id)?.remove();
      document.getElementById("d" + id)?.remove();
    }
  });
  queue = job.catch(() => {});
  return job;
}

/** Rasterize an SVG string. `scale` multiplies its intrinsic size; `bg` fills behind it (e.g. "#fff"). */
export async function svgToPng(svg: string, scale = 2, bg?: string): Promise<Uint8Array> {
  const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
  const el = doc.documentElement;
  const vb = el.getAttribute("viewBox")?.split(/[\s,]+/).map(Number);
  const w = vb?.[2] || parseFloat(el.getAttribute("width") || "") || 800;
  const h = vb?.[3] || parseFloat(el.getAttribute("height") || "") || 600;
  el.setAttribute("width", String(w));
  el.setAttribute("height", String(h));
  el.style.maxWidth = "";
  const src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(new XMLSerializer().serializeToString(el));
  const img = new Image();
  img.src = src;
  await img.decode();
  const canvas = document.createElement("canvas");
  canvas.width = Math.ceil(w * scale);
  canvas.height = Math.ceil(h * scale);
  const g = canvas.getContext("2d")!;
  if (bg) { g.fillStyle = bg; g.fillRect(0, 0, canvas.width, canvas.height); }
  g.drawImage(img, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise<Blob>((ok, err) => canvas.toBlob((b) => (b ? ok(b) : err(new Error("PNG encode failed"))), "image/png"));
  return new Uint8Array(await blob.arrayBuffer());
}
