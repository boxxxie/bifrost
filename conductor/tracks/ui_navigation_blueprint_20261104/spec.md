# Specification: Layered Focus Trees, 2D Spatial Navigation, Chord DSL & Actor Command Routing (`ui_navigation_blueprint_20261104`)

## Overview
Upgrade **Bifrost** (`package bifrost`) from flat single-level `focus_scope` cycling to a complete **Hierarchical Focus Scope Tree + 2D Spatial Navigation + Bottom-Up Event Bubbling + Declarative Key-Chord/AST DSL + Sleipnir Actor Action Router** architecture.

Rather than forcing application authors to maintain parallel Harel statecharts alongside an immediate-mode UI tree (which creates synchronization drift when layout nodes dynamically mount, filter, or unmount), Bifrost **embeds core statechart invariants directly into the immediate-mode layout/focus hierarchy** while providing lightweight explicit sub-modes (`QHsm`-inspired transient widget modes and multi-key chords) where orthogonal modal state genuinely belongs:

- **OR-States & Hierarchy** $\rightarrow$ Nested `.Focus_Scope` containers (`parent_scope_idx`, `subtree_end_idx`) derived automatically during `begin_layout`..`end_layout`.
- **Shallow ($H$) & Deep ($H^*$) History** $\rightarrow$ Zero-allocation `Scope_Memory_Entry` table keyed by persistent `scope_hash` (`u64`) with deterministic deleted-target fallback and `.Trap_Focus` isolation.
- **Event Bubbling & Guards** $\rightarrow$ Bottom-up walk over `focus_node_path` (`tip -> enclosing scopes -> root`) halted at `effective_z`-ordered `.Trap_Focus` shields.
- **Orthogonal Regions & Transient Sub-Modes** $\rightarrow$ `.Scope_Text_Sink` (simultaneous filter-input capture + list navigation), two-stage vs. `.Auto_Edit` text capture, multi-key chord state (`g g`, `<C-w> l`), and transient widget sub-modes (e.g. splitter `Resize` mode).
- **Zero-Ceremony Odin Ergonomics & Actor Integration** $\rightarrow$ Pure-library Key-Chord + `core:reflect` Struct-Tag Action DSL, optional `core:odin/ast` static codegen (`tools/bifrost_gen`), live contextual focus-breadcrumb/hint bars, and direct UI action $\to$ `sleipnir` `actor.PID` dispatch.

Full reference documentation and self-contained examples are preserved in [`docs/NAVIGATION_AND_DSL_GUIDE.md`](../../../docs/NAVIGATION_AND_DSL_GUIDE.md).

---

## Reference Submodules & Patch Slices
- **Lazygit (`reference/lazygit`):** [`.tmp/patches/track6_lazygit_context_stack.patch`](../../../.tmp/patches/track6_lazygit_context_stack.patch), [`.tmp/patches/track8_lazygit_keybindings_hints.patch`](../../../.tmp/patches/track8_lazygit_keybindings_hints.patch) — `ContextMgr` stack push/pop, per-panel cursor memory, and live footer keybinding hints.
- **Textual (`reference/textual`):** [`.tmp/patches/track6_textual_focus_and_screen.patch`](../../../.tmp/patches/track6_textual_focus_and_screen.patch), [`.tmp/patches/track7_textual_event_bubbling.patch`](../../../.tmp/patches/track7_textual_event_bubbling.patch) — Focus chains, focus traps, DOM-style bubbling, and scoped `BINDINGS` discovery.
- **Dear ImGui (`reference/imgui`):** [`.tmp/patches/track7_imgui_nav_internal.patch`](../../../.tmp/patches/track7_imgui_nav_internal.patch) — Immediate-mode `PushFocusScope`, 2D `NavScoreItem` spatial rect scoring, and `NavId` alive/fallback reconciliation.
- **QP/C (`reference/qpc`):** [`.tmp/patches/track8_qpc_qhsm_lca.patch`](../../../.tmp/patches/track8_qpc_qhsm_lca.patch) — Miro Samek's zero-allocation `QHsm` LCA hierarchical state machine semantics.
- **Sleipnir & xitdb (`deps/sleipnir`, `deps/xitdb`):** [`.tmp/patches/track8_sleipnir_ast_codegen.patch`](../../../.tmp/patches/track8_sleipnir_ast_codegen.patch), [`.tmp/patches/track9_xitdb_marshal_dsl.patch`](../../../.tmp/patches/track9_xitdb_marshal_dsl.patch) — Odin `core:odin/parser` + `core:odin/ast` codegen (`tools/sleipnir_gen`) and zero-alloc runtime micro-DSLs / struct reflection.

---

## Track Decomposition

1. **Track 6 (`focus_scope_tree_and_history_20261104`):** Hierarchical Focus Scope Tree, Z-Ordered `.Trap_Focus`, Shallow/Deep History (`H`/`H*`), Mouse-to-History Sync, Two-Stage vs. `.Auto_Edit` Text Capture, and `.Scope_Text_Sink`.
2. **Track 7 (`spatial_2d_nav_and_bubbling_20261104`):** Lane-Aware 2D Spatial Scorer (`.Wrap_Spatial`, `.Strict_Spatial`), Unified `ui_virtual_list` Row/Page Stepping, Same-Frame `scroll_node_into_view`, Hierarchical `F6` Cycling, and Bottom-Up `Enter`/`Escape` Drill-Down/Up.
3. **Track 8 (`keymap_chord_dsl_and_ast_gen_20261104`):** Key-Chord Micro-DSL (`"<C-p>"`, `"g g"`), Transient Widget Sub-Modes, `core:reflect` Typed Enum/Struct-Tag Action Registration (`Keymap_Table` + `Command_Palette` + Contextual Breadcrumb/Hint Bar), and Optional `tools/bifrost_gen` AST Codegen.
4. **Track 9 (`sleipnir_actor_action_routing_20261104`):** `actor_bridge.odin` Split-Brain Elimination, Frame-0 & Two-Pass Coordinator Focus Reconciliation, Direct UI Action $\to$ `sleipnir` `actor.PID` Routing, and Optional `xitdb` Workspace Layout Persistence.
