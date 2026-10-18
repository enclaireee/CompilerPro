// LaTeX mode: latexmk compile + pdf.js preview + SyncTeX; math-only snippets preview live with KaTeX.
import "./latex.css";
import katex from "katex";
import {
  basename, cancelCompile, cleanBuild, compile, copyFile, dirname, exists, pickSave, readBytes,
  synctexEdit, synctexView, texRoot, type CompileResult,
} from "../api";
import { icon, iconButton } from "../icons";
import { createPdfViewer, type PdfViewer, type ViewState } from "../pdf";
import { esc, h } from "../shell";
import type { MountFn } from "../types";

// Strip % comments, split on blank lines, unwrap \[ \], $$ $$ and equation.
export function mathBlocks(text: string): string[] {
  return text.replace(/(^|[^\\])%.*$/gm, "$1").split(/\n\s*\n/).map((b) => b.trim())
    .map((b) => b.replace(/^\\\[([\s\S]*)\\\]$/, "$1").replace(/^\$\$([\s\S]*)\$\$$/, "$1")
      .replace(/^\\begin\{(equation\*?)\}([\s\S]*)\\end\{\1\}$/, "$2").trim())
    .filter(Boolean);
}

export const mount: MountFn = (ctx) => {
  let rootPath: string | null = null; // the compiled root .tex, null in snippet mode
  let pdfPath: string | null = null;
  let compiling = false;
  let snippet = false;
  let result: CompileResult | null = null;
  let viewer: PdfViewer | null = null;
  let openTok = 0;
  let dead = false;
  let snipT = 0;
  const offs: (() => void)[] = [];

  // ----- preview -----
  const box = h("div", "tex-preview");
  const viewHost = h("div", "pdf-host");
  const emptyEl = h("div", "empty", '<p>Press <span class="kbd">⌘↵</span> to compile</p>');
  const snipEl = h("div", "tex-snippet");
  const hint = h("p", "tex-hint", "Snippet: no \\documentclass, previewing math. Add one to compile.");
  const paper = h("div", "tex-paper");
  snipEl.append(hint, paper);
  box.append(viewHost, emptyEl, snipEl);
  ctx.preview.append(box);
  const setView = (v: "pdf" | "empty" | "snippet") => {
    viewHost.hidden = v !== "pdf";
    emptyEl.hidden = v !== "empty";
    snipEl.hidden = v !== "snippet";
  };
  setView("empty");

  const ensureViewer = () => viewer ??= createPdfViewer(viewHost, {
    ...ctx.state<ViewState>("tex.view"),
    onView: (s) => ctx.setState("tex.view", s),
    onEdit: async (page, x, y) => {
      if (!pdfPath) return;
      const loc = await synctexEdit(pdfPath, page, x, y).catch(() => null);
      if (loc) ctx.openFile(loc.file, loc.line); else ctx.toast("No source found for that spot");
    },
  });
  const dropViewer = () => { viewer?.destroy(); viewer = null; };

  async function showPdf(path: string) {
    try {
      const bytes = await readBytes(path);
      if (dead || path !== pdfPath) return;
      setView("pdf"); // visible before load so fit-width measures a real width
      await ensureViewer().load(bytes);
    } catch (e) { ctx.toast(`Couldn't show PDF: ${e}`, "error"); }
  }

  // ----- invert (dark mode) -----
  let invert = ctx.state<boolean>("tex.invert") ?? ctx.theme() === "dark";
  const invBtn = iconButton("invert", "Invert PDF colours", () => {
    invert = !invert;
    ctx.setState("tex.invert", invert);
    paintInvert();
  });
  const paintInvert = () => {
    box.classList.toggle("invert", invert);
    invBtn.setAttribute("aria-pressed", String(invert));
  };
  paintInvert();
  offs.push(ctx.onThemeChange((t) => {
    if (ctx.state<boolean>("tex.invert") === undefined) { invert = t === "dark"; paintInvert(); }
  }));

  // ----- toolbar -----
  const syncBtn = iconButton("sync", "Show in PDF ⌥⌘J", () => syncForward());
  const exportBtn = iconButton("download", "Export PDF", () => exportPdf());
  const runBtn = h("button", "btn primary");
  runBtn.type = "button";
  runBtn.addEventListener("click", () => run());
  const paintRun = () => {
    runBtn.innerHTML = compiling
      ? `${icon("stop", 14)}<span class="spinner"></span>Stop`
      : `${icon("play", 14)}Compile <span class="kbd">⌘↵</span>`;
    runBtn.setAttribute("aria-label", compiling ? "Stop compiling" : "Compile");
  };
  paintRun();
  ctx.toolbar.append(syncBtn, exportBtn, invBtn, runBtn);

  // ----- status bar -----
  const chip = h("button", "chip");
  chip.type = "button";
  chip.title = "Toggle problems and log";
  chip.addEventListener("click", () => ctx.drawer.toggle());
  const info = h("span");
  ctx.status.prepend(chip, info);
  const setChip = (cls: string, html: string) => { chip.className = "chip " + cls; chip.innerHTML = html; };
  setChip("", "Ready");

  // ----- drawer -----
  const dr = h("div", "tex-drawer");
  const tabs = h("div", "tabs");
  tabs.setAttribute("role", "tablist");
  const tabProblems = h("button", "tab active", "Problems");
  const tabLog = h("button", "tab", "Raw log");
  const cleanBtn = h("button", "btn", `${icon("trash", 14)}Clean build`);
  [tabProblems, tabLog].forEach((t) => { t.type = "button"; t.setAttribute("role", "tab"); });
  cleanBtn.type = "button";
  tabs.append(tabProblems, tabLog, cleanBtn);
  const body = h("div", "tex-body");
  const logEl = h("pre", "tex-log");
  logEl.tabIndex = 0;
  dr.append(tabs, body);
  ctx.drawer.el.append(dr);
  let tab: "problems" | "log" = "problems";

  function paintDrawer() {
    tabProblems.classList.toggle("active", tab === "problems");
    tabLog.classList.toggle("active", tab === "log");
    tabProblems.setAttribute("aria-selected", String(tab === "problems"));
    tabLog.setAttribute("aria-selected", String(tab === "log"));
    if (tab === "log") {
      logEl.textContent = result?.log || "No log yet.";
      body.replaceChildren(logEl);
      return;
    }
    const diags = [...(result?.diagnostics ?? [])].sort((a, b) => +a.warning - +b.warning); // errors first
    if (!diags.length) {
      body.replaceChildren(h("div", "empty", result ? "No problems" : "Compile to see problems"));
      return;
    }
    const list = h("div", "list");
    for (const d of diags) {
      const b = h("button", "list-item tex-diag " + (d.warning ? "warn" : "err"),
        `<span class="sev">${d.warning ? "warn" : "error"}</span>` +
        `<span class="loc">${esc(d.file ? basename(d.file) : "")}${d.line ? ":" + d.line : ""}</span>` +
        `<span class="msg">${esc(d.message)}</span>`);
      b.type = "button";
      b.addEventListener("click", () => { const f = d.file || rootPath; if (f) ctx.openFile(f, d.line || undefined); });
      list.append(b);
    }
    body.replaceChildren(list);
  }
  tabProblems.addEventListener("click", () => { tab = "problems"; paintDrawer(); });
  tabLog.addEventListener("click", () => { tab = "log"; paintDrawer(); });
  cleanBtn.addEventListener("click", async () => {
    if (!rootPath) return ctx.toast("Nothing to clean: this file has no \\documentclass");
    try {
      await cleanBuild(rootPath);
      pdfPath = null; result = null;
      dropViewer(); setView("empty"); setChip("", "Ready"); info.textContent = "";
      paintDrawer();
      ctx.toast("Build files removed");
    } catch (e) { ctx.toast(`Clean failed: ${e}`, "error"); }
  });
  paintDrawer();

  // ----- root tracking + previous PDF -----
  async function adopt(root: string | null, engine: string, path: string) {
    if (root === null) {
      if (!/\.(tex|ltx)$/i.test(path)) return; // .bib/.sty etc. keep the current preview
      if (!snippet) {
        snippet = true; rootPath = null; pdfPath = null; result = null;
        dropViewer(); setView("snippet"); setChip("", "Snippet"); info.textContent = ""; paintDrawer();
      }
      renderSnippet();
      return;
    }
    snippet = false;
    if (root === rootPath) return;
    rootPath = root; result = null; pdfPath = null;
    dropViewer(); setView("empty"); setChip("", "Ready"); info.textContent = engine; paintDrawer();
    const pdf = `${dirname(root)}/.build/${basename(root).replace(/\.[^.]+$/, "")}.pdf`;
    if (await exists(pdf).catch(() => false)) {
      if (dead || rootPath !== root) return;
      pdfPath = pdf;
      await showPdf(pdf);
    }
  }
  offs.push(ctx.onFileOpened(async (path) => {
    const tok = ++openTok;
    const r = await texRoot(path).catch(() => null);
    if (r && !dead && tok === openTok) await adopt(r.root, r.engine, path);
  }));

  // ----- snippet preview -----
  function renderSnippet() {
    const blocks = mathBlocks(ctx.editor.text());
    paper.replaceChildren(...blocks.map((src) => {
      const el = h("div", "tex-block");
      katex.render(src, el, { displayMode: true, throwOnError: false });
      return el;
    }));
  }
  offs.push(ctx.onChange(() => {
    if (!snippet) return;
    clearTimeout(snipT);
    snipT = window.setTimeout(renderSnippet, 250);
  }));

  // ----- compile -----
  function cancel() { cancelCompile().catch(() => {}); }

  async function run() {
    if (compiling) return cancel();
    const file = ctx.file();
    if (!file) return ctx.toast("Open a .tex file first");
    compiling = true;
    paintRun();
    setChip("busy", '<span class="spinner"></span>Compiling…');
    const offEsc = ctx.shortcut("Escape", cancel); // only while a compile runs, so Esc stays free in the editor
    try {
      await ctx.save();
      const r = await texRoot(file);
      if (!r.root) {
        await adopt(null, "", file);
        setChip("", "Snippet");
        return ctx.toast("No \\documentclass: this file previews as math only. Add one to compile.");
      }
      await adopt(r.root, r.engine, file);
      const res = await compile(r.root);
      result = res;
      const errs = res.diagnostics.filter((d) => !d.warning).length;
      const warns = res.diagnostics.length - errs;
      info.textContent = [res.engine || r.engine, warns ? `${warns} warning${warns > 1 ? "s" : ""}` : ""].filter(Boolean).join(" · ");
      if (res.cancelled) setChip("", "Cancelled");
      else if (res.ok) setChip("ok", `✓ ${(res.ms / 1000).toFixed(1)}s`);
      else setChip("err", `✗ ${errs} error${errs === 1 ? "" : "s"}`);
      paintDrawer();
      if (!res.ok && !res.cancelled) ctx.drawer.open();
      // A file switch during the compile may have adopted another root: don't show this PDF over it.
      if (res.pdf && !res.cancelled && rootPath === r.root) { pdfPath = res.pdf; await showPdf(res.pdf); }
    } catch (e) {
      setChip("err", "✗ failed");
      ctx.toast(`Compile failed: ${e}`, "error");
    } finally {
      offEsc();
      compiling = false;
      paintRun();
    }
  }

  // ----- sync + export -----
  async function syncForward() {
    const file = ctx.file();
    if (!pdfPath || !viewer || !file) return ctx.toast("Compile first to get a PDF");
    const c = ctx.editor.cursor();
    const spots = await synctexView(file, c.line, c.col, pdfPath).catch(() => []);
    if (spots.length) viewer.flash(spots); else ctx.toast("No matching position in the PDF");
  }

  async function exportPdf() {
    if (!pdfPath) return ctx.toast("Compile first to get a PDF");
    try {
      const dest = await pickSave(basename(pdfPath), ["pdf"], "export-pdf");
      if (!dest) return;
      await copyFile(pdfPath, dest);
      ctx.toast("Exported");
    } catch (e) { ctx.toast(`Export failed: ${e}`, "error"); }
  }

  // ----- shortcuts -----
  offs.push(
    ctx.shortcut("Mod-Enter", run),
    ctx.shortcut("Mod-Alt-j", syncForward),
    ctx.shortcut("Mod-=", () => viewer?.zoomBy(1.1)),
    ctx.shortcut("Mod--", () => viewer?.zoomBy(1 / 1.1)),
    ctx.shortcut("Mod-0", () => viewer?.fit()),
  );

  return {
    unmount() {
      dead = true;
      offs.forEach((f) => f());
      clearTimeout(snipT);
      dropViewer();
      box.remove();
      syncBtn.remove(); exportBtn.remove(); invBtn.remove(); runBtn.remove();
      chip.remove(); info.remove();
      dr.remove();
      ctx.drawer.close();
    },
  };
};
