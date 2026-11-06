# Implementation Plan: `virtualized_collapsible_tree_20261106`

## Phase 1: Red-First `@(scenario)` ATDD Specifications
- [ ] Task: Add `@(scenario)` executable specifications in `tests/spec_tree.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`
    - [ ] Add `@(scenario)` specs for tree guide glyph rendering (`├─`, `╰─`, `│`, `▸`/`▾`) and expand/collapse toggling (`Enter`/`Space`/`l`/`h`).
    - [ ] Add `@(scenario)` specs for parent-node jump when pressing `h`/`Left` on a collapsed or leaf node.
    - [ ] Add `@(scenario)` specs verifying $O(1)$ virtualized `UI_Node` budget over a 10,000-node tree.

## Phase 2: Virtualized Collapsible Tree (`bifrost/tree.odin`)
- [ ] Task: Implement `ui_tree`, `Tree_State`, and visible-row virtualization
    - [ ] Implement flattened visible-row traversal, expand/collapse state tracking, and $O(1)$ viewport slicing.
    - [ ] Implement keyboard (`j`/`k`, `h`/`l`, `Enter`/`Space`) and mouse interaction, including parent jump on `h`/`Left`.
    - [ ] Implement box-drawing indentation guides (`├─`, `╰─`, `│`, `▸`/`▾`) and selection highlighting.

## Phase 3: Showcase & Verification
- [ ] Task: Integrate `ui_tree` into `examples/widget_gallery/main.odin` and verify all test suites
    - [ ] Showcase an interactive collapsible tree in `examples/widget_gallery/main.odin`.
    - [ ] Verify `odin run tools/bifrost_gen -- --atdd tests`, `odin test bifrost`, `odin test tests`, and Windows target checks pass with zero memory leaks.
