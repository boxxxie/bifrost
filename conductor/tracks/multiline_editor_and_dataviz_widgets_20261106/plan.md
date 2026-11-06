# Implementation Plan: `multiline_editor_and_dataviz_widgets_20261106`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for `ui_text_area` (2D grapheme motion, sticky target column, multi-line selection, OSC 52 copy/cut, bracketed paste, line-number gutter, two-stage edit mode).
    - [ ] Add `@(scenario)` specs for `ui_tree` (expand/collapse, parent jump on `h`, $O(1)$ virtualized node count) and `ui_tabs` (tab switching + $H^*$ focus restoration).
    - [ ] Add `@(scenario)` specs for `ui_canvas` ($2\times 4$ Braille dot bitmasking & line rasterization) and `ui_sparkline` (`▁▂▃▄▅▆▇█` scaling).

## Phase 2: Multi-Line Text Area (`bifrost/text_area.odin`)
- [ ] Task: Implement `ui_text_area` and `Text_Area_State`
    - [ ] Implement line-indexed UTF-8 editing, 2D grapheme caret navigation with sticky target column, multi-line selection, OSC 52 clipboard integration, and viewport scrolling with optional line-number gutter.

## Phase 3: Collapsible Tree (`bifrost/tree.odin`) & Scoped Tab Bar (`bifrost/tabs.odin`)
- [ ] Task: Implement `ui_tree` and `ui_tabs`
    - [ ] Implement virtualized `ui_tree` with expand/collapse state, box-drawing tree guides (`├─`, `╰─`, `│`), and keyboard/mouse navigation.
    - [ ] Implement `ui_tabs` integrated with `.Focus_Scope` deep history ($H^*$).

## Phase 4: Braille & Sparkline Canvas (`bifrost/canvas.odin`) & Example Updates
- [ ] Task: Implement `ui_canvas` and `ui_sparkline`, and integrate new widgets into `examples/`
    - [ ] Implement $2\times 4$ Unicode Braille bitmask rasterizer (`ui_canvas`) and 8-level block sparkline (`ui_sparkline`).
    - [ ] Showcase the new widgets in `examples/widget_gallery/main.odin` and `examples/log_monitor/main.odin`.
    - [ ] Verify all unit, codegen, and `@(scenario)` ATDD suites pass with zero memory leaks.
