# Specification: Track 6 — Hierarchical Focus Scope Tree, `H`/`H*` History & Two-Stage Edit (`focus_scope_tree_and_history_20261104`)

## Overview
Replace Bifrost's flat `scope_id` focus tracking with a true **Hierarchical Focus Scope Tree** (`parent_scope_idx`, `subtree_end_idx`, `text_sink_idx`, `Focus_Flags`) and a persistent zero-allocation **`Scope_Memory_Entry`** table implementing Harel statechart **Shallow History ($H$)** and **Deep History ($H^*$)** across frames, deleted/filtered nodes, nested `z_layer` modals, mouse clicks, two-stage text inputs, and `.Scope_Text_Sink` command-palette views.

## Reference Blueprint & Patches
- **Investigation Report:** [`investigation.md`](./investigation.md)
- **Master Architecture Guide:** [`docs/NAVIGATION_AND_DSL_GUIDE.md`](../../../docs/NAVIGATION_AND_DSL_GUIDE.md)
- [`.tmp/patches/track6_lazygit_context_stack.patch`](../../../.tmp/patches/track6_lazygit_context_stack.patch) (`reference/lazygit` — `ContextMgr` stack, `UpdateSelectionHighlights` active vs. inactive highlights)
- [`.tmp/patches/track6_textual_focus_and_screen.patch`](../../../.tmp/patches/track6_textual_focus_and_screen.patch) (`reference/textual` — `Screen` focus chains, `allow_focus` vs `allow_focus_children`, & focus traps)
- [`.tmp/patches/track6_clay_local_id_hashing.patch`](../../../.tmp/patches/track6_clay_local_id_hashing.patch) (`reference/clay` — `CLAY_ID_LOCAL` / `CLAY_IDI_LOCAL` parent-seeded ID hashing)
- [`.tmp/patches/track7_ftxui_containers_and_stacking.patch`](../../../.tmp/patches/track7_ftxui_containers_and_stacking.patch) (`reference/ftxui` — `EnsureFocusableSelection` disabled-child advancement)

## Functional Requirements

1. **Hierarchical Scope Tree, `Focus_Flags` & Scope-Seeded Local IDs (`bifrost/layout.odin`):**
   - Introduce `Focus_Flag :: enum u8` and `Focus_Flags :: bit_set[Focus_Flag; u16]`:
     - `.Focusable`, `.Focus_Scope`, `.Trap_Focus`, `.Captures_Text`, `.Auto_Edit`, `.Loop_Spatial`, `.Wrap_Spatial`, `.Strict_Spatial`, `.Default_Focus`, `.Scope_Text_Sink`, `.Disabled`.
   - Maintain 100% backwards compatibility with existing `Box_Config` boolean fields (`focusable`, `focus_scope`, `capture_input`, `text_input`) by synthesizing corresponding `Focus_Flags` in `push_node`.
   - Add Clay-inspired zero-allocation scope-seeded ID helpers (`hash_local_id(parent_hash, label)` and `hash_local_idi(parent_hash, label, index)`) so reusable subtrees and multi-column lists avoid `fmt.tprintf` allocations and ID collisions.
   - Extend `Layout_Node` with `parent_scope_idx: i32`, `subtree_end_idx: i32`, `text_sink_idx: i32`, and `focus_flags: Focus_Flags`.
   - Maintain a fixed-capacity `scope_stack: [MAX_SCOPE_DEPTH]i32` on `Layout_Context` (root `0` automatically acts as `.Focus_Scope`), recording exact `subtree_end_idx` on `container`, `ui_modal`, and `ui_virtual_list` exit, and binding `ctx.nodes[parent_scope_idx].text_sink_idx` when `.Scope_Text_Sink` mounts.

2. **Z-Order-Aware `.Trap_Focus` Discovery, Per-Scope History (`H`/`H*`) & Inactive Selection Highlights (`bifrost/input.odin`):**
   - Resolve the active `.Trap_Focus` root using `ctx.z_order` / `effective_z` (never raw `ctx.nodes` declaration index, ensuring modals declared inside earlier sibling containers like `sidebar` at `z_layer = 20` win cleanly over later siblings at `z_layer = 0`).
   - Add fixed-capacity `scope_memory: [MAX_SCOPE_MEMORY]Scope_Memory_Entry` (`scope_hash`, `last_child_hash` for Shallow $H$, `last_leaf_hash` for Deep $H^*$, `last_seen_frame` LRU eviction) and `focus_node_path: [MAX_FOCUS_PATH]i32` (`root .. focused_tip`).
   - Expose Lazygit-style 3-state selection queries (`is_focused` for active tip vs. `is_scope_selected` for remembered `last_leaf_hash` in inactive scopes) and optional dimmed inactive highlight rendering in `apply_input_highlights`.
   - Skip `.Disabled` nodes/subtrees during target resolution so focus never strands on a disabled widget (`FTXUI EnsureFocusableSelection` invariant).
   - Stop recording `scope_memory` upward once crossing a `.Trap_Focus` boundary so modal dialogs never clobber underlying workspace pane focus memory, and support arbitrarily stacked modals (`z=20`, `z=30`, etc.) restoring exact prior leaf focus upon dismissal.
   - Deterministic `resolve_scope_target` fallback chain:
     1. Deep History ($H^*$: `last_leaf_hash` if mounted, `.Focusable`, and allowed inside scope).
     2. Shallow History ($H$: walk down `last_child_hash` child scope to its surviving `.Default_Focus` or first `.Focusable` descendant when the prior leaf was deleted or filtered out).
     3. Fresh Mount (`.Default_Focus` descendant, else first `.Focusable` descendant).
     4. Empty Scope / Zero-Match Fallback (`scope_idx` itself if `.Focusable`, e.g. empty Kanban column, or `scope_node.text_sink_idx`).

3. **Two-Stage vs. `.Auto_Edit` Text Capture, Sticky `Tab` Edit & `.Scope_Text_Sink` (`bifrost/input.odin`, `bifrost/text_input.odin`, `bifrost/command_palette.odin`):**
   - Separate `focused_id` from `editing_id`:
     - `.Auto_Edit` inputs enter `editing_id = focused_id` automatically on focus; single `Escape` passes through to parent scopes/modals.
     - Two-stage inputs (`{.Focusable, .Captures_Text}` without `.Auto_Edit`) navigate spatially via `h/j/k/l`/Arrows until `Enter` (or mouse click!) sets `editing_id = focused_id`; first `Escape` exits edit mode (`editing_id = 0`), second `Escape` bubbles up.
     - Pressing `Tab` / `Shift+Tab` while actively editing sets `carry_edit_mode = true` so adjacent two-stage form inputs stay in edit mode seamlessly.
   - `.Scope_Text_Sink`: When an ancestor scope on `focus_node_path` owns a `text_sink_idx`, automatically bind `editing_id` to the sink so printable runes & horizontal cursor keys edit the search bar while `Up`/`Down`/`Ctrl+N`/`Ctrl+P`/`Enter` navigate and activate list items; mutating text resets sibling selection inside the scope to `.Default_Focus` / row `0`.
   - Mouse integration: Clicking any `.Focusable` node updates `scope_memory` along `parent_scope_idx`, and clicking a `.Captures_Text` node immediately activates `editing_id` and places the UTF-8 cursor.

## Acceptance Criteria
- All existing 40 unit and ATDD tests in `bifrost/` and `tests/` continue passing unchanged.
- New deterministic unit and ATDD specs cover `effective_z` out-of-order `.Trap_Focus` modals, 3-level nested modal restoration, deleted leaf $\to$ shallow child scope fallback, empty focusable scope fallback, mouse-to-history + two-stage click-to-edit, sticky `Tab` edit carry, and `.Scope_Text_Sink` filter-reset behavior with zero leaks under `mem.Tracking_Allocator`.
