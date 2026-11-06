# Reference Investigation: Track 6 (`focus_scope_tree_and_history_20261104`)

## Patches Inspected
- [`.tmp/patches/track6_lazygit_context_stack.patch`](../../../.tmp/patches/track6_lazygit_context_stack.patch) (`reference/lazygit` — `ContextMgr`, `UpdateSelectionHighlights`, `search_trait.go`)
- [`.tmp/patches/track6_textual_focus_and_screen.patch`](../../../.tmp/patches/track6_textual_focus_and_screen.patch) (`reference/textual` — `Screen.focus_chain`, `_trap_focus`, `allow_focus` vs `allow_focus_children`)
- [`.tmp/patches/track6_clay_local_id_hashing.patch`](../../../.tmp/patches/track6_clay_local_id_hashing.patch) (`reference/clay` — `CLAY_ID_LOCAL` / `CLAY_IDI_LOCAL` parent-seeded ID hashing)
- [`.tmp/patches/track7_ftxui_containers_and_stacking.patch`](../../../.tmp/patches/track7_ftxui_containers_and_stacking.patch) (`reference/ftxui` — `EnsureFocusableSelection` & `StackedContainer::SetActiveChild`)

---

## Key Architectural Findings & Design Verdicts for `bifrost`

### 1. 3-State Active vs. Inactive History Selection Highlights (`lazygit/pkg/gui/context.go`)
- **Finding:** In `ContextMgr.UpdateSelectionHighlights` (`context.go:210-234`), Lazygit distinguishes **three** selection states across panels rather than binary focused/unfocused:
  1. **Active leaf focus** (`Highlight = true, HighlightInactive = false`): the currently focused pane/item.
  2. **Inactive history selection** (`Highlight = true, HighlightInactive = true`): background panes/columns whose `last_leaf_hash` is remembered in `Scope_Memory_Entry` while active focus is in another pane or a modal overlay.
  3. **Unselected** (`Highlight = false`).
- **Verdict for `bifrost/input.odin`:** Expose `is_scope_selected(inp, id)` (true when `id` is the remembered `last_leaf_hash` of its enclosing `.Focus_Scope`) and render a subtle dimmed highlight in `apply_input_highlights` when `!is_focused` so inactive Kanban columns and split-pane sidebars visibly retain their selected item.

### 2. Scope-Seeded Local IDs Without String Formatting (`clay/clay.h`)
- **Finding:** `CLAY_ID_LOCAL(label)` and `CLAY_IDI_LOCAL(label, index)` (`clay.h:88-97`) hash `(label, index)` seeded by the currently open parent element's ID (`Clay_GetOpenElementId()`). Without parent-seeded hashing, reusable components or multi-column lists must allocate `fmt.tprintf("col_%d_card_%d", c, i)` strings every frame to avoid `id_hash` collisions.
- **Verdict for `bifrost/layout.odin`:** Add zero-allocation `hash_local_id(parent_hash, label)` and `hash_local_idi(parent_hash, label, index)` helpers (plus optional `.Local_ID` scoping) seeded by `ctx.nodes[parent_scope_idx].id_hash`.

### 3. Container Self-Focus vs. Child-Focus & Disabled Subtree Pruning (`textual/screen.py` & `ftxui/container.cpp`)
- **Finding:** Textual's `Screen.focus_chain` (`screen.py:808-825`) separates `allow_focus()` (can the container node itself hold focus?) from `allow_focus_children()` (can traversal descend into children?) while inheriting `disabled`/`hidden` down the traversal stack in one pass. FTXUI's `EnsureFocusableSelection` (`container.cpp:72-76`) immediately advances selection if the remembered child becomes disabled on a subsequent frame.
- **Verdict for `bifrost`:** `Focus_Flags` cleanly models this via orthogonal `.Focusable` (container can hold focus itself, e.g. for `Enter` drill-down or empty Kanban column fallback) and `.Focus_Scope` (defines a scope region), plus `.Disabled` subtree skipping during `resolve_scope_target` so focus never strands on a disabled widget.

### 4. Dynamic Floating Window Bring-to-Front (`ftxui/container.cpp`)
- **Finding:** `StackedContainer::SetActiveChild` (`container.cpp:287-301`) rotates a clicked/focused non-modal floating window to the front while preserving the relative z-order of all other floating windows.
- **Verdict for `bifrost`:** Support optional dynamic z-promotion for non-modal floating scopes while keeping `.Trap_Focus` discovery strictly anchored to `ctx.z_order` (`effective_z`).
