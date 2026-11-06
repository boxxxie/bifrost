# Specification: Track 12 — Virtualized Collapsible Tree (`ui_tree`) (`virtualized_collapsible_tree_20261106`)

## Overview
Add a virtualized hierarchical tree / outline widget (`ui_tree`, `Tree_State`, `Tree_Node`) to `bifrost` that renders nested hierarchies with box-drawing indentation guides (`├─`, `╰─`, `│`, `▸`/`▾`), keyboard/mouse expand/collapse, parent-node jump navigation, and an $O(1)$ visible layout node budget over large trees.

## Reference Implementations
- `reference/lipgloss` (`tree/` — box-drawing tree guide glyph composition `├─`, `╰─`, `│`)
- `bifrost/scroll.odin` (`ui_virtual_list` — $O(1)$ viewport slicing and auto-scroll-into-view)

## Functional Requirements

1. **Virtualized Flattened Visible Row Window (`bifrost/tree.odin`):**
   - Represent hierarchical nodes with stable IDs, labels, depth/parent links, and expand/collapse state.
   - Materialize only the visible slice (`[first_visible .. last_visible]`) inside the scroll viewport so trees with thousands of nodes allocate $O(\text{visible\_rows})$ `UI_Node`s per frame.

2. **Tree Guide Glyphs & Indentation Rendering:**
   - Render ancestor continuation pipes (`│  ` or `   `), branch connectors (`├─ ` for intermediate siblings, `╰─ ` for the last sibling), and expand/collapse indicators (`▾ ` expanded, `▸ ` collapsed, or leaf prefix).

3. **Keyboard & Mouse Navigation:**
   - `Up`/`Down` (or `k`/`j`) moves between visible flattened tree rows and auto-scrolls the viewport to keep the selected node visible.
   - `Right` / `l` expands a collapsed branch node, or moves to its first child if already expanded.
   - `Left` / `h` collapses an expanded branch node, or jumps directly to its parent node if collapsed or on a leaf node.
   - `Enter` / `Space` toggles expand/collapse on branch nodes or activates leaf nodes; mouse left-click selects/toggles the clicked row.

4. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Add pure `@(scenario)` specifications in `tests/spec_tree.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Showcase `ui_tree` in `examples/widget_gallery/main.odin`.

## Acceptance Criteria
- `ui_tree` passes `odin run tools/bifrost_gen -- --atdd tests`, unit tests, and `@(scenario)` ATDD tests with $O(1)$ layout node count, zero per-frame heap leaks, and full `vt_cells` ANSI diff equivalence.
