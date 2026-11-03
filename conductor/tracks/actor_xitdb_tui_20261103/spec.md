# Specification: Core Actor-Driven Odin TUI Engine (`bifrost`)

## Overview
Build **Bifrost** (`package bifrost`), an immediate-mode, actor-driven Terminal User Interface (TUI) framework in Odin that combines:
- **Sleipnir (`package actor`):** Subsystem-level concurrency where terminal input/resize/timer producers and background workers communicate via lock-free mailboxes with a single-writer UI coordinator actor.
- **xitdb (`package xitdb`):** Zero-GC immutable persistence where worker actors commit transactions and pass $O(1)$ moment indices (`i64`) to the UI actor, which slices virtualized viewports (`Linked_Array_List`, `Sorted_Map`, `Array_List`) directly on `context.temp_allocator`.
- **Best-of-Breed Immediate-Mode TUI Architecture:**
  - **Clay (C):** Two-pass topological `Fit` / `Grow` / `Fixed` layout solver over a flat `[dynamic]Layout_Node` slice on `context.temp_allocator`.
  - **Notcurses (C):** Out-of-flow `z_layer` elevation and in-place 50% RGB bit-shift backdrop dimming (`Dim_Screen`, `Dim_Rect`).
  - **Lip Gloss & Bubble Tea (Go):** Unified box-model config structs and Elm-style actor message/command loops.
  - **Ratatui (Rust) & libvaxis (Zig):** Double-buffered `[]Cell` diffing wrapped in DEC Mode 2026 synchronized output (`\x1b[?2026h ... \x1b[?2026l`).
  - **FTXUI (C++) & Zest (Zig):** Scoped focus navigation (`focus_scope`), modal input capture (`capture_input`), focus history restoration, and reverse `z_order` mouse hit-testing.

Full architectural reference and verified prototype modules are documented in [`building_an_actor_driven_odin_tui.md`](./building_an_actor_driven_odin_tui.md).

---

## Core Modules & Requirements

1. **Two-Pass Topological Layout Engine (`bifrost/layout.odin`):**
   - `Direction` (`.Row`, `.Column`), `Alignment` (`.Start`, `.Center`, `.End`), `Border_Kind` (`.None`, `.Plain`, `.Rounded`, `.Double`), `Anchor_Mode` (`.Screen`, `.Parent`).
   - `Axis_Size` union (`Fit{min, max}`, `Grow{weight, min, max}`, `Fixed(i32)`).
   - Scoped `container` (`@(deferred_in = defer_end_container)`) and `leaf` builders.
   - `end_layout`:
     - **Pass 0:** Propagate `effective_z`, `out_of_flow`, and `scope_id`.
     - **Pass 1 (Reverse Topological Order):** Bottom-up intrinsic and `Fit` sizing (skipping `out_of_flow` children).
     - **Pass 2 (Forward Topological Order):** Out-of-flow `.Screen`/`.Parent` anchoring, constrained `Grow` freeze loop with exact integer remainder distribution, `content_span` recording, non-virtual scroll offset shifting, and hierarchical `node_clip` / `inner_clip` intersection.
     - **Pass 3:** Stable insertion sort of node indices into `ctx.z_order` by `effective_z` ascending.

2. **Z-Sorted Rasterizer & Minimal ANSI Diff Renderer (`bifrost/renderer.odin`):**
   - `Color` (`.Default`, `.ANSI_16`, `.ANSI_256`, `.RGB`), `Style_Flags` (`bit_set[Style_Flag; u8]`), `Cell`, `Paint_Spec`, `Backdrop_Mode` (`.None`, `.Dim_Screen`, `.Dim_Rect`).
   - Persistent double-buffered `Screen` (`screen_init`, `screen_destroy`, `screen_resize`, `begin_frame`).
   - Scoped `ui_modal` (`@(deferred_in = defer_end_modal)`) with automatic `z_layer = 20`, `.Dim_Screen`, `focus_scope = true`, and `capture_input = true`.
   - `render_layout`: Iterates `ctx.z_order`, applies 50% RGB bit-shift dimming (`dim_rect_backdrop`), fills backgrounds (`fill_char`), draws borders/titles, vertical scrollbars, clipped text, and inverted block cursors.
   - `screen_diff_ansi`: Emits minimal 1-based cursor jumps, incremental SGR transitions (`emit_sgr_transition`), and DEC Mode 2026 synchronized update framing (`0` bytes emitted on clean frames).

3. **Z-Aware Input, Focus & Hit-Testing Engine (`bifrost/input.odin`):**
   - Zero-allocation `Input_State` owned by the UI actor.
   - `resolve_input`: Identifies topmost `capture_input` modal, reconciles focus with an 8-entry `focus_history` stack, dispatches global/scoped keybindings, routes keys/clicks to text inputs, splitters, scrollable containers, and focusable widgets, and refreshes `hovered_id`.
   - `hit_test_point`: Walks `ctx.z_order` in reverse (front-to-back), respecting modal capture boundaries and solid floating occlusion, and reports `backdrop_clicked_id` for click-outside modal dismissal.

4. **Virtualized `xitdb` Lists & Scrollbar Module (`bifrost/scroll.odin`):**
   - Fixed 32-entry `Scroll_Slot` table inside `Input_State`.
   - Scoped `ui_virtual_list` (`@(deferred_in = defer_end_virtual_list)`) computing visible `Virtual_Slice{start_row, end_row, selected_row, total_rows}` so 100,000-row `xitdb` collections only instantiate layout nodes for the visible viewport rows.
   - `hit_test_scrollable` mouse-wheel bubbling and keyboard `Up`/`Down`/`Page_Up`/`Page_Down`/`Home`/`End` navigation.

5. **Interactive UTF-8 Text Input & Real-Time `xitdb` Filter (`bifrost/text_input.odin`):**
   - Fixed 16-entry `Text_Input_Slot` (`[256]byte` each) with UTF-8 codepoint-aligned cursor movement, word-jumping (`Ctrl+Left/Right`, `Ctrl+W/U/K`), click-to-place, and horizontal rune scrolling (`slice_utf8_by_runes`).
   - Telescope-style `linked_list_id` forwarding so arrow keys navigate the linked `ui_virtual_list` while typing in the search box.
   - `Xitdb_Filter` caching matching record indices per `(moment_slot, query_hash, total_db_rows)`.

6. **Interactive Split-Pane Dividers, Keybinding Router & Command Palette (`bifrost/splitter_keymap.odin`, `bifrost/command_palette.odin`):**
   - `ui_splitter` 1-cell divider bar with mouse drag and keyboard resize (`apply_splitter_size_immediate` shifting sibling rects and clips on the same frame) and visual upgrade (`│` $\to$ `┃`, `─` $\to$ `━`).
   - Three-tier keybinding router (`.Scope_Only`, `.Root_And_Scopes`, `.Global_Always`) with text-input shielding and `.Allow_In_Text_Input`.
   - `Command_Palette` (`ui_command_palette`, `update_command_palette`) with multi-token fuzzy scoring (`fuzzy_score`) and live shortcut badge discovery (`lookup_action_shortcut`).

7. **Sleipnir + xitdb Actor Integration & Terminal Backend (`bifrost/actor_bridge.odin`, `bifrost/terminal.odin`, `examples/`):**
   - Integration with `sleipnir` (`package actor`) and `xitdb` (`package xitdb`) demonstrating worker actors committing `xitdb` moments and messaging `State_Committed{moment_idx}` to the Bifrost UI actor.
   - Interactive `xitdb` Inspector TUI demo (`examples/xitdb_inspector/`).
