# Specification: Track 18 — Word-Wrapped Rich Text Paragraph & Markdown Document Viewer (`ui_paragraph`, `ui_markdown`) (`rich_text_and_markdown_20261108`)

## Overview
Add read-only document rendering components to `bifrost` to present formatted prose, help pages, release notes, and documentation without requiring an editable `ui_text_area`:
1. `ui_paragraph`: A lightweight, zero-allocation read-only paragraph widget supporting soft word-wrapping (`Wrap_Mode.Word` / `.Char`), indentation, alignment (`.Left`, `.Center`, `.Right`), and heterogeneous inline styling spans (`Text_Span{text, fg, bg, style}`).
2. `ui_markdown`: A fast in-terminal Markdown document parser and renderer supporting ATX headers (`#`–`###`), unordered/ordered lists (`- `, `1. `), blockquotes (`> `), horizontal rules (`---`), and syntax-highlighted code fences (` ``` `).

## Reference Implementations
- `reference/ratatui` (`ratatui-widgets/src/paragraph.rs` — word wrap algorithm with whitespace trimming and span flow)
- `reference/lipgloss` (`style.go` — text alignment and margins)
- `bifrost/renderer.odin` (`Text_Style_Flags`, `string_display_width`)

## Functional Requirements

1. **Word-Wrapped Paragraph (`ui_paragraph` in `bifrost/paragraph.odin`):**
   - Spans: Accept a slice of `Text_Span`s (each with text, foreground, background, and style attributes such as `.Bold`, `.Italic`, `.Underline`).
   - Line Breaking:
     - Wrap at whitespace boundaries (`.Word`) without splitting mid-word unless a word exceeds the total available width (`.Char`).
     - Support explicit hard newlines (`\n`).
   - Sizing & Scrolling:
     - Intrinsic height computed from total wrapped line count.
     - Integration with `ui_virtual_list` or parent container scrolling when total lines exceed viewport height.
   - Text Alignment:
     - Support `.Left`, `.Center`, and `.Right` alignment on each wrapped line.

2. **Terminal Markdown Document Viewer (`ui_markdown` in `bifrost/paragraph.odin`):**
   - Parser:
     - Pure Odin single-pass scanner on `context.temp_allocator`.
     - Detect document elements:
       - Headers: `# H1` (bold underline + accent fg), `## H2` (bold), `### H3` (italic).
       - Bullet Lists: `- item` or `* item` with indented bullets (`• `).
       - Blockquotes: `> quote` rendered with left vertical bar (`│ `) and muted styling.
       - Inline styling: `**bold**`, `*italic*`, `` `inline code` ``.
       - Code Fences: ` ```lang ... ``` ` rendered in an indented boxed sub-container with syntax highlighting.
       - Horizontal Rules: `---` rendered as a line rule across container width.

3. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Pure `@(scenario)` specs in `tests/spec_paragraph.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Add a "Docs & Help" tab in `examples/widget_showcase/main.odin` displaying `README.md` and feature guides using `ui_markdown`.

## Acceptance Criteria
- `ui_paragraph` word wraps multi-byte UTF-8 text and wide East Asian characters with pixel-accurate display column widths.
- `ui_markdown` parses and formats structured markdown documents without any per-frame heap allocations.
- Passes all ATDD and unit tests under `-vet -strict-style`.
