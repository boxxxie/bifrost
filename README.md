# Bifrost (`package bifrost`)

An immediate-mode, actor-driven Terminal User Interface (TUI) framework for [Odin](https://odin-lang.org/), designed to bridge [**Sleipnir (`package actor`)**](deps/sleipnir) and [**xitdb (`package xitdb`)**](deps/xitdb).

---

## Architectural Highlights

- **Subsystem Actor Concurrency (`sleipnir`):** Dedicated input, timer, and background worker actors communicate via lock-free mailboxes with a single-writer UI coordinator actor.
- **Zero-Copy Persistent State (`xitdb`):** Worker actors commit transactions to `xitdb` and send lightweight $O(1)$ moment indices (`i64`) to the UI actor, which slices virtualized viewports (`Linked_Array_List`, `Sorted_Map`, `Array_List`) directly on `context.temp_allocator`.
- **Clay-Style Two-Pass Topological Layout (`layout.odin`):** `Fit` (shrink-wrap), `Grow` (weighted flex with `min`/`max` freeze clamping and exact integer remainder distribution), `Fixed`, and out-of-flow `z_layer` overlays in two linear array passes with zero recursion.
- **Notcurses-Inspired Z-Layers & 50% RGB Backdrop Dimming (`renderer.odin`):** Inline `ui_modal` and floating dropdowns with automatic in-place 50% RGB bit-shift dimming (`Dim_Screen`, `Dim_Rect`) and DEC Mode 2026 synchronized ANSI diff output (`\x1b[?2026h ... \x1b[?2026l`).
- **Scoped Focus, Hit-Testing & Widgets (`input.odin`, `scroll.odin`, `text_input.odin`, `splitter_keymap.odin`, `command_palette.odin`):**
  - Reverse `z_order` mouse hit-testing, modal input capture, and an 8-deep focus restoration history stack.
  - Virtualized `ui_virtual_list` rendering 100,000+ `xitdb` rows in $O(1)$ layout nodes with z-aware mouse-wheel bubbling and proportional border scrollbars.
  - Byte-exact UTF-8 `ui_text_input` with Telescope-style `linked_list_id` forwarding and cached `Xitdb_Filter`.
  - Interactive 1-cell `ui_splitter` dividers, 3-tier global/scoped keybinding router, and a reusable `Ctrl+P` fuzzy `ui_command_palette`.

---

## Conductor Tracks & Documentation

- **Active Track:** [`conductor/tracks/actor_xitdb_tui_20261103/`](conductor/tracks/actor_xitdb_tui_20261103/)
  - [Track Specification (`spec.md`)](conductor/tracks/actor_xitdb_tui_20261103/spec.md)
  - [Implementation Plan (`plan.md`)](conductor/tracks/actor_xitdb_tui_20261103/plan.md)
  - [Reference Design Document (`building_an_actor_driven_odin_tui.md`)](conductor/tracks/actor_xitdb_tui_20261103/building_an_actor_driven_odin_tui.md)
