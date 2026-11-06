# Implementation Plan: `multiline_text_area_20261106`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_text_area.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for 2D grapheme caret motion and sticky `preferred_col` across short/blank lines.
    - [ ] Add `@(scenario)` specs for multi-line editing (`Enter`, `Backspace` line merge), visual selection (`Shift+Arrows`, `Ctrl+A`), OSC 52 multi-line copy/cut, and bracketed `Paste_Event`.
    - [ ] Add `@(scenario)` specs for 2D viewport scrolling (`scroll_row`, `scroll_col`), line-number gutter rendering, and two-stage `.Navigation` / `.Editing` mode transitions.

## Phase 2: Multi-Line Text Editor (`bifrost/text_area.odin`)
- [ ] Task: Implement `ui_text_area` and `Text_Area_State`
    - [ ] Implement UTF-8 buffer management, line-start byte indexing, and `(row, display_col)` <-> byte offset conversion.
    - [ ] Implement 2D grapheme caret navigation with sticky `preferred_col`, multi-line visual selection, and OSC 52 / `Paste_Event` clipboard integration.
    - [ ] Implement 2D viewport scrolling (`scroll_row`, `scroll_col`), optional line-number gutter, and custom draw callback in `bifrost/renderer.odin` / `bifrost/text_area.odin`.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate `ui_text_area` into `examples/widget_gallery/main.odin` and verify all test suites
    - [ ] Add an interactive multi-line scratchpad / notes editor to `examples/widget_gallery/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
