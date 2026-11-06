# Implementation Plan: `ui_navigation_blueprint_20261104`

## Phase 1: Track 6 — Hierarchical Focus Scope Tree, `H`/`H*` History & Two-Stage Edit
- [x] Task: Complete Track 6 (`conductor/tracks/focus_scope_tree_and_history_20261104/plan.md`)
    - [x] Extend `Layout_Node` / `Layout_Context` with `Focus_Flags`, `parent_scope_idx`, `subtree_end_idx`, and `text_sink_idx`.
    - [x] Implement `effective_z`-aware `.Trap_Focus` discovery, `Scope_Memory_Entry` (`H` & `H*`) with deleted-node fallback, mouse-to-history sync, two-stage vs. `.Auto_Edit` text capture, sticky `Tab` edit carry, and `.Scope_Text_Sink`.
    - [x] Verify unit and ATDD specs pass with zero memory leaks.

## Phase 2: Track 7 — 2D Spatial Navigation, Virtualized List Paging & Bottom-Up Bubbling
- [x] Task: Complete Track 7 (`conductor/tracks/spatial_2d_nav_and_bubbling_20261104/plan.md`)
    - [x] Implement integer-only lane-aware 2D spatial scoring (`.Wrap_Spatial`, `.Strict_Spatial`), hierarchical `F6`/`Shift+F6` scope cycling, same-frame `scroll_node_into_view`, and unified `ui_virtual_list` row/page stepping.
    - [x] Implement bottom-up `focus_node_path` key bubbling (`Enter` drill-down, scoped keymaps, `Tab`, spatial, paging, `Escape` drill-up, `.Trap_Focus` shield) and upgrade `kanban_board` & `widget_gallery`.
    - [x] Verify all spatial, scrolling, and bubbling specs pass with zero memory leaks.

## Phase 3: Track 8 — Declarative Key-Chord DSL, Transient Sub-Modes, Hints & AST Codegen
- [x] Task: Complete Track 8 (`conductor/tracks/keymap_chord_dsl_and_ast_gen_20261104/plan.md`)
    - [x] Implement Tier 1 Key-Chord parser (`"<C-p>"`, `"g g"`, `"<C-w> l"`), multi-key `pending_chord` state, transient widget sub-modes (e.g. splitter `Resize` mode), `core:reflect` typed action/struct-tag registration, and `ui_focus_breadcrumb_bar` / `ui_key_hint_bar`.
    - [x] Implement Tier 2 `tools/bifrost_gen` (`core:odin/parser` + `core:odin/ast`) static `@(ui_scope)` / `@(ui_action)` binding generator and test suite.
    - [x] Verify zero-leak tests across `bifrost`, `tests`, and `tools/bifrost_gen`.

## Phase 4: Track 9 — Sleipnir Actor Command Routing & `actor_bridge.odin` Unification
- [x] Task: Complete Track 9 (`conductor/tracks/sleipnir_actor_action_routing_20261104/plan.md`)
    - [x] Remove hardcoded key-handling split-brain from `ui_reduce_single_msg` and enforce Frame-0 + two-pass `resolve_input` reconciliation in `ui_coordinator_flush_frame`.
    - [x] Add typed UI Action $\to$ `sleipnir` `actor.PID` / `UI_Msg` dispatch, optional `xitdb` workspace layout/focus persistence, and upgrade `log_monitor` + `xitdb_inspector`.
    - [x] Verify full `bifrost` + `tests` suites and headless/example smoke checks pass with zero leaks.
