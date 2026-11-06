# Specification: Track 7 — 2D Spatial Navigation, Virtualized List Paging & Bottom-Up Bubbling (`spatial_2d_nav_and_bubbling_20261104`)

## Overview
Build Bifrost's directional and layered keyboard navigation engine: integer-only lane-aware **2D Spatial Rect Scoring** (`h/j/k/l`, Arrow keys, `Ctrl+N/P`), `.Wrap_Spatial` & `.Strict_Spatial` scope modifiers, same-frame **`scroll_node_into_view`**, unified $O(1)$ **`ui_virtual_list`** cursor/page stepping, hierarchical **`F6` / `Shift+F6`** scope cycling, and **Bottom-Up Focus Path Bubbling** (`Enter` drill-down, `Escape` drill-up, scoped keymaps, and `.Trap_Focus` shields)—showcased in upgraded `kanban_board` and `widget_gallery` examples.

## Reference Blueprint & Patches
- **Investigation Report:** [`investigation.md`](./investigation.md)
- **Master Architecture Guide:** [`docs/NAVIGATION_AND_DSL_GUIDE.md`](../../../docs/NAVIGATION_AND_DSL_GUIDE.md)
- [`.tmp/patches/track7_imgui_nav_internal.patch`](../../../.tmp/patches/track7_imgui_nav_internal.patch) (`reference/imgui` — 2D `NavScoreItem`, `NavBiasScoringRect` sticky axis memory, `Loop` vs `Wrap`)
- [`.tmp/patches/track7_ratatui_table_list_state.patch`](../../../.tmp/patches/track7_ratatui_table_list_state.patch) (`reference/ratatui` — 2D `(selected_row, selected_column)` `TableState`)
- [`.tmp/patches/track7_textual_event_bubbling.patch`](../../../.tmp/patches/track7_textual_event_bubbling.patch) (`reference/textual` — DOM-style bottom-up key bubbling & scoped bindings)
- [`.tmp/patches/track7_ftxui_containers_and_stacking.patch`](../../../.tmp/patches/track7_ftxui_containers_and_stacking.patch) (`reference/ftxui` — Nested `Vertical` / `Horizontal` container bubbling)

## Functional Requirements

1. **Integer-Only Lane-Aware 2D Spatial Navigation & Sticky Axis Memory (`bifrost/input.odin`):**
   - Implement `Nav_Dir :: enum u8 { Left, Right, Up, Down }` and `score_spatial_candidate(origin, cand: Rect, dir: Nav_Dir)` using integer-only orthogonal overlap metrics (`interval_metrics`, `OUT_OF_LANE_PENALTY :: 1_000_000`) over unclipped layout `rect` coordinates so scrolled-offscreen siblings remain reachable.
   - **Sticky Orthogonal Axis Bias (`preferred_nav_pos: [2]i32`):** Preserve preferred `x` across vertical moves over wide/ragged spans and preferred `y` across horizontal moves (`ImGui NavBiasScoringRect`), resetting on mouse click or explicit scope jump.
   - `find_spatial_neighbor`: Evaluates `.Focusable` (and non-`.Disabled`) sibling nodes sharing `cand.parent_scope_idx == origin.parent_scope_idx`.
   - **`.Loop_Spatial` vs. `.Wrap_Spatial`:**
     - `.Loop_Spatial`: Same-lane ring wrap (end of row/column wraps to opposite edge of the **same** row/column—ideal for Kanban lists and toolbars).
     - `.Wrap_Spatial`: Reading-order 2D grid wrap (end of Row 1 wraps to first item of Row 2; start of Row 2 wraps back to end of Row 1—ideal for 2D galleries and grids).
   - `.Strict_Spatial`: Consumes missed directional moves at the scope boundary so they do not bubble out to parent containers.
   - Cross-column / cross-scope spatial transition: When a directional move bubbles up to an ancestor scope (e.g. pressing `l` inside `col_todo` where cards are stacked vertically, bubbling up to `board` and hitting sibling scope `col_doing`), resolve into `col_doing` via `resolve_scope_target(..., use_history = true)` so each column remembers its last focused card ($H^*$).

2. **Same-Frame `scroll_node_into_view` & 2D `(row, col)` `ui_virtual_list` Paging (`bifrost/input.odin`, `bifrost/scroll.odin`):**
   - Materialized scroll containers (`scrollable && virtual_total_rows == 0`): Whenever `focused_id` changes (or `ensure_visible` is set), walk enclosing scrollable containers, compute scroll delta (`scroll_padding`), clamp to `max_offset`, and shift descendant `rect` and `node_clip`/`inner_clip` on the **exact same frame** (`0` frame lag).
   - `Page_Up` / `Page_Down` / `Home` / `End`: Step one viewport span in-lane across materialized sibling nodes, or step `Scroll_Slot` / `Virtual_List_State.selected_row` directly when inside an $O(1)$ virtualized `ui_virtual_list` (`virtual_total_rows > 0` for 100k+ `xitdb` rows).
   - **Optional 2D Virtual Table Column Selection (`Ratatui TableState`):** Support `selected_col` / `total_cols` on `Virtual_List_State` so `h`/`l` steps across columns when `total_cols > 1` and bubbles out to sibling panes (e.g. `sidebar_pane`) when pressing `h` at column `0`.

3. **Hierarchical `F6` Cycling & Bottom-Up `focus_node_path` Bubbling (`bifrost/input.odin`, `bifrost/splitter_keymap.odin`):**
   - `cycle_focus_scope` (`F6` / `Shift+F6` / `Ctrl+Tab`): Walk up `focus_node_path` (halting at `.Trap_Focus`) to locate the nearest `.Focus_Scope` with sibling scopes and transition with `use_history = true`.
   - Bottom-up walk (`i := focus_node_path_len - 1; i >= 0; i -= 1`):
     1. **Tip `Enter` / `Space`:** Two-stage edit entry on `.Captures_Text`, drill-down into child target on `.Focus_Scope` (`resolve_scope_child_target`), or leaf activation (`activated_id`).
     2. **Scoped Keybindings:** Match bindings whose `scope_id == node.id_hash` (inner scopes shadow outer scopes).
     3. **Scope-Local `Tab` / `Shift+Tab`:** Topological sibling ring within `node.parent_scope_idx`.
     4. **2D Spatial Navigation:** `h/j/k/l`, Arrow keys, and `Ctrl+N/P` (mapped when not captured by text editing).
     5. **Paging:** `Page_Up`, `Page_Down`, `Home`, `End`.
     6. **Ancestor `Escape` Drill-Up:** When `!is_tip && ev.code == .Escape` and ancestor has `{.Focus_Scope, .Focusable}`, pop focus up to the container node itself (e.g. card $\to$ Kanban column).
     7. **`.Trap_Focus` Boundary Shield:** Halt all bubbling at `.Trap_Focus` (setting `escape_modal_id` on unhandled `Escape`).

4. **Example Upgrades (`examples/kanban_board/main.odin`, `examples/widget_gallery/main.odin`):**
   - Upgrade Kanban columns to `{.Focus_Scope, .Focusable, .Wrap_Spatial}` so empty columns are focusable, `Enter`/`Escape` drills into/out of columns, `j/k` wraps cards vertically, `h/l` & `F6` switch columns with $H^*$ card memory, and `H`/`L` (`Shift+H`/`Shift+L`) moves cards across stages.
   - Upgrade Widget Gallery to demonstrate 2D grid navigation, two-stage vs. `.Auto_Edit` inputs, and same-frame scroll-into-view.

## Acceptance Criteria
- Deterministic unit tests (`bifrost/focus_nav_test.odin`) and ATDD specs (`tests/spec_focus_and_input.odin`) verify 2D lane scoring, `.Wrap_Spatial`, `.Strict_Spatial`, cross-column $H^*$ bubbling, same-frame `scroll_node_into_view`, `Page_Up`/`Page_Down`/`Home`/`End` on both materialized and virtualized `xitdb` lists, and `Enter`/`Escape` drill-down/drill-up with zero memory leaks.
