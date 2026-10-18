// The contract between the shared shell and each mode (src/modes/*.ts).
import type { EditorView } from "@codemirror/view";

export type Mode = "latex" | "mermaid" | "markdown";
export type Theme = "light" | "dark";

export interface EditorApi {
  view: EditorView;
  text(): string;
  /** 1-based line and column of the main cursor. */
  cursor(): { line: number; col: number };
  /** Scroll a 1-based line into the middle of the editor, put the cursor there, flash it briefly. */
  revealLine(line: number): void;
  /** 1-based line at the top of the editor viewport (for scroll sync). */
  topLine(): number;
}

export interface Drawer {
  /** Bottom panel under editor + preview. Empty; the mode fills it. */
  el: HTMLElement;
  open(): void;
  close(): void;
  toggle(): void;
  isOpen(): boolean;
}

export interface ModeContext {
  mode: Mode;
  /** Right pane. Empty; the mode owns its contents. Scrolls nothing by itself (overflow hidden). */
  preview: HTMLElement;
  /** Toolbar slot (right side, before the theme toggle) for the mode's buttons. */
  toolbar: HTMLElement;
  /** Status-bar slot (right side) for compile status etc. */
  status: HTMLElement;
  drawer: Drawer;
  editor: EditorApi;
  /** Absolute path of the open file, or null when the folder has none yet. */
  file(): string | null;
  /** Absolute path of the project folder. */
  folder(): string;
  theme(): Theme;
  /** Each subscription returns an unsubscribe fn; the shell also drops them all on unmount. */
  onThemeChange(cb: (t: Theme) => void): () => void;
  /** Fires on every doc change, immediately. Debounce yourself. */
  onChange(cb: (text: string) => void): () => void;
  /** Fires after the editor switched to another file (also once right after mount if a file is open). */
  onFileOpened(cb: (path: string, text: string) => void): () => void;
  /** Fires when the editor scrolls (for preview sync). */
  onEditorScroll(cb: () => void): () => void;
  /** Open a file in the editor (saving the current one first); optionally reveal a 1-based line. */
  openFile(path: string, line?: number): Promise<void>;
  /** Save the open file now if dirty. */
  save(): Promise<boolean>;
  /** Global shortcut, captured before the editor sees it. Key format: "Mod-Enter", "Mod-Alt-j", "Mod-Shift-e", "Escape". */
  shortcut(key: string, run: () => void): () => void;
  /** Per-project persisted UI state (survives relaunch). Values must be JSON-serialisable. */
  state<T>(key: string): T | undefined;
  setState<T>(key: string, value: T): void;
  toast(message: string, kind?: "info" | "error"): void;
}

export interface ModeInstance {
  unmount(): void;
}

export type MountFn = (ctx: ModeContext) => ModeInstance;
