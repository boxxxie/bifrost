# Specification: Track 13 — Focus-Scope-Integrated Tab Bar (`ui_tabs`) (`focus_scoped_tabs_20261106`)

## Overview
Add a declarative tab bar and tabbed container primitive (`ui_tabs`, `Tabs_State`) to `bifrost` that renders interactive tab headers (`[ Tab 1 | Tab 2 | Tab 3 ]`), supports keyboard (`[`/`]`, `h`/`l` on header) and mouse tab switching, and integrates directly with `Focus_Scope_Node` so each tab's body scope automatically preserves and restores its deep focused descendant ($H^*$) across tab switches.

## Reference Implementations
- `reference/imgui` (`imgui_widgets.cpp` — `BeginTabBar` / `BeginTabItem` state and active tab persistence)
- `bifrost/focus_scope.odin` (`Focus_Scope_Node`, `.Deep_History` / $H^*$ focus restoration)

## Functional Requirements

1. **Declarative Tab Header Bar & Active Tab State (`bifrost/tabs.odin`):**
   - Render a horizontal tab strip displaying tab labels, active tab indicator/underline or high-contrast pill styling, and optional badges or key hints.
   - Support switching tabs via mouse left-click on any tab header, keyboard `Left`/`Right` (`h`/`l`) when the tab header bar is focused, or global/scoped `[` / `]` (or `Alt+1..9`) tab-cycle actions.

2. **Automatic Per-Tab `Focus_Scope` Deep History ($H^*$):**
   - Bind each tab body to a stable per-tab `Focus_Scope_Node` (`restore_policy = .Deep_History`).
   - When switching from Tab A to Tab B and back to Tab A, automatically restore focus to the exact nested control (`last_focused_leaf_id` / $H^*$) that was active inside Tab A before the switch.

3. **4-Layer `@(scenario)` ATDD Specifications & Example Showcase:**
   - Add pure `@(scenario)` specifications in `tests/spec_tabs.odin` and Layer 2 DSL steps in `tests/dsl_bifrost.odin`.
   - Showcase `ui_tabs` in `examples/widget_gallery/main.odin`.

## Acceptance Criteria
- `ui_tabs` passes `odin run tools/bifrost_gen -- --atdd tests`, unit tests, and `@(scenario)` ATDD tests with zero per-frame heap leaks and full `vt_cells` ANSI diff equivalence.
