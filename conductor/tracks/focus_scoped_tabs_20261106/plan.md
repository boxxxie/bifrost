# Implementation Plan: `focus_scoped_tabs_20261106`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_tabs.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for tab header rendering, keyboard tab switching (`[`/`]`, `h`/`l`), and mouse click tab selection.
    - [ ] Add `@(scenario)` specs verifying per-tab `Focus_Scope_Node` deep history ($H^*$) focus restoration when switching between tabs and back.

## Phase 2: Focus-Scoped Tab Bar (`bifrost/tabs.odin`)
- [ ] Task: Implement `ui_tabs` and `Tabs_State`
    - [ ] Implement declarative tab bar header layout, hit-testing, and keyboard/mouse tab switching.
    - [ ] Integrate per-tab `.Focus_Scope` containers with `.Deep_History` ($H^*$) restoration on tab change.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate `ui_tabs` into `examples/widget_gallery/main.odin` and verify all test suites
    - [ ] Organize `examples/widget_gallery/main.odin` workspaces or inspector panels with `ui_tabs`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
