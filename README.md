# Margin

A native macOS editor for Markdown, JSON and LaTeX, with a live, editable preview
side by side with the source. Built with SwiftUI and AppKit, with **no external
dependencies** — no SwiftMath, no markdown library, no JSON library. Everything
renders through Apple's own frameworks (Foundation's markdown parser, Core Text,
Core Graphics).

## What it does

- **Editor / Split / Preview** modes (⌘1 / ⌘2 / ⌘3), with a locked-scrolling
  split view (⌘L) that keeps both panes aligned on scroll and on click.
- **The preview is editable.** Typing a plain-text change into the rendered
  pane edits the Markdown/JSON/LaTeX source directly, undo included.
- **Markdown** via Foundation's own markdown parser: headings, lists, tables,
  block quotes, code blocks, images, links, task lists — plus inline `$math$`,
  `$$display math$$` and fenced ` ```math ` blocks.
- **JSON**: a calm key/value outline (not just syntax-highlighted text), with
  nested objects and arrays shown as "3 fields" / "5 items", a clear banner
  with line/column when the JSON is invalid, and a *Format JSON* command that
  re-indents without touching key order or literal spelling.
- **LaTeX**: a genuine document preview, not just a math renderer — title
  pages, numbered sections (`\appendix`-aware), `abstract`, `itemize` /
  `enumerate` / `description`, `tabular`, `figure` / `table` with captions,
  `theorem`-style environments with auto-numbering, `proof` with a ∎, footnotes,
  `\cite` / bibliography, `\label` / `\ref` / `\eqref` resolved in a forward
  pass, `\newcommand` / `\def` / `\DeclareMathOperator` macro expansion, and
  TeX ligatures/accents (`--`, `` ``quotes'' ``, `\'e`, …).
- **Math typesetting is hand-written**, not a wrapper around a library: a
  small TeX-style box-layout engine on top of Core Text, covering fractions,
  `\sqrt[n]{}`, big operators with stacked limits in display style, stretchy
  `\left`/`\right` delimiters, accents (`\hat`, `\vec`, `\overbrace`, …),
  matrices/`cases`/`aligned`/`gathered`, and the math alphabets (`\mathbb`,
  `\mathcal`, `\mathbf`, …).
- Per-file-type syntax highlighting and formatting shortcuts in the editor
  (⌘B/⌘I/⌘E adapt between Markdown and LaTeX; list/`\item` continuation on
  Return).

## Building

No Xcode project, no dependencies to fetch — just Swift Package Manager:

```bash
./build.sh
```

This builds `build/Margin.app`. Pass `--install` to also copy it into
`/Applications`:

```bash
./build.sh --install
```

Requires macOS 14+ and a recent Xcode / Swift toolchain.

## Project layout

```
Sources/Margin/
  App.swift              — document type, menu commands
  ContentView.swift       — editor/preview layout, render scheduling
  EditorView.swift         — the editor pane + per-kind syntax highlighting
  PreviewPane.swift        — the editable preview pane
  PaneLink.swift           — keeps the two panes mapped and scroll-locked
  DocKind.swift            — picks a renderer by file extension
  MarkdownRenderer.swift   — Markdown → NSAttributedString
  JSONRenderer.swift       — JSON → NSAttributedString (+ formatter)
  LaTeXRenderer.swift      — LaTeX document → NSAttributedString
  MathRenderer.swift       — math image rendering + box model
  MathParser.swift         — LaTeX math → a node tree
  MathLayout.swift         — node tree → laid-out boxes
  MathSymbols.swift        — symbol table + math-alphabet Unicode mapping
```
