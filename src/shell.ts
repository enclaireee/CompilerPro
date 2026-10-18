// Workspace frame shared by all modes: toolbar, sidebar (tree + outline), editor, splitters, status bar,
// drawer, quick-open, toasts, auto-save. Modes plug in via ModeContext (src/types.ts).
import { getCurrentWindow } from "@tauri-apps/api/window";
import { EditorView } from "@codemirror/view";
import { message } from "@tauri-apps/plugin-dialog";
import { readText, writeText, listTree, pickSave, basename, dirname, type Entry } from "./api";
import { createEditor } from "./editor";
import { icon, iconButton } from "./icons";
import type { Drawer, Mode, ModeContext, ModeInstance, MountFn, Theme } from "./types";

export const EXTS: Record<Mode, string[]> = {
  latex: ["tex", "bib", "sty", "cls", "ltx"],
  mermaid: ["mmd", "mermaid"],
  markdown: ["md", "markdown"],
};
export const MODE_NAME: Record<Mode, string> = { latex: "LaTeX", mermaid: "Mermaid", markdown: "Markdown" };
const MODE_ICON: Record<Mode, string> = { latex: "tex", mermaid: "diagram", markdown: "markdown" };
const TEMPLATE: Record<Mode, [string, string]> = {
  latex: ["untitled.tex", "\\documentclass{article}\n\\usepackage{amsmath}\n\n\\begin{document}\n\n\n\n\\end{document}\n"],
  mermaid: ["diagram.mmd", "flowchart LR\n  A[Start] --> B[End]\n"],
  markdown: ["notes.md", "# Notes\n\n"],
};
const loaders: Record<Mode, () => Promise<{ mount: MountFn }>> = {
  latex: () => import("./modes/latex"),
  mermaid: () => import("./modes/mermaid"),
  markdown: () => import("./modes/markdown"),
};

// ---------- small shared helpers ----------
export function h<K extends keyof HTMLElementTagNameMap>(tag: K, cls = "", html = ""): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (html) el.innerHTML = html;
  return el;
}
export const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
export const load = <T>(key: string, fallback: T): T => {
  try { const v = localStorage.getItem(key); return v ? (JSON.parse(v) as T) : fallback; } catch { return fallback; }
};
export const store = (key: string, v: unknown) => localStorage.setItem(key, JSON.stringify(v));

let toastBox: HTMLElement | null = null;
export function toast(message: string, kind: "info" | "error" = "info") {
  if (!toastBox) { toastBox = h("div", "toasts"); toastBox.setAttribute("role", "status"); document.body.append(toastBox); }
  const t = h("div", "toast" + (kind === "error" ? " error" : ""));
  t.textContent = message;
  toastBox.append(t);
  setTimeout(() => t.remove(), kind === "error" ? 6000 : 3000);
}

/** "Mod-Alt-j" style name for a keydown; uses e.code so Option doesn't turn j into ∆. */
export function keyName(e: KeyboardEvent): string {
  const c = e.code;
  const map: Record<string, string> = { Backslash: "\\", Slash: "/", Comma: ",", Period: ".", Equal: "=", Minus: "-", BracketLeft: "[", BracketRight: "]" };
  const k = c.startsWith("Key") ? c.slice(3).toLowerCase() : c.startsWith("Digit") ? c.slice(5) : map[c] ?? e.key;
  return (e.metaKey ? "Mod-" : "") + (e.ctrlKey ? "Ctrl-" : "") + (e.altKey ? "Alt-" : "") + (e.shiftKey ? "Shift-" : "") + k;
}

// ---------- theme (auto follows macOS; manual also flips native vibrancy) ----------
type Pref = "auto" | "light" | "dark";
const media = matchMedia("(prefers-color-scheme: dark)");
const themeSubs = new Set<(t: Theme) => void>();
let pref: Pref = load<Pref>("cp.theme", "auto");
let resolved: Theme = "light";
function applyTheme() {
  const next: Theme = pref === "auto" ? (media.matches ? "dark" : "light") : pref;
  document.documentElement.dataset.theme = next;
  if (next !== resolved) { resolved = next; themeSubs.forEach((cb) => cb(next)); }
}
media.addEventListener("change", () => pref === "auto" && applyTheme());
export const theme = {
  get: () => resolved,
  pref: () => pref,
  on(cb: (t: Theme) => void) { themeSubs.add(cb); return () => themeSubs.delete(cb); },
  async cycle() {
    pref = pref === "auto" ? "light" : pref === "light" ? "dark" : "auto";
    store("cp.theme", pref);
    await getCurrentWindow().setTheme(pref === "auto" ? null : pref).catch(() => {});
    applyTheme();
  },
  init() { getCurrentWindow().setTheme(pref === "auto" ? null : pref).catch(() => {}); applyTheme(); },
};
export function themeButton(): HTMLButtonElement {
  const b = iconButton("auto", "", () => theme.cycle().then(paint));
  const paint = () => {
    const p = theme.pref();
    b.innerHTML = icon(p === "auto" ? "auto" : p === "light" ? "sun" : "moon");
    b.title = `Appearance: ${p === "auto" ? "Match system" : p === "light" ? "Light" : "Dark"} (click to change)`;
    b.setAttribute("aria-label", b.title);
  };
  paint();
  return b;
}

// ---------- outline ----------
interface Heading { line: number; depth: number; title: string }
const TEX_LEVEL: Record<string, number> = { part: 0, chapter: 1, section: 2, subsection: 3, subsubsection: 4, paragraph: 5 };
function outlineOf(mode: Mode, text: string): Heading[] {
  const out: Heading[] = [];
  const lines = text.split("\n");
  let fence = false;
  lines.forEach((l, i) => {
    if (mode === "latex") {
      const m = /^\s*\\(part|chapter|section|subsection|subsubsection|paragraph)\*?\s*(?:\[[^\]]*\])?\{([^}]*)/.exec(l);
      if (m) out.push({ line: i + 1, depth: TEX_LEVEL[m[1]], title: m[2].trim() || m[1] });
    } else if (mode === "markdown") {
      if (/^\s*(```|~~~)/.test(l)) fence = !fence;
      const m = !fence && /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(l);
      if (m) out.push({ line: i + 1, depth: m[1].length, title: m[2] });
    }
  });
  const min = Math.min(...out.map((o) => o.depth));
  out.forEach((o) => (o.depth -= min));
  return out;
}

// ---------- splitter ----------
function splitter(el: HTMLElement, onMove: (clientX: number) => void, onReset: () => void, onDone: () => void) {
  el.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    el.setPointerCapture(e.pointerId);
    el.classList.add("dragging");
    document.body.classList.add("dragging-split");
    const move = (ev: PointerEvent) => onMove(ev.clientX);
    const up = () => {
      el.removeEventListener("pointermove", move);
      el.classList.remove("dragging");
      document.body.classList.remove("dragging-split");
      onDone();
    };
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up, { once: true });
  });
  el.addEventListener("dblclick", () => { onReset(); onDone(); });
}

// ---------- workspace ----------
export interface WorkspaceOpts {
  mode: Mode;
  folder: string;
  file: string | null;
  onHome(): void;
  onOpenFolder(): void;
  /** Called whenever the open file changes (for session restore + recents). */
  onFile(path: string | null): void;
}
export interface Workspace {
  mode: Mode;
  folder: string;
  openFile(path: string, line?: number): Promise<void>;
  /** False if the user cancelled (or the save failed): the workspace stays open. */
  close(): Promise<boolean>;
}

interface Layout { editor: number; sidebar: number; sidebarHidden: boolean }

export async function openWorkspace(root: HTMLElement, o: WorkspaceOpts): Promise<Workspace> {
  const { mode, folder } = o;
  document.documentElement.dataset.mode = mode;
  const layout = load<Layout>("cp.layout", { editor: 0.5, sidebar: 240, sidebarHidden: false });
  const saveLayout = () => store("cp.layout", layout);
  const cleanups: (() => void)[] = [];
  const listen = <K extends keyof WindowEventMap>(t: K, f: (e: WindowEventMap[K]) => void, cap = false) => {
    window.addEventListener(t, f, cap);
    cleanups.push(() => window.removeEventListener(t, f, cap));
  };

  // ----- DOM -----
  const ws = h("div", "workspace");
  const sidebar = h("aside", "sidebar");
  const sideTop = h("div", "sidebar-top");
  sideTop.dataset.tauriDragRegion = "";
  const treeHead = h("div", "section-title", `<span class="name">${esc(basename(folder))}</span>`);
  const newBtn = iconButton("plus", "New file (⌘N)", () => newFile());
  treeHead.append(newBtn);
  const tree = h("nav", "tree");
  tree.setAttribute("aria-label", "Files");
  const outlineHead = h("div", "section-title", "<span>Outline</span>");
  const outline = h("nav", "outline");
  outline.setAttribute("aria-label", "Outline");
  sidebar.append(sideTop, treeHead, tree);
  if (mode !== "mermaid") sidebar.append(outlineHead, outline);
  const sideSplit = h("div", "split split-side");

  const main = h("div", "main");
  const toolbar = h("header", "toolbar");
  toolbar.dataset.tauriDragRegion = "";
  const title = h("div", "title");
  title.dataset.tauriDragRegion = "";
  const crumb = h("span", "crumb");
  const fname = h("span", "name");
  const dirty = h("span", "dirty");
  dirty.title = "Unsaved changes";
  title.append(dirty, crumb, fname);
  const spacer = h("div", "spacer");
  spacer.dataset.tauriDragRegion = "";
  const modeSlot = h("div", "slot");
  const badge = h("span", "mode-badge", `${icon(MODE_ICON[mode], 13)}${MODE_NAME[mode]}`);
  toolbar.append(
    iconButton("sidebar", "Toggle sidebar (⌘\\)", () => toggleSidebar()),
    iconButton("home", "Home", () => o.onHome()),
    title, spacer, modeSlot, badge, themeButton(),
  );

  const panes = h("div", "panes");
  const editorPane = h("section", "editor-pane");
  const split = h("div", "split");
  split.title = "Drag to resize, double-click to reset";
  const preview = h("section", "preview-pane");
  panes.append(editorPane, split, preview);
  const drawerEl = h("div", "drawer");
  const status = h("footer", "statusbar");
  const pos = h("span");
  const saveState = h("span");
  const statusSlot = h("div", "slot");
  status.append(pos, saveState, statusSlot);
  main.append(toolbar, panes, drawerEl, status);
  ws.append(sidebar, sideSplit, main);
  root.replaceChildren(ws);

  const applyLayout = () => {
    ws.classList.toggle("no-sidebar", layout.sidebarHidden);
    ws.style.setProperty("--sidebar-w", layout.sidebar + "px");
    editorPane.style.flexBasis = layout.editor * 100 + "%";
  };
  applyLayout();
  const toggleSidebar = () => { layout.sidebarHidden = !layout.sidebarHidden; applyLayout(); saveLayout(); };
  splitter(split, (x) => {
    const r = panes.getBoundingClientRect();
    layout.editor = Math.min(0.8, Math.max(0.2, (x - r.left) / r.width));
    applyLayout();
  }, () => { layout.editor = 0.5; applyLayout(); }, saveLayout);
  splitter(sideSplit, (x) => {
    layout.sidebar = Math.min(420, Math.max(170, x));
    applyLayout();
  }, () => { layout.sidebar = 240; applyLayout(); }, saveLayout);

  const drawer: Drawer = {
    el: drawerEl,
    open: () => drawerEl.classList.add("open"),
    close: () => drawerEl.classList.remove("open"),
    toggle: () => drawerEl.classList.toggle("open"),
    isOpen: () => drawerEl.classList.contains("open"),
  };

  // ----- subscriptions -----
  const subs = { change: new Set<(t: string) => void>(), opened: new Set<(p: string, t: string) => void>(), scroll: new Set<() => void>() };
  const sub = <T>(set: Set<T>, cb: T) => { set.add(cb); return () => { set.delete(cb); }; };
  const shortcuts = new Map<string, () => void>();

  // ----- editor + saving -----
  let file: string | null = null;
  let saved = "";
  let saving: Promise<boolean> = Promise.resolve(true);
  const seen = new Set<string>();
  let outlineItems: Heading[] = [];
  let outlineTimer = 0;

  const editor = createEditor(editorPane, mode, {
    onChange(text) {
      markDirty();
      clearTimeout(outlineTimer);
      outlineTimer = window.setTimeout(renderOutline, 250);
      subs.change.forEach((cb) => cb(text));
    },
    onCursor() { paintCursor(); },
    onScroll() { subs.scroll.forEach((cb) => cb()); },
  });
  const isDirty = () => file !== null && editor.text() !== saved;
  const markDirty = () => {
    const d = isDirty();
    dirty.classList.toggle("on", d);
    saveState.textContent = file ? (d ? "Edited" : "Saved") : "";
  };
  const paintCursor = () => {
    const c = editor.cursor();
    pos.textContent = file ? `Ln ${c.line}, Col ${c.col}` : "";
    const cur = [...outlineItems].reverse().find((x) => x.line <= c.line);
    outline.querySelectorAll(".current").forEach((x) => x.classList.remove("current"));
    if (cur) outline.querySelector(`[data-line="${cur.line}"]`)?.classList.add("current");
  };

  /** Resolves false if the write failed (callers must not discard the buffer then). */
  async function save(): Promise<boolean> {
    saving = saving.then(async () => {
      if (!file || !isDirty()) return true;
      const text = editor.text();
      const path = file;
      try {
        await writeText(path, text);
        if (path === file) saved = text;
      } catch (e) {
        saveState.textContent = "Save failed";
        toast(`Couldn't save ${basename(path)}: ${e}`, "error");
        return false;
      }
      markDirty();
      return true;
    });
    return saving;
  }

  /** Before the buffer goes away: Save / Don't Save / Cancel. Resolves false to stay put. */
  async function settle(): Promise<boolean> {
    if (!isDirty()) return true;
    const r = await message(`Do you want to save the changes you made to ${basename(file!)}?`, {
      title: "Unsaved changes", kind: "warning",
      buttons: { yes: "Save", no: "Don't Save", cancel: "Cancel" },
    });
    if (r === "Save" || r === "Yes") return save();
    return r === "Don't Save" || r === "No";
  }

  const rememberCursor = () => { if (file) store("cp.cursor:" + file, editor.cursor()); };

  async function openFile(path: string, line?: number) {
    if (!(await settle())) return;
    rememberCursor();
    let text: string;
    // ponytail: CRLF is normalised to LF (CodeMirror does anyway); a CRLF file becomes LF on its first save.
    try { text = (await readText(path)).replace(/\r\n?/g, "\n"); } catch (e) { toast(`Couldn't open ${basename(path)}: ${e}`, "error"); return; }
    file = path;
    saved = text;
    editor.load(path, text);
    if (!seen.has(path)) {
      seen.add(path);
      const c = load<{ line: number; col: number } | null>("cp.cursor:" + path, null);
      const doc = editor.view.state.doc;
      if (c && !line && c.line <= doc.lines) {
        const at = Math.min(doc.line(c.line).from + c.col - 1, doc.line(c.line).to);
        editor.view.dispatch({ selection: { anchor: at }, effects: EditorView.scrollIntoView(at, { y: "center" }) });
      }
    }
    if (line) editor.revealLine(line);
    emptyEl?.remove();
    emptyEl = null;
    const rel = path.startsWith(folder + "/") ? path.slice(folder.length + 1) : basename(path);
    crumb.textContent = rel.includes("/") ? dirname(rel) + " / " : "";
    fname.textContent = basename(path);
    getCurrentWindow().setTitle(`${basename(path)} — CompilerPro`).catch(() => {});
    tree.querySelectorAll(".list-item.active").forEach((x) => x.classList.remove("active"));
    tree.querySelector(`[data-path="${CSS.escape(path)}"]`)?.classList.add("active");
    renderOutline();
    markDirty();
    paintCursor();
    o.onFile(path);
    subs.opened.forEach((cb) => cb(path, text));
    editor.view.focus();
  }

  // ----- tree -----
  let files: string[] = [];
  const closed = new Set<string>(load<string[]>(`cp.state:${folder}:tree.closed`, []));
  async function renderTree() {
    let entries: Entry[];
    try { entries = await listTree(folder, EXTS[mode]); } catch (e) { toast(`Couldn't read folder: ${e}`, "error"); entries = []; }
    files = [];
    const build = (list: Entry[], into: HTMLElement) => {
      for (const e of list) {
        if (e.dir) {
          const node = h("div", closed.has(e.path) ? "closed" : "open");
          const btn = h("button", "list-item", `${icon("chevron", 12).replace("<svg", '<svg class="chev"')}${icon("folder", 14)}<span class="name">${esc(e.name)}</span>`);
          btn.addEventListener("click", () => {
            const open = node.classList.toggle("open");
            node.classList.toggle("closed", !open);
            open ? closed.delete(e.path) : closed.add(e.path);
            store(`cp.state:${folder}:tree.closed`, [...closed]);
          });
          const kids = h("div", "children");
          build(e.children, kids);
          node.append(btn, kids);
          into.append(node);
        } else {
          files.push(e.path);
          const btn = h("button", "list-item" + (e.path === file ? " active" : ""), `${icon("file", 14)}<span class="name">${esc(e.name)}</span>`);
          btn.dataset.path = e.path;
          btn.title = e.path;
          btn.addEventListener("click", () => openFile(e.path));
          into.append(btn);
        }
      }
    };
    const frag = h("div", "list");
    build(entries, frag);
    tree.replaceChildren(frag);
    return files;
  }

  function renderOutline() {
    if (mode === "mermaid") return;
    outlineItems = file ? outlineOf(mode, editor.text()) : [];
    const list = h("div", "list");
    for (const it of outlineItems) {
      const b = h("button", "list-item");
      b.style.paddingLeft = 6 + it.depth * 12 + "px";
      b.dataset.line = String(it.line);
      b.innerHTML = `<span class="name">${esc(it.title)}</span>`;
      b.addEventListener("click", () => editor.revealLine(it.line));
      list.append(b);
    }
    if (!outlineItems.length) list.append(h("div", "list-item muted", file ? "No headings" : ""));
    outline.replaceChildren(list);
    paintCursor();
  }

  // ----- empty state -----
  let emptyEl: HTMLElement | null = null;
  function showEmpty() {
    emptyEl = h("div", "editor-empty");
    const box = h("div", "empty");
    const inner = h("div");
    inner.innerHTML = `<p>No ${EXTS[mode].slice(0, 2).map((x) => "." + x).join(" / ")} files in this folder yet.</p>`;
    const b = h("button", "btn primary", `${icon("plus", 14)}New file <span class="kbd">⌘N</span>`);
    b.addEventListener("click", () => newFile());
    inner.append(b);
    box.append(inner);
    emptyEl.append(box);
    editorPane.append(emptyEl);
  }

  async function newFile() {
    const [name, body] = TEMPLATE[mode];
    const path = await pickSave(`${folder}/${name}`, EXTS[mode].slice(0, 1));
    if (!path) return;
    try { await writeText(path, body); } catch (e) { toast(`Couldn't create file: ${e}`, "error"); return; }
    await renderTree();
    await openFile(path, mode === "latex" ? 6 : 2);
  }

  // ----- quick open (⌘P) -----
  let qo: HTMLElement | null = null;
  function quickOpen() {
    if (qo) return;
    const back = h("div", "quickopen-backdrop");
    const box = h("div", "quickopen");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "Open file");
    const input = h("input");
    input.placeholder = "Go to file…";
    input.setAttribute("aria-label", "File name");
    const list = h("div", "list");
    list.setAttribute("role", "listbox");
    box.append(input, list);
    back.append(box);
    document.body.append(back);
    qo = back;
    let sel = 0;
    let hits: string[] = [];
    const rel = (p: string) => p.slice(folder.length + 1);
    const score = (q: string, s: string) => { // subsequence match; lower = better
      let i = 0, gaps = 0, last = -1;
      for (let j = 0; j < s.length && i < q.length; j++) if (s[j] === q[i]) { if (last >= 0) gaps += j - last - 1; last = j; i++; }
      return i === q.length ? gaps + (s.length - last) * 0.01 : -1;
    };
    const paint = () => {
      const q = input.value.toLowerCase().replace(/\s+/g, "");
      hits = files.map((p) => [p, score(q, rel(p).toLowerCase())] as const).filter(([, s]) => s >= 0)
        .sort((a, b) => a[1] - b[1]).slice(0, 50).map(([p]) => p);
      sel = Math.min(sel, Math.max(0, hits.length - 1));
      list.replaceChildren(...hits.map((p, i) => {
        const b = h("button", "list-item" + (i === sel ? " sel" : ""), `${icon("file", 14)}<span class="name">${esc(basename(p))}</span><span class="muted name">${esc(rel(p).includes("/") ? dirname(rel(p)) : "")}</span>`);
        b.setAttribute("role", "option");
        b.addEventListener("click", () => pick(p));
        return b;
      }));
      if (!hits.length) list.append(h("div", "list-item muted", "No matching files"));
    };
    const close = () => { back.remove(); qo = null; editor.view.focus(); };
    const pick = (p: string) => { close(); openFile(p); };
    input.addEventListener("input", () => { sel = 0; paint(); });
    input.addEventListener("keydown", (e) => {
      if (e.key === "ArrowDown") { sel = Math.min(sel + 1, hits.length - 1); paint(); e.preventDefault(); }
      else if (e.key === "ArrowUp") { sel = Math.max(sel - 1, 0); paint(); e.preventDefault(); }
      else if (e.key === "Enter" && hits[sel]) pick(hits[sel]);
      else if (e.key === "Escape") close();
    });
    back.addEventListener("mousedown", (e) => e.target === back && close());
    paint();
    input.focus();
  }

  // ----- global keys (capture phase, before CodeMirror) -----
  const shellKeys: Record<string, () => void> = {
    "Mod-s": () => save(),
    "Mod-p": quickOpen,
    "Mod-\\": toggleSidebar,
    "Mod-n": newFile,
    "Mod-o": () => o.onOpenFolder(),
  };
  listen("keydown", (e) => {
    if (qo) return;
    const k = keyName(e);
    const run = shortcuts.get(k) ?? shellKeys[k];
    if (!run) return;
    e.preventDefault();
    e.stopPropagation();
    run();
  }, true);

  // ----- refresh on focus (saving is manual: ⌘S, or the prompt in settle()) -----
  listen("blur", rememberCursor);
  listen("focus", async () => {
    await renderTree();
    if (!file || isDirty()) return;
    const disk = await readText(file).then((t) => t.replace(/\r\n?/g, "\n"), () => null);
    if (disk !== null && disk !== saved) { // changed in another editor: take it
      const path = file;
      editor.drop(path);
      seen.add(path);
      await openFile(path);
    }
  });

  // ----- mode -----
  const ctx: ModeContext = {
    mode,
    preview,
    toolbar: modeSlot,
    status: statusSlot,
    drawer,
    editor,
    file: () => file,
    folder: () => folder,
    theme: () => theme.get(),
    onThemeChange: (cb) => { const off = theme.on(cb); cleanups.push(off); return off; },
    onChange: (cb) => sub(subs.change, cb),
    onFileOpened: (cb) => sub(subs.opened, cb),
    onEditorScroll: (cb) => sub(subs.scroll, cb),
    openFile,
    save,
    shortcut: (key, run) => { shortcuts.set(key, run); return () => { shortcuts.delete(key); }; },
    state: <T>(key: string) => load<T | undefined>(`cp.state:${folder}:${key}`, undefined),
    setState: (key, value) => store(`cp.state:${folder}:${key}`, value),
    toast,
  };

  const found = await renderTree();
  // Prefer the remembered file, else the shallowest main.* / first document file.
  const docs = found.filter((p) => EXTS[mode].slice(0, 2).includes(p.split(".").pop()!))
    .sort((a, b) => a.split("/").length - b.split("/").length || +!/\/main\.\w+$/.test(a) - +!/\/main\.\w+$/.test(b));
  const first = o.file && found.includes(o.file) ? o.file : docs[0] ?? null;
  let instance: ModeInstance | null = null;
  try {
    instance = (await loaders[mode]()).mount(ctx);
  } catch (e) {
    toast(`Couldn't start ${MODE_NAME[mode]} mode: ${e}`, "error");
  }
  if (first) await openFile(first); else { showEmpty(); renderOutline(); o.onFile(null); }

  return {
    mode,
    folder,
    openFile,
    async close() {
      if (!(await settle())) return false;
      rememberCursor();
      instance?.unmount();
      cleanups.forEach((f) => f());
      subs.change.clear(); subs.opened.clear(); subs.scroll.clear(); shortcuts.clear();
      qo?.remove();
      editor.destroy();
      delete document.documentElement.dataset.mode;
      return true;
    },
  };
}
