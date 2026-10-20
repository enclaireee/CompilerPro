# Proof — app icon and identity

**Name** Proof
**One line** LaTeX, Mermaid and Markdown, compiled on your Mac.
**Tagline** Source in. Page out.

---

## 1. The name

A proof is the printed sheet you check before an edition goes out. It is also the
thing a LaTeX document contains. One word, both meanings.

Apple names document apps with plain nouns — Pages, Notes, Preview, Books. Proof
belongs in that list. It replaces “CompilerPro”, which names the machinery and the
price tier and describes neither the page nor the reader.

Alternates considered: **Typeset** (descriptive, already used), **Manuscript** (longer,
no clearer), **Press** (right, but crowded). Proof won because it also means the maths.

Trademark and domain checks are **not** done. Do those before shipping the name.

## 2. The icon

A white page with a system-blue play button. The page is the document; the play is what
the app adds — press it and the source becomes the page.

- Built on Apple’s macOS icon grid: 1024 px canvas, 824 px rounded square,
  186 px corners, 100 px inset.
- Same light material as the iWork icons: white to `#F0F0F5`, a hairline edge and a
  soft shadow. No texture, no gradient on the glyph, no lettering.
- One accent only: system blue. The play button is the same control language as the
  run button in Xcode.
- Two cuts: standard from 64 px up, and a small-size cut at 16–32 px with a larger page,
  heavier rules and a bigger play button.

Rules: never outline, gradient, bevel or gloss the tile; never add the app name to the
icon; never use a colour other than system blue for the play button.

## 3. Colour

Use the system, not a palette.

| Role | Value | Use |
| --- | --- | --- |
| System blue | `#0071E3` light · `#0A84FF` dark | Play button, links, compile action |
| System grey | `#F5F5F7` | Sidebars, toolbars, alternating rows |
| Label | `#1D1D1F` / semantic | All text — use system label colours, not fixed hex |
| Teal | system | LaTeX badge |
| Pink | system | Mermaid badge |
| Indigo | system | Markdown badge |

The app keeps the user’s own macOS accent colour for standard controls. The brand blue
belongs to the icon and to the compile action, not to every button.

## 4. Type

SF Pro and SF Mono, as the app already uses. Nothing to license, nothing to embed.

- **SF Pro Display** — the wordmark and window titles, 28 px and up, Semibold,
  tracking −2 to −3 %.
- **SF Pro Text** — every control, label, menu, inspector. 13 pt body.
- **SF Mono** — the editor, line/column counters, shortcuts, paths. 13 pt.

## 5. Writing

Apple’s interface voice, not marketing copy.

- Say what happened and what to do next. “MacTeX is not installed.” “Compiled in 0.8 s.”
- Short sentences. Concrete numbers. No exclamation marks.
- Never: *supercharge, seamless, unlock, AI-powered, next-generation, oops*.
- Keep “Source in. Page out.” for the store listing and the website, not for dialogs.

## 6. Assets

```
brand/
  brand.md                     this file
  brand-board.html             icon and identity page (open in a browser)
  icon/
    proof-icon.svg             master, 1024 px grid
    proof-icon-small.svg       small-size cut (16–32 px)
    proof-icon-1024.png        rendered master
    proof-small-1024.png       rendered small cut
    AppIcon.icns               ready for Sources/Proof/Resources/AppIcon.icns
    Proof.iconset/             full macOS icon set
    old-compilerpro.png        the icon being replaced (for comparison)
```

## 7. Applying it to the app

Naming is cross-cutting: ~34 occurrences across 20 files, plus the package and target
names. Do it in one commit, separate from any visual work, so it can be reverted without
taking the design with it.

1. `Package.swift` — package, product and target names.
2. `Sources/CompilerPro` → `Sources/Proof`, `CompilerProCore` → `ProofCore`.
3. `CompilerProApp` → `ProofApp`; window title “Welcome to Proof”.
4. Welcome screen: `Text("CompilerPro")` → `Text("Proof")`.
5. `Resources/AppIcon.icns` → the new icon.
6. Keep the `cp.*` UserDefaults keys so existing settings survive, or migrate them once.
