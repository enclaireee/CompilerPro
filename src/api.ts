// Typed wrappers over the Rust commands in src-tauri/src/{lib,tex}.rs.
import { invoke } from "@tauri-apps/api/core";
import { open, save } from "@tauri-apps/plugin-dialog";

export interface Entry { name: string; path: string; dir: boolean; children: Entry[] }
export interface Diag { file: string; line: number; message: string; warning: boolean }
export interface CompileResult {
  ok: boolean;
  cancelled: boolean;
  /** Set when there is a PDF worth showing (TeX often still writes one despite errors). */
  pdf: string | null;
  diagnostics: Diag[];
  log: string;
  ms: number;
  engine: string;
}
/** Box in PDF points, origin top-left, y down. CSS px on a page = value * scale. */
export interface Spot { page: number; x: number; y: number; w: number; h: number }
export interface SourceLoc { file: string; line: number }

export const readText = (path: string) => invoke<string>("read_text", { path });
export const writeText = (path: string, contents: string) => invoke<void>("write_text", { path, contents });
export const writeBytes = (path: string, data: Uint8Array) => invoke<void>("write_bytes", { path, data: Array.from(data) });
export const readBytes = async (path: string) => new Uint8Array(await invoke<ArrayBuffer>("read_bytes", { path }));
export const copyFile = (from: string, to: string) => invoke<void>("copy_file", { from, to });
export const createDir = (path: string) => invoke<void>("create_dir", { path });
export const exists = (path: string) => invoke<boolean>("exists", { path });
export const listTree = (root: string, exts: string[]) => invoke<Entry[]>("list_tree", { root, exts });
export const takeOpened = () => invoke<string[]>("take_opened");

export const texRoot = (file: string) => invoke<{ root: string | null; engine: string }>("tex_root", { file });
export const texStatus = () => invoke<{ found: boolean; path: string | null }>("tex_status");
export const compile = (root: string) => invoke<CompileResult>("compile", { root });
export const cancelCompile = () => invoke<void>("cancel_compile");
export const cleanBuild = (root: string) => invoke<void>("clean_build", { root });
export const synctexView = (file: string, line: number, col: number, pdf: string) =>
  invoke<Spot[]>("synctex_view", { file, line, col, pdf });
export const synctexEdit = (pdf: string, page: number, x: number, y: number) =>
  invoke<SourceLoc | null>("synctex_edit", { pdf, page, x, y });

/** Native folder picker. */
export async function pickFolder(defaultPath?: string): Promise<string | null> {
  const r = await open({ directory: true, defaultPath });
  return typeof r === "string" ? r : null;
}

/** Native file picker limited to extensions. */
export async function pickFile(exts: string[], defaultPath?: string): Promise<string | null> {
  const r = await open({ directory: false, defaultPath, filters: [{ name: "Documents", extensions: exts }] });
  return typeof r === "string" ? r : null;
}

/** Native save dialog. `lastDirKey` remembers the folder per purpose (e.g. "export-pdf"). */
export async function pickSave(defaultName: string, exts: string[], lastDirKey?: string): Promise<string | null> {
  const remembered = lastDirKey ? localStorage.getItem("cp.lastdir:" + lastDirKey) : null;
  const defaultPath = remembered ? `${remembered}/${defaultName}` : defaultName;
  const r = await save({ defaultPath, filters: exts.length ? [{ name: exts[0].toUpperCase(), extensions: exts }] : undefined });
  if (r && lastDirKey) localStorage.setItem("cp.lastdir:" + lastDirKey, dirname(r));
  return r;
}

export const dirname = (p: string) => p.slice(0, Math.max(p.lastIndexOf("/"), 1));
export const basename = (p: string) => p.slice(p.lastIndexOf("/") + 1);
export const extname = (p: string) => {
  const b = basename(p);
  const i = b.lastIndexOf(".");
  return i > 0 ? b.slice(i + 1).toLowerCase() : "";
};
