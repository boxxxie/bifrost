# Specification: Track 11 — Multi-Line Text Editor (`ui_text_area`) (`multiline_text_area_20261106`)

## Overview
Add a grapheme-aware multi-line text area widget (`ui_text_area`, `Text_Area_State`) to `bifrost` backed by a dynamic UTF-8 buffer and incremental line-start byte index. Unlike the single-line `ui_text_input` (`MAX_TEXT_BYTES :: 256`), `ui_text_area` supports multi-line documents, 2D grapheme caret motion with a sticky preferred display column, multi-line visual selection, zero-CGO OSC 52 copy/cut, bracketed paste insertion, 2D viewport scrolling (`scroll_row`, `scroll_col`), optional line-number gutter, and two-stage `.Navigation` vs. `.Editing` mode.

## Reference Implementations
- `reference/imgui` (`imstb_textedit.h`, `imgui_widgets.cpp` — multi-line caret target column, line indexing, and selection ranges)
- `bifrost/text_input.odin` (single-line UTF-8 grapheme boundary navigation, visual selection, OSC 52 clipboard, and two-stage edit mode)

## Functional Requirements

1. **Dynamic UTF-8 Buffer & Line Index (`bifrost/text_area.odin`):**
   - Support multi-line UTF-8 buffers (`[dynamic]u8` or caller-provided backing buffer) with incremental or on-demand line-start byte offsets (`\n` boundaries).
   - Maintain 2D viewport scroll offsets (`scroll_row`, `scroll_col`) that automatically keep the active caret `(cursor_row, cursor_col)` visible within the content viewport.
   - Support an optional line-number gutter (`show_line_numbers: bool`) rendered with muted theme styling to the left of the text content area.

2. **2D Grapheme-Cluster Caret Navigation & Sticky Preferred Column:**
   - Horizontal movement (`Left`, `Right`, `Home`, `End`, `Ctrl+Left` / `Alt+B`, `Ctrl+Right` / `Alt+F`) steps by Unicode grapheme clusters (`unicode_string_width` / grapheme boundaries) and updates `preferred_col`.
   - Vertical movement (`Up`, `Down`, `Page_Up`, `Page_Down`) moves across lines while preserving `preferred_col` across blank or shorter lines so moving `Down` across an empty line and `Down` again restores the original horizontal display column.
   - Document-boundary motions (`Ctrl+Home`, `Ctrl+End`) jump to the start or end of the buffer.

3. **Multi-Line Selection, Editing, Clipboard & Two-Stage Mode:**
   - Support multi-line visual selection (`Shift+Up`/`Down`/`Left`/`Right`, `Shift+Home`/`End`, `Ctrl+A` select all) highlighted across all spanned lines.
   - Support newline insertion (`Enter`), `Tab` insertion (spaces), `Backspace` and `Delete` (merging lines across `\n` boundaries or deleting the active multi-line selection), `Ctrl+U` (delete to line start), `Ctrl+K` (delete to line end), and `Ctrl+W` (delete previous word).
   - Zero-CGO OSC 52 clipboard encoding (`Ctrl+C` copy, `Ctrl+X` cut) preserving `\n` line breaks, and bracketed `Paste_Event` insertion replacing any active selection.
   - Integrate with `bifrost`'s two-stage `.Navigation` vs. `.Editing` mode (`Enter` or `i` enters `.Editing`; `Esc` clears selection or exits `.Editing` back to `.Navigation` so `h`/`j`/`k`/`l` spatial navigation works seamlessly).

4. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Add pure `@(scenario)` specifications in `tests/spec_text_area.odin` and Layer 2 DSL helpers in `tests/dsl_bifrost.odin`.
   - Showcase `ui_text_area` in `examples/widget_gallery/main.odin`.

## Acceptance Criteria
- `ui_text_area` passes `odin run tools/bifrost_gen -- --atdd tests`, unit tests, and `@(scenario)` ATDD tests on Linux, macOS, and Windows with zero per-frame heap leaks and full `vt_cells` ANSI diff equivalence.
