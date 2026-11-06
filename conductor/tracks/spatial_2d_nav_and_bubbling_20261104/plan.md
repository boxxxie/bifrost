# Implementation Plan: `spatial_2d_nav_and_bubbling_20261104`

## Phase 1: Red-First 2D Spatial, Paging & Bottom-Up Bubbling Specifications
- [x] Task: Add deterministic unit and ATDD tests for 2D spatial navigation, paging, virtual-list stepping, and `Enter`/`Escape` drill-down/up
    - [x] Add `test_spatial_2d_wrapping_and_bubbling`, `test_scroll_into_view_and_paging`, and virtualized `ui_virtual_list` directional/page stepping tests in `bifrost/focus_nav_test.odin`.
    - [x] Add multi-column Kanban drill-down/drill-up + cross-column $H^*$ restoration ATDD specs in `tests/spec_focus_and_input.odin`.

## Phase 2: 2D Spatial Scorer, Same-Frame `scroll_node_into_view` & Virtual-List Paging (`bifrost/input.odin`, `bifrost/scroll.odin`)
- [x] Task: Implement `score_spatial_candidate`, `.Wrap_Spatial`, `.Strict_Spatial`, `scroll_node_into_view`, and paging resolvers
    - [x] Implement `Nav_Dir`, `interval_metrics`, `score_spatial_candidate`, `find_spatial_neighbor`, and `find_wrapped_neighbor` over unclipped `node.rect` coordinates.
    - [x] Implement `compute_axis_scroll_delta`, `shift_descendants_y`, and same-frame `scroll_node_into_view` in `reconcile_focus`, plus unified materialized and `ui_virtual_list` (`virtual_total_rows > 0`) row/page stepping (`Page_Up`, `Page_Down`, `Home`, `End`, `j/k`, Arrows).

## Phase 3: Bottom-Up `focus_node_path` Dispatch & Example Upgrades (`bifrost/input.odin`, `examples/`)
- [x] Task: Upgrade `handle_key_event` and `cycle_focus_scope` to full bottom-up bubbling and refactor `kanban_board` + `widget_gallery`
    - [x] Implement hierarchical `cycle_focus_scope` (`F6` / `Shift+F6` / `Ctrl+Tab`) and the 7-step bottom-up `focus_node_path` walk (`Enter` drill-down, scoped keymaps, `Tab` ring, 2D spatial nav, paging, `Escape` drill-up, `.Trap_Focus` boundary).
    - [x] Upgrade `examples/kanban_board/main.odin` and `examples/widget_gallery/main.odin` to showcase `{.Focus_Scope, .Focusable, .Wrap_Spatial}`, empty-column focus, `Enter`/`Escape` layering, and $H^*$ card history.
    - [x] Run `odin test bifrost -vet -vet-packages:bifrost -strict-style`, `odin test tests -vet -vet-packages:bifrost_tests,bifrost -strict-style`, and compile check both examples with zero memory leaks.
