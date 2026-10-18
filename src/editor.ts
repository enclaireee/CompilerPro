// One CodeMirror view per workspace; one EditorState per file so undo history survives file switches.
import { EditorSelection, EditorState, type Extension } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter, drawSelection,
} from "@codemirror/view";
import { history, defaultKeymap, historyKeymap, indentWithTab, toggleComment } from "@codemirror/commands";
import { bracketMatching, indentOnInput, StreamLanguage, syntaxHighlighting } from "@codemirror/language";
import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { searchKeymap, highlightSelectionMatches } from "@codemirror/search";
import { markdown } from "@codemirror/lang-markdown";
import { stex } from "@codemirror/legacy-modes/mode/stex";
import { classHighlighter } from "@lezer/highlight";
import type { EditorApi, Mode } from "./types";

const latexLang = StreamLanguage.define({ ...stex, languageData: { commentTokens: { line: "%" } } });

// ponytail: tiny tokenizer (comments, keywords, strings, arrows); a real grammar only if this feels wrong.
const MERMAID_KW = /^(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram(-v2)?|erDiagram|gantt|pie|journey|gitGraph|mindmap|timeline|quadrantChart|xychart-beta|sankey-beta|block-beta|subgraph|end|participant|actor|loop|alt|else|opt|par|and|note|title|section|class|state|direction|style|classDef|linkStyle|click)\b/;
const mermaidLang = StreamLanguage.define<null>({
  token(s) {
    if (s.match("%%")) { s.skipToEnd(); return "comment"; }
    if (s.match(/^"[^"]*"?/)) return "string";
    if (s.match(MERMAID_KW)) return "keyword";
    if (s.match(/^[-=.ox<>]{2,}|^-->|^==>/)) return "operator";
    if (s.match(/^[\[\](){}|]/)) return "punctuation";
    if (s.match(/^\d+(\.\d+)?/)) return "number";
    s.next();
    return null;
  },
  languageData: { commentTokens: { line: "%%" } },
});

const wrap = (l: string, r: string) => (v: EditorView) => {
  v.dispatch(v.state.changeByRange((range) => ({
    changes: [{ from: range.from, insert: l }, { from: range.to, insert: r }],
    range: EditorSelection.range(range.from + l.length, range.to + l.length),
  })));
  return true;
};

function modeExtensions(mode: Mode): Extension[] {
  if (mode === "latex") return [latexLang, keymap.of([{ key: "Mod-b", run: wrap("\\textbf{", "}") }, { key: "Mod-i", run: wrap("\\textit{", "}") }])];
  if (mode === "markdown") return [markdown(), keymap.of([{ key: "Mod-b", run: wrap("**", "**") }, { key: "Mod-i", run: wrap("*", "*") }])];
  return [mermaidLang];
}

export interface Editor extends EditorApi {
  /** Switch to `path`; reuses that file's state (undo, selection) if seen before and text is unchanged. */
  load(path: string, text: string): void;
  /** Forget a file's state (e.g. reloaded from disk). */
  drop(path: string): void;
  destroy(): void;
}

export function createEditor(parent: HTMLElement, mode: Mode, hooks: {
  onChange(text: string): void;
  onCursor(): void;
  onScroll(): void;
}): Editor {
  const states = new Map<string, EditorState>();
  let current: string | null = null;

  const extensions: Extension[] = [
    lineNumbers(), highlightActiveLine(), highlightActiveLineGutter(), history(), drawSelection(),
    bracketMatching(), closeBrackets(), indentOnInput(), highlightSelectionMatches(),
    syntaxHighlighting(classHighlighter), EditorView.lineWrapping,
    keymap.of([
      ...closeBracketsKeymap, ...searchKeymap, ...historyKeymap, indentWithTab,
      { key: "Mod-/", run: toggleComment }, ...defaultKeymap,
    ]),
    modeExtensions(mode),
    EditorView.updateListener.of((u) => {
      if (u.docChanged) hooks.onChange(u.state.doc.toString());
      if (u.docChanged || u.selectionSet) hooks.onCursor();
    }),
  ];

  const view = new EditorView({ parent, state: EditorState.create({ doc: "", extensions }) });
  view.scrollDOM.addEventListener("scroll", () => hooks.onScroll(), { passive: true });

  const flash = (pos: number) => requestAnimationFrame(() => {
    const node = view.domAtPos(pos).node;
    const line = (node instanceof HTMLElement ? node : node.parentElement)?.closest(".cm-line");
    if (!line) return;
    line.classList.remove("cm-flash");
    void (line as HTMLElement).offsetWidth; // restart animation
    line.classList.add("cm-flash");
    setTimeout(() => line.classList.remove("cm-flash"), 1300);
  });

  return {
    view,
    text: () => view.state.doc.toString(),
    cursor() {
      const head = view.state.selection.main.head;
      const line = view.state.doc.lineAt(head);
      return { line: line.number, col: head - line.from + 1 };
    },
    revealLine(n) {
      const doc = view.state.doc;
      const line = doc.line(Math.min(Math.max(1, n), doc.lines));
      view.dispatch({ selection: { anchor: line.from }, effects: EditorView.scrollIntoView(line.from, { y: "center" }) });
      view.focus();
      flash(line.from);
    },
    topLine: () => view.state.doc.lineAt(view.lineBlockAtHeight(view.scrollDOM.scrollTop).from).number,
    load(path, text) {
      if (current) states.set(current, view.state);
      current = path;
      const prev = states.get(path);
      const state = prev && prev.doc.toString() === text ? prev : EditorState.create({ doc: text, extensions });
      view.setState(state);
      view.dispatch({ effects: EditorView.scrollIntoView(state.selection.main.head, { y: "center" }) });
    },
    drop(path) { states.delete(path); },
    destroy() { view.destroy(); states.clear(); },
  };
}
