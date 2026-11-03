# Initial Concept

An immediate-mode, actor-driven Terminal User Interface (TUI) engine for Odin that bridges **Sleipnir** (`package actor`) and **xitdb** (`package xitdb`) with a Clay-style two-pass layout solver, Notcurses-inspired z-layer compositing and RGB backdrop dimming, and Ratatui/libvaxis-inspired double-buffered ANSI diff rendering.

# Product Guide

## Vision

**Bifrost** (`package bifrost`) is the bridge between lock-free background actor state (Sleipnir + xitdb) and a tear-free, microsecond-scale terminal UI in Odin. Instead of retained-mode widget trees or mutex-guarded shared state, worker actors commit immutable snapshots to `xitdb` and send lightweight moment indices (`i64`) over `sleipnir` mailboxes to a single-writer UI coordinator actor. The UI actor resolves layout, input, focus, and cell diffing on `context.temp_allocator` with zero per-frame heap allocations.

## Core Capabilities (v0.1.0)

1. **Two-Pass Topological Layout Engine (`layout.odin`):**
   - Clay-inspired `Fit` (shrink-wrap with `min`/`max`), `Grow` (weighted flex with `min`/`max` freeze clamping and exact integer remainder distribution), and `Fixed` sizing.
   - Declarative scoped containers via `@(deferred_in = defer_end_container)` (`if container(&ctx, "id", {...}) { ... }`).
   - Out-of-flow overlay promotion (`z_layer`, `floating`, `.Screen` and `.Parent` anchoring) so modals and dropdowns can be declared inline anywhere in the component tree without disturbing parent layout geometry.

2. **Z-Sorted Rasterizer & Tear-Free ANSI Diff Renderer (`renderer.odin`):**
   - Double-buffered `front` and `back` `[]Cell` grids with hierarchical parent-to-child clip rectangle intersection (`node_clip`, `inner_clip`).
   - Stable `effective_z` layer sorting and in-place 50% RGB bit-shift backdrop dimming (`.Dim_Screen`, `.Dim_Rect`) for stacked modals and HUD overlays.
   - Zero-allocation hot-loop ANSI diff emitter (`screen_diff_ansi`) with incremental SGR transitions, contiguous cursor-jump elimination, and DEC Mode 2026 synchronized output (`\x1b[?2026h ... \x1b[?2026l`).

3. **Z-Aware Input, Scoped Focus & Hit-Testing Engine (`input.odin`):**
   - Reverse `z_order` mouse hit-testing with floating/modal occlusion and backdrop click detection (`was_modal_dismissed`).
   - Scoped `Tab` / `Shift+Tab` focus cycling (`focus_scope`), `F6` / `Ctrl+Tab` scope switching, and an 8-deep focus restoration history stack (`focus_history`) when modals open and close.

4. **Virtualized `xitdb` Viewports & Smooth Scrolling (`scroll.odin`):**
   - Zero-allocation persistent `Scroll_Slot` table and `ui_virtual_list` scoped container that materializes only the visible `[start_row ..< end_row]` slice from 100,000+ row `xitdb` collections (`Linked_Array_List`, `Sorted_Map`, `Array_List`).
   - Z-ordered mouse-wheel target bubbling (`hit_test_scrollable`) and proportional border scrollbar rendering (`┃` / `│`).

5. **Interactive UTF-8 Text Input & Real-Time `xitdb` Filtering (`text_input.odin`):**
   - Codepoint-exact UTF-8 cursor editing (`Left`, `Right`, `Ctrl+Left/Right`, `Home`, `End`, `Backspace`, `Delete`, `Ctrl+W/U/K`, click-to-place) with horizontal rune scrolling.
   - Telescope-style `linked_list_id` arrow-key forwarding and moment/query-cached `Xitdb_Filter`.

6. **Interactive Split-Pane Dividers, Keybinding Router & Command Palette (`splitter_keymap.odin`, `command_palette.odin`):**
   - Mouse-dragged and keyboard-driven 1-cell splitters (`ui_splitter`) with same-frame sibling geometry and clip adjustment.
   - Three-tier keybinding router (`.Scope_Only`, `.Root_And_Scopes`, `.Global_Always`) with automatic text-input shielding and `.Allow_In_Text_Input` chord support.
   - Reusable `Ctrl+P` fuzzy command palette (`ui_command_palette`) with word-boundary/consecutive-run ranking and live shortcut badge discovery.

7. **Sleipnir Actor Runtime & Terminal Backend Integration (`actor_loop.odin`, `terminal.odin`):**
   - Single-writer UI coordinator actor integrated with `sleipnir` (`package actor`) and `xitdb` (`package xitdb`), plus raw terminal mode (`termios`), `SIGWINCH` resize handling, and ANSI input sequence parsing.
