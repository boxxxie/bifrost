# Specification: Track 11 — Multi-Line Text Editor (`ui_text_area`), Collapsible Tree (`ui_tree`), Tab Bar (`ui_tabs`) & Braille/Sparkline Data-Viz Canvas (`ui_canvas`) (`multiline_editor_and_dataviz_widgets_20261106`)

## Overview
Expand `bifrost`'s widget suite with four rich interactive primitives for IDE-, inspector-, and observability-class TUI applications:
1. A grapheme-aware multi-line text area (`ui_text_area`) backed by a dynamic gap buffer / line index.
2. A virtualized collapsible tree / outline view (`ui_tree`) with $O(1)$ visible node budget.
3. A focus-scope-integrated tab bar (`ui_tabs`) that preserves per-tab deep focus history ($H^*$).
4. A zero-allocation Braille ($2\times 4$ sub-cell dots `U+2800..U+28FF`) and block sparkline (`▁▂▃▄▅▆▇█`) data-visualization canvas (`ui_canvas`, `ui_sparkline`).

## Reference Implementations
- `reference/imgui` (`imstb_textedit.h`, `imgui_widgets.cpp` — multi-line caret target column, selection ranges, and tab bars)
- `reference/lipgloss` (`tree/` — tree guide glyph rendering `├─`, `╰─`, `│`)
- `reference/ftxui` (`src/ftxui/dom/canvas.cpp` — $2\times 4$ Braille dot matrix encoding and line/series drawing)

## Functional Requirements

1. **Multi-Line Text Editor (`bifrost/text_area.odin`):**
   - Support dynamic UTF-8 buffers beyond `MAX_TEXT_BYTES :: 256` with incremental line-start byte offsets and `[row, col]` viewport scrolling (`scroll_row`, `scroll_col`).
   - Grapheme-cluster-accurate 2D caret movement (`Up`/`Down`/`Left`/`Right`, `Home`/`End`, `Ctrl+Home`/`Ctrl+End`, `Page_Up`/`Page_Down`, word motions) with sticky preferred display column across blank/short lines.
   - Multi-line visual selection (`Shift+Arrows`, `Ctrl+A`), zero-CGO OSC 52 multi-line copy/cut, bracketed paste insertion (`Paste_Event`), optional line-number gutter, and two-stage `.Navigation` vs. `.Editing` mode (`Enter`/`i` to edit, `Esc` to return to scope navigation).

2. **Virtualized Collapsible Tree & Scoped Tab Bar (`bifrost/tree.odin`, `bifrost/tabs.odin`):**
   - `ui_tree`: Virtualized hierarchical tree container supporting expand/collapse (`Enter`/`Space`/`l`/`h`), parent-node jump when pressing `h`/`Left` on a collapsed or leaf node, indentation guide glyphs (`├─`, `╰─`, `│`, `▸`/`▾`), and $O(1)$ layout node budget over large trees.
   - `ui_tabs`: Declarative tab header bar (`[ Tab 1 | Tab 2 | Tab 3 ]`) with keyboard (`[`/`]` or `h`/`l` on header) and mouse selection, wired into `Focus_Scope_Node` so each tab's body scope remembers its $H^*$ focused descendant across tab switches.

3. **Braille & Sparkline Data-Viz Canvas (`bifrost/canvas.odin`):**
   - `ui_canvas`: Immediate-mode sub-cell canvas mapping $(2W) \times (4H)$ virtual pixels into `Screen` cells via Unicode Braille patterns (`U+2800` + 8-bit dot mask), supporting points, Bresenham lines, rectangles, and time-series polylines with per-cell RGB foreground coloring.
   - `ui_sparkline`: Compact 1-row or multi-row vertical block bar renderer (`▁▂▃▄▅▆▇█`) for real-time actor telemetry and `xitdb` metrics.

4. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Add pure `@(scenario)` specifications in `tests/` covering multi-line editing/selection/scrolling, virtualized tree expand/collapse/parent-navigation, tab focus restoration, and Braille/sparkline cell rasterization.
   - Showcase `ui_text_area`, `ui_tree`, `ui_tabs`, and `ui_canvas`/`ui_sparkline` in `examples/widget_gallery` and `examples/log_monitor`.

## Acceptance Criteria
- All new widgets pass `odin run tools/bifrost_gen -- --atdd tests`, unit tests, and `@(scenario)` ATDD tests with zero per-frame heap leaks and full `vt_cells` ANSI diff equivalence.
