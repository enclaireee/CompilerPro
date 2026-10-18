// Markdown mode: markdown-it + KaTeX + Mermaid fences, live preview with editor->preview scroll sync.
import MarkdownIt from "markdown-it";
import { katex } from "@mdit/plugin-katex";
import { readBytes, dirname, extname } from "../api";
import { esc, h, toast } from "../shell";
import { renderMermaid } from "../render/mermaid";
import type { MountFn } from "../types";
import "./markdown.css";

// html MUST stay false: a raw <script>/<img onerror> from a .md would run in a webview that can write files.
const md = new MarkdownIt({ html: false, linkify: true });
md.use(katex, { throwOnError: false });

const MIME: Record<string, string> = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", svg: "image/svg+xml", webp: "image/webp" };
const SCHEME = /^[a-z][a-z0-9+.-]*:/i;

// data-line on every block token, slug ids on headings, disabled checkboxes on task items.
md.core.ruler.push("cp_attrs", (state) => {
  const slugs = new Map<string, number>();
  const toks = state.tokens;
  toks.forEach((t, i) => {
    if (t.map && t.nesting !== -1 && t.block) t.attrSet("data-line", String(t.map[0] + 1));
    if (t.type === "heading_open") {
      const base = (toks[i + 1].content.toLowerCase().replace(/[^\p{L}\p{N}\s-]/gu, "").trim().replace(/\s+/g, "-")) || "section";
      const n = slugs.get(base) ?? 0;
      slugs.set(base, n + 1);
      t.attrSet("id", n ? `${base}-${n}` : base);
    }
    if (t.type === "inline" && toks[i - 1]?.type === "paragraph_open" && toks[i - 2]?.type === "list_item_open") {
      const m = /^\[([ xX])\] /.exec(t.content);
      const first = t.children?.[0];
      if (!m || first?.type !== "text") return;
      first.content = first.content.slice(4);
      const box = new state.Token("html_inline", "", 0);
      box.content = `<input type="checkbox" disabled${m[1] === " " ? "" : " checked"}> `;
      t.children!.unshift(box);
    }
  });
});

// Mermaid fences become placeholders (filled from env.known or asynchronously); other fences just get data-line.
const fence = md.renderer.rules.fence!;
md.renderer.rules.fence = (toks, i, opts, env, slf) => {
  const t = toks[i];
  const line = t.attrGet("data-line");
  if (t.info.trim() !== "mermaid") return fence(toks, i, opts, env, slf).replace("<pre", `<pre data-line="${line}"`);
  return `<div class="md-mermaid" data-line="${line}" data-code="${esc(t.content)}">${(env as { known: Map<string, string> }).known.get(t.content) ?? ""}</div>\n`;
};

// Local images: park the path in data-local; mount() swaps in a blob: URL.
const image = md.renderer.rules.image!;
md.renderer.rules.image = (toks, i, opts, env, slf) => {
  const t = toks[i];
  const src = String(t.attrGet("src") ?? "");
  if (!SCHEME.test(src) && !src.startsWith("//") && MIME[extname(src.split(/[?#]/)[0])]) {
    t.attrs = t.attrs!.filter(([k]) => k !== "src");
    t.attrSet("data-local", src);
  }
  return image(toks, i, opts, env, slf);
};

/** Join a relative path onto a directory, resolving . and .. */
function resolve(dir: string, rel: string): string {
  const out: string[] = [];
  for (const p of (rel.startsWith("/") ? rel : dir + "/" + rel).split("/")) {
    if (p === "..") out.pop(); else if (p && p !== ".") out.push(p);
  }
  return "/" + out.join("/");
}
const decode = (s: string) => { try { return decodeURIComponent(s); } catch { return s; } };

export const mount: MountFn = (ctx) => {
  const root = h("div", "md-preview");
  root.append(h("article", "md-body"));
  const body = root.firstElementChild as HTMLElement;
  ctx.preview.replaceChildren(root);

  let known = new Map<string, string>(); // mermaid code -> svg / error html
  const blobs = new Map<string, Promise<string>>(); // abs image path -> blob: URL
  let text = "";
  let timer = 0;
  let raf = 0;
  let lines: HTMLElement[] | null = null;

  function render() {
    const top = root.scrollTop;
    body.innerHTML = md.render(text, { known });
    root.scrollTop = top;
    lines = null;
    const cache = known; // a theme change swaps the map mid-render; don't write old-theme SVGs into the new one
    body.querySelectorAll<HTMLElement>(".md-mermaid:empty").forEach(async (el) => {
      const code = el.dataset.code!;
      let html: string;
      try { html = await renderMermaid(code, ctx.theme()); } catch (e) {
        html = `<div class="md-err">${esc(String((e as Error)?.message ?? e))}</div><pre><code>${esc(code)}</code></pre>`;
      }
      cache.set(code, html);
      if (el.isConnected) el.innerHTML = html;
    });
    const file = ctx.file();
    body.querySelectorAll<HTMLImageElement>("img[data-local]").forEach(async (img) => {
      const path = resolve(file ? dirname(file) : ctx.folder(), decode(img.dataset.local!.split(/[?#]/)[0]));
      if (!blobs.has(path)) {
        blobs.set(path, readBytes(path).then((b) => URL.createObjectURL(new Blob([b], { type: MIME[extname(path)] }))));
      }
      try { img.src = await blobs.get(path)!; } catch {
        blobs.delete(path);
        img.replaceWith(h("span", "md-img-fail", esc(img.alt || path)));
      }
    });
  }

  function sync() {
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(() => {
      lines ??= [...body.querySelectorAll<HTMLElement>("[data-line]")];
      if (!lines.length) return;
      const L = ctx.editor.topLine();
      const base = root.getBoundingClientRect().top - root.scrollTop;
      const at = (el: HTMLElement) => el.getBoundingClientRect().top - base;
      const n = (el: HTMLElement) => +el.dataset.line!;
      let a: HTMLElement | undefined;
      let b: HTMLElement | undefined;
      for (const el of lines) { if (n(el) <= L) a = el; else { b = el; break; } }
      const ya = a ? at(a) : 0;
      const la = a ? n(a) : 1;
      const yb = b ? at(b) : root.scrollHeight;
      const lb = b ? n(b) : ctx.editor.view.state.doc.lines + 1;
      root.scrollTop = ya + ((yb - ya) * (L - la)) / Math.max(1, lb - la);
    });
  }

  root.addEventListener("click", (e) => {
    const a = (e.target as Element).closest("a");
    if (!a) return;
    e.preventDefault(); // the webview must never navigate away
    const href = a.getAttribute("href") ?? "";
    const file = ctx.file();
    if (href.startsWith("#")) {
      body.querySelector(`[id="${CSS.escape(decode(href.slice(1)))}"]`)?.scrollIntoView();
    } else if (!SCHEME.test(href) && !href.startsWith("//") && ["md", "markdown"].includes(extname(href.split(/[?#]/)[0]))) {
      ctx.openFile(resolve(file ? dirname(file) : ctx.folder(), decode(href.split(/[?#]/)[0])));
    } else {
      navigator.clipboard.writeText(a.href).then(() => toast("Link copied"), () => toast("External links open in your browser — copy: " + a.href));
    }
  });

  const dropBlobs = () => { blobs.forEach((p) => p.then(URL.revokeObjectURL, () => {})); blobs.clear(); };
  // ponytail: images re-read on file open / window focus, not watched.
  window.addEventListener("focus", dropBlobs);
  const offs = [
    ctx.onChange((t) => { text = t; clearTimeout(timer); timer = window.setTimeout(render, 300); }),
    ctx.onFileOpened((_, t) => { dropBlobs(); text = t; clearTimeout(timer); root.scrollTop = 0; render(); sync(); }),
    ctx.onThemeChange(() => { known = new Map(); render(); }),
    ctx.onEditorScroll(sync),
  ];

  return {
    unmount() {
      offs.forEach((f) => f());
      clearTimeout(timer);
      cancelAnimationFrame(raf);
      window.removeEventListener("focus", dropBlobs);
      dropBlobs();
      ctx.preview.replaceChildren();
    },
  };
};
