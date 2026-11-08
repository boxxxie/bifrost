# Implementation Plan: `form_controls_20261108`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_form_controls.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for `ui_checkbox` and `ui_switch` toggling via `Space` and mouse clicks.
    - [ ] Add `@(scenario)` specs for `ui_radio_group` arrow-key cycling and exclusive selection state.
    - [ ] Add `@(scenario)` specs for `ui_slider` mouse drag scrub and keyboard step increments.
    - [ ] Add `@(scenario)` specs for `ui_dropdown` parent-anchored overlay promotion, option activation, and outside-click dismissal.

## Phase 2: Form Controls Implementation (`bifrost/form_controls.odin`)
- [ ] Task: Implement `ui_checkbox`, `ui_switch`, `ui_radio_group`, and `ui_slider`
    - [ ] Implement `ui_checkbox` with `[ ]` / `[x]` glyphs, focus outlines, and input handling.
    - [ ] Implement `ui_switch` with dual-state pill/box rendering and custom color schemes.
    - [ ] Implement `ui_radio_group` with horizontal/vertical flow and cyclic keyboard navigation.
    - [ ] Implement `ui_slider` with track fill glyphs, draggable thumb indicator, and numeric value formatting.
- [ ] Task: Implement `ui_dropdown` with Parent-Anchored Overlay
    - [ ] Implement closed-state header button and open/close state storage.
    - [ ] Implement open-state floating overlay at `z_layer = 10` with option list navigation and outside click dismissal.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate form controls into `examples/widget_gallery/main.odin` and verify all test suites
    - [ ] Add a interactive "Settings & Form Controls" tab/section in `examples/widget_gallery/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
