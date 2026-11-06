# Implementation Plan: `focus_scope_tree_and_history_20261104`

## Phase 1: Red-First Scope Tree, `H`/`H*` History & Text-Sink Specifications
- [x] Task: Write deterministic unit and ATDD tests for hierarchical scope trees, `H`/`H*` memory, and edit modes
    - [x] Add unit tests in `bifrost/focus_nav_test.odin` covering `parent_scope_idx` / `subtree_end_idx` construction, `z_order` out-of-tree-order `.Trap_Focus` precedence, stacked modals (`modal_1` + `modal_2`), deleted-leaf shallow history ($H$) fallback, empty `.Focusable` scope fallback, two-stage edit + sticky `Tab` carry, mouse click-to-edit + history recording, and `.Scope_Text_Sink` filter reset.
    - [x] Add ATDD specs in `tests/spec_focus_and_input.odin` (and helpers in `tests/dsl_bifrost.odin`) exercising user-level two-stage editing and command-palette `.Scope_Text_Sink` typing + navigation.

## Phase 2: Hierarchical Scope Stack & `Focus_Flags` in `bifrost/layout.odin`
- [x] Task: Extend `Box_Config`, `Layout_Node`, and `Layout_Context` with `Focus_Flags` and scope-tree bounds
    - [x] Define `Focus_Flag` and `Focus_Flags`, mapping legacy booleans (`focusable`, `focus_scope`, `capture_input`, `text_input`) onto `Focus_Flags` for full backwards compatibility.
    - [x] Track `scope_stack: [MAX_SCOPE_DEPTH]i32`, `parent_scope_idx`, `subtree_end_idx`, and `text_sink_idx` across `begin_layout`, `push_node`, `container`, `ui_modal`, and `ui_virtual_list`.

## Phase 3: `Scope_Memory_Entry` (`H`/`H*`), Two-Stage Edit & `.Scope_Text_Sink` in `bifrost/input.odin`
- [x] Task: Implement `Scope_Memory_Entry`, `z_order`-aware `reconcile_focus`, two-stage `editing_id`, and `.Scope_Text_Sink`
    - [x] Add `Scope_Memory_Entry`, `focus_node_path`, `editing_id`, `carry_edit_mode`, and LRU `scope_memory` helpers on `Input_State`.
    - [x] Upgrade `reconcile_focus` to locate topmost `.Trap_Focus` via `ctx.z_order` (`effective_z`), resolve targets via Deep $H^*$ $\to$ Shallow $H$ $\to$ `.Default_Focus` $\to$ Empty-Scope/Sink fallback, halt `scope_memory` writes across `.Trap_Focus` boundaries, and bind ancestor `.Scope_Text_Sink` to `editing_id`.
    - [x] Update `ui_text_input`, `ui_modal`, `ui_command_palette`, and `handle_mouse_event` to honor `.Auto_Edit`, two-stage edit (`Enter`/click to edit, `Escape` to exit), sticky `Tab` edit carry, and `.Scope_Text_Sink` sibling-selection reset on text mutation.
    - [x] Run `odin test bifrost -vet -vet-packages:bifrost -strict-style` and `odin test tests -vet -vet-packages:bifrost_tests,bifrost -strict-style` with zero memory leaks.
