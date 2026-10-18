// App entry: launcher ↔ workspace, Finder/drag-drop opens, session restore, recents.
import "katex/dist/katex.min.css";
import "./style.css";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { createDir, exists, pickFile, pickFolder, pickSave, takeOpened, texStatus, writeText, basename, dirname, extname } from "./api";
import logo from "./logo.svg?raw";
import { icon } from "./icons";
import { EXTS, MODE_NAME, esc, h, keyName, load, openWorkspace, store, theme, themeButton, toast, type Workspace } from "./shell";
import type { Mode } from "./types";

interface Recent { mode: Mode; folder: string; file: string | null; t: number }
interface Session { mode: Mode; folder: string; file: string | null }

const app = document.getElementById("app")!;
const MODES: Mode[] = ["latex", "mermaid", "markdown"];
const GLYPH: Record<Mode, string> = { latex: "tex", mermaid: "diagram", markdown: "markdown" };
/** Starter file for "New project…". */
const STARTER: Record<Mode, { name: string; text: string }> = {
  latex: { name: "main.tex", text: "\\documentclass{article}\n\\usepackage{amsmath}\n\n\\title{Untitled}\n\\author{}\n\n\\begin{document}\n\\maketitle\n\n\\section{Introduction}\n\n\n\\end{document}\n" },
  mermaid: { name: "diagram.mmd", text: "flowchart LR\n  A[Start] --> B[End]\n" },
  markdown: { name: "notes.md", text: "# Untitled\n\n" },
};
const BLURB: Record<Mode, string> = {
  latex: "Documents & math, compiled with TeX Live",
  mermaid: "Diagrams with live preview",
  markdown: "Notes with math and diagrams",
};

let ws: Workspace | null = null;
let busy: Promise<void> = Promise.resolve();
let launcherKeys: ((e: KeyboardEvent) => void) | null = null;
/** Serialize screen switches so overlapping opens (Finder + session restore) can't interleave. */
const serial = (f: () => Promise<void>) => (busy = busy.then(f).catch((e) => toast(String(e), "error")));

const modeFor = (path: string): Mode | null => MODES.find((m) => EXTS[m].includes(extname(path))) ?? null;

function remember(r: Omit<Recent, "t">) {
  const list = load<Recent[]>("cp.recents", []).filter((x) => !(x.folder === r.folder && x.mode === r.mode));
  store("cp.recents", [{ ...r, t: Date.now() }, ...list].slice(0, 10));
}

function enter(mode: Mode, folder: string, file: string | null) {
  return serial(async () => {
    if (ws && !(await ws.close())) return;
    if (launcherKeys) { window.removeEventListener("keydown", launcherKeys); launcherKeys = null; }
    ws = await openWorkspace(app, {
      mode, folder, file,
      onHome: goHome,
      onOpenFolder: async () => { const f = await pickFolder(folder); if (f) enter(mode, f, null); },
      onFile(path) {
        store("cp.session", { mode, folder, file: path } satisfies Session);
        remember({ mode, folder, file: path });
      },
    });
  });
}

function goHome() {
  return serial(async () => {
    if (ws && !(await ws.close())) return;
    ws = null;
    localStorage.removeItem("cp.session");
    renderLauncher();
  });
}

async function openPath(path: string) {
  const mode = modeFor(path);
  if (!mode) { toast(`CompilerPro opens .tex, .mmd and .md files (got ${basename(path)})`, "error"); return; }
  if (ws && ws.mode === mode && path.startsWith(ws.folder + "/")) return ws.openFile(path);
  await enter(mode, dirname(path), path);
}

async function startMode(mode: Mode) {
  const folder = await pickFolder();
  if (folder) enter(mode, folder, null);
}
async function startFile(mode: Mode) {
  const file = await pickFile(EXTS[mode]);
  if (file) enter(mode, dirname(file), file);
}

async function newProject(mode: Mode) {
  const dir = await pickSave("Untitled", [], "new-project");
  if (!dir) return;
  const file = `${dir}/${STARTER[mode].name}`;
  try {
    await createDir(dir);
    await writeText(file, STARTER[mode].text);
  } catch (e) { toast(`Couldn't create ${basename(dir)}: ${e}`, "error"); return; }
  enter(mode, dir, file);
}

function renderLauncher() {
  getCurrentWindow().setTitle("CompilerPro").catch(() => {});
  const root = h("main", "launcher");
  const drag = h("div", "drag-region");
  drag.dataset.tauriDragRegion = "";
  const corner = h("div");
  corner.style.cssText = "position:fixed;top:8px;right:10px";
  corner.append(themeButton());
  const mark = h("div", "logo", logo);
  mark.setAttribute("aria-hidden", "true");
  root.append(drag, corner, mark, h("h1", "", "CompilerPro"), h("p", "sub", "Write, compile and preview. Fully offline."));

  const cards = h("div", "cards");
  MODES.forEach((m, i) => {
    const card = h("div", "card");
    card.dataset.m = m;
    card.tabIndex = 0;
    card.setAttribute("role", "button");
    card.setAttribute("aria-label", `${MODE_NAME[m]}: open a folder`);
    card.innerHTML = `<span class="kbd">⌘${i + 1}</span><div class="glyph">${icon(GLYPH[m], 20)}</div><b>${MODE_NAME[m]}</b><span>${BLURB[m]}</span>`;
    const actions = h("div", "actions");
    const newLink = h("a", "", "New…");
    newLink.title = `New ${MODE_NAME[m]} project (⇧⌘${i + 1})`;
    newLink.addEventListener("click", (e) => { e.stopPropagation(); newProject(m); });
    const folderLink = h("a", "", "Open folder…");
    const fileLink = h("a", "", "Open file…");
    folderLink.addEventListener("click", (e) => { e.stopPropagation(); startMode(m); });
    fileLink.addEventListener("click", (e) => { e.stopPropagation(); startFile(m); });
    actions.append(newLink, folderLink, fileLink);
    card.append(actions);
    card.addEventListener("click", () => startMode(m));
    card.addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); startMode(m); } });
    cards.append(card);
  });
  root.append(cards);

  const recents = load<Recent[]>("cp.recents", []);
  if (recents.length) {
    const sec = h("section", "recents");
    sec.append(h("h2", "", "Recent"));
    const list = h("div", "list");
    for (const r of recents) {
      const b = h("button", "list-item");
      const label = basename(r.folder) + (r.file ? ` / ${basename(r.file)}` : "");
      b.innerHTML = `<span class="glyph">${icon(GLYPH[r.mode], 14)}</span><span class="name">${esc(label)}</span><span class="path">${esc(r.folder.replace(/^\/Users\/[^/]+/, "~"))}</span>`;
      b.title = `${MODE_NAME[r.mode]} — ${r.folder}`;
      b.addEventListener("click", async () => {
        if (!(await exists(r.folder))) {
          store("cp.recents", load<Recent[]>("cp.recents", []).filter((x) => x !== r && x.folder !== r.folder));
          toast(`${r.folder} no longer exists`, "error");
          renderLauncher();
          return;
        }
        enter(r.mode, r.folder, r.file);
      });
      list.append(b);
    }
    sec.append(list);
    root.append(sec);
  }

  const tex = h("p", "tex-banner");
  root.append(tex);
  texStatus().then((s) => {
    tex.textContent = s.found ? `TeX Live: ${s.path}` : "TeX Live not found. Install MacTeX to compile LaTeX documents (math snippets still preview).";
    tex.classList.toggle("missing", !s.found);
  }).catch(() => {});

  app.replaceChildren(root);
  launcherKeys = (e) => {
    const k = keyName(e);
    const i = ["Mod-1", "Mod-2", "Mod-3"].indexOf(k);
    const n = ["Mod-Shift-1", "Mod-Shift-2", "Mod-Shift-3"].indexOf(k);
    if (i >= 0) { e.preventDefault(); startMode(MODES[i]); }
    if (n >= 0) { e.preventDefault(); newProject(MODES[n]); }
  };
  window.addEventListener("keydown", launcherKeys);
}

async function boot() {
  theme.init();
  // Finder "Open With" / Dock drops. The event only signals; the buffer is the source of truth (no duplicates).
  // Cmd+Q (Rust holds the exit) and the red close button both ask about unsaved changes first.
  const requestQuit = () => serial(async () => {
    if (ws && !(await ws.close())) return;
    ws = null;
    await invoke("quit");
  });
  await listen("flush", requestQuit);
  await getCurrentWindow().onCloseRequested((e) => { e.preventDefault(); requestQuit(); });
  await listen("open-paths", async () => { for (const p of await takeOpened()) await openPath(p); });
  await getCurrentWebview().onDragDropEvent(async (e) => {
    if (e.payload.type === "drop") for (const p of e.payload.paths) await openPath(p);
  });
  const opened = await takeOpened();
  if (opened.length) { for (const p of opened) await openPath(p); return; }
  const s = load<Session | null>("cp.session", null);
  if (s && (await exists(s.folder))) return enter(s.mode, s.folder, s.file);
  renderLauncher();
}

boot();
