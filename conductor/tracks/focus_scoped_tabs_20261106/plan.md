# Implementation Plan: `focus_scoped_tabs_20261106`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [x] Task: Add `@(scenario)` executable specifications in `tests/spec_tabs.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [x] Add `@(scenario)` specs for tab header rendering, keyboard tab switching (`[`/`]`, `h`/`l`), and mouse click tab selection.
    - [x] Add `@(scenario)` specs verifying per-tab `Focus_Scope_Node` deep history ($H^*$) focus restoration when switching between tabs and back.

## Phase 2: Focus-Scoped Tab Bar (`bifrost/tabs.odin`)
- [x] Task: Implement `ui_tabs` and `Tabs_State`
    - [x] Implement declarative tab bar header layout, hit-testing, and keyboard/mouse tab switching.
    - [x] Integrate per-tab `.Focus_Scope` containers with `.Deep_History` ($H^*$) restoration on tab change.

## Phase 3: Showcase & Verification
- [x] Task: Integrate `ui_tabs` into `examples/widget_gallery/main.odin` and verify all test suites
    - [x] Organize `examples/widget_gallery/main.odin` workspaces or inspector panels with `ui_tabs`.
    - [x] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
