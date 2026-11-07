# Initial Concept

An immediate-mode, actor-driven Terminal User Interface (TUI) engine for Odin that bridges **Sleipnir** (`package actor`) and **xitdb** (`package xitdb`) with a Clay-style two-pass layout solver, Notcurses-inspired z-layer compositing and RGB backdrop dimming, and Ratatui/libvaxis-inspired double-buffered ANSI diff rendering.

# Product Guide

## Vision

**Bifrost** (`package bifrost`) is the bridge between lock-free background actor state (Sleipnir + xitdb) and a tear-free, microsecond-scale terminal UI in Odin. Instead of retained-mode widget trees or mutex-guarded shared state, worker actors commit immutable snapshots to `xitdb` and send lightweight moment indices (`i64`) over `sleipnir` mailboxes to a single-writer UI coordinator actor. The UI actor resolves layout, input, focus, and cell diffing on `context.temp_allocator` with zero per-frame heap allocations.

## Core Capabilities (v0.2.0)

1. **Two-Pass Topological Layout Engine (`layout.odin`):**
   - Clay-inspired `Fit` (shrink-wrap with `min`/`max`), `Grow` (weighted flex with `min`/`max` freeze clamping and exact integer remainder distribution), and `Fixed` sizing.
   - Declarative scoped containers via `@(deferred_in = defer_end_container)` (`if container(&ctx, "id", {...}) { ... }`).
   - Out-of-flow overlay promotion (`z_layer`, `floating`, `.Screen` and `.Parent` anchoring) so modals and dropdowns can be declared inline anywhere in the component tree without disturbing parent layout geometry.

2. **Z-Sorted Rasterizer & Tear-Free ANSI Diff Renderer (`renderer.odin`):**
   - Double-buffered `front` and `back` `[]Cell` grids with hierarchical parent-to-child clip rectangle intersection (`node_clip`, `inner_clip`).
   - Stable `effective_z` layer sorting and in-place 50% RGB bit-shift backdrop dimming (`.Dim_Screen`, `.Dim_Rect`) for stacked modals and HUD overlays.
   - Zero-allocation hot-loop ANSI diff emitter (`screen_diff_ansi`) with incremental SGR transitions, contiguous cursor-jump elimination, and DEC Mode 2026 synchronized output (`\x1b[?2026h ... \x1b[?2026l`).

3. **Hierarchical Focus Scopes, 2D Spatial Navigation & Hit-Testing (`focus_scope.odin`, `spatial_nav.odin`, `input.odin`):**
   - Reverse `z_order` mouse hit-testing with floating/modal occlusion and backdrop click detection (`was_modal_dismissed`).
   - Hierarchical focus scope tree (`Focus_Scope_Node`) with Harel statechart shallow/deep history (`H` / `H*`), modal history stack (`focus_history`), and two-stage `.Navigation` vs. `.Editing` sub-modes (`Enter`/`i` to edit, `Esc` to exit to scope navigation).
   - 2D directional navigation (`Left`/`Right`/`Up`/`Down`) with orthogonal projection-overlap cone scoring, bottom-up scope boundary bubbling, and explicit `nav_overrides` (`Node_Nav_Override`).

4. **Virtualized 2D `xitdb` Viewports & Smooth Scrolling (`scroll.odin`, `xitdb_bridge.odin`):**
   - Zero-allocation persistent `Scroll_Slot` table and `ui_virtual_list` / `ui_virtual_table` scoped containers that materialize only the visible `[start_row ..< end_row]` slice from 100,000+ row `xitdb` collections (`Linked_Array_List`, `Sorted_Map`, `Array_List`).
   - Vertical (`offset`) and horizontal (`offset_x`) viewport scrolling, mouse click column selection (`select_virtual_col_at_x`), z-ordered mouse-wheel target bubbling (`hit_test_scrollable`), and proportional border scrollbars (`┃` / `│`).

5. **Interactive UTF-8 Text Input, Selection, OSC 52 Clipboard & Real-Time `xitdb` Filtering (`text_input.odin`):**
   - Codepoint-exact UTF-8 cursor editing (`Left`, `Right`, `Ctrl+Left/Right`, `Home`, `End`, `Backspace`, `Delete`, `Ctrl+W/U/K`, click-to-place) with horizontal rune scrolling.
   - Visual selection (`Shift+Left/Right/Home/End`) and zero-CGO OSC 52 terminal clipboard copy/cut (`Ctrl+C`/`Ctrl+X`).
   - Telescope-style `linked_list_id` arrow-key forwarding and moment/query-cached `Xitdb_Filter`.

6. **Declarative Key-Chord Engine, Multi-Style Modal Editing (`Vim`/`Helix`/`Emacs`), AST Codegen & Command Palette (`keymap.odin`, `status_bars.odin`, `splitter.odin`, `command_palette.odin`, `bifrost/codegen`):**
   - Mouse-dragged and keyboard-driven 1-cell splitters (`ui_splitter`) with same-frame sibling geometry and clip adjustment.
   - Three-tier keybinding router (`.Scope_Only`, `.Root_And_Scopes`, `.Global_Always`) supporting 1- and 2-step chords (`g g`, `C-x C-f`, `<leader> f`), transient sub-modes (`.Resize`), compile-time + runtime conflict detection, and AST code generation (`tools/bifrost_gen`).
   - Live runtime keymap style switching (`set_keymap_style`, `<F2>` cycle or `<F3>`–`<F5>`) across **Vim** (`5j` prefix counts, `gg`/`G`), **Helix** (`j5` post-fix counts, `gg`/`ge`), and **Emacs** (`C-n`/`C-p`/`C-f`/`C-b`, `M-<`/`M->`, `C-v`/`M-v`, `C-u` universal argument, `M-x` palette).
   - Auto-populating Which-Key popup (`ui_which_key_overlay`), focus breadcrumb bar (`ui_focus_breadcrumb_bar`), contextual key hint bar (`ui_key_hint_bar`), and reusable `Ctrl+P`/`M-x` fuzzy command palette (`ui_command_palette`).

7. **Sleipnir Actor Runtime, Action Sinks & `xitdb` Workspace Persistence (`ui_coordinator.odin`, `ui_actions_effects.odin`, `workspace_persistence.odin`, `terminal.odin`, `ansi_parser.odin`):**
   - Single-writer UI coordinator actor integrated with `sleipnir` (`package actor`) and `xitdb` (`package xitdb`), typed actor command routing (`bind_action_actor_sink`), declarative `UI_Effect` side effects, and persistent workspace layout/split/focus/keymap serialization (`save_workspace_state` / `load_workspace_state`).

8. **Core Widget Suite — Tracks 11–14 (`text_area.odin`, `tree.odin`, `tabs.odin`, `canvas.odin`):**
   - **Multi-Line UTF-8 Text Editor (`ui_text_area`):** 2D caret navigation with sticky `preferred_col`, optional dynamic line-number gutter, `Shift+Arrow`/`Ctrl+A` multi-line selection, `Ctrl+C`/`Ctrl+X`/`Ctrl+V` + bracketed paste + OSC 52 clipboard (`flush_osc52_clipboard`), and two-stage `.Navigation`/`.Editing` sub-modes.
   - **Virtualized Collapsible Tree (`ui_tree`):** O(visible_rows) layout node materialization over 10,000+ hierarchical nodes with box-drawing guides (`├─ `, `╰─ `, `│  `, `▾ `, `▸ `), `h`/`l` expand/collapse and parent-node jump, and `id_hash`-persistent branch state.
   - **Focus-Scope-Integrated Tab Bar (`ui_tabs` / `ui_tab_bar`):** Per-tab `Focus_Scope` isolation (`<id>_body_<i>`) with automatic Deep History ($H^*$) restoration across `[` / `]`, `Alt+1..9`, header `h`/`l`, and mouse clicks.
   - **Unicode Braille Canvas & Sparklines (`ui_canvas` / `ui_sparkline`):** ISO/TR 11548-1 $2 \times 4$ sub-cell Braille dot-matrix canvas (`U+2800..U+28FF`) with integer Bresenham lines, rects, and auto-scaled time-series polylines, plus 8-level vertical block sparklines (`▁▂▃▄▅▆▇█`).
