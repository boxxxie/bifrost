# Technology Stack

## Language & Dependencies
- **Language:** Odin (`dev-2026-09`+)
- **Core Ecosystem Libraries:**
  - **Sleipnir (`package actor`):** `deps/sleipnir/actor` — High-throughput, zero-GC Pony-style actor runtime (`M:N` work-stealing scheduler, intrusive MPSC / wait-free SPSC mailboxes) for UI coordinator, terminal input/timer sources, and background worker actors.
  - **xitdb (`package xitdb`):** `deps/xitdb/xitdb` — Immutable, persistent single-file structural database (`Array_List`, `Linked_Array_List`, `Hash_Map`, `Sorted_Map`, 5-layer DSL & Datalog) for lock-free $O(1)$ actor state handoffs, virtualized viewport slicing, and instant time-travel.
- **Standard Library Dependencies:**
  - `core:fmt`, `core:hash`, `core:mem`, `core:mem/virtual`, `core:strings`, `core:unicode/utf8`, `core:sys/posix`, `core:os`, `core:time`, `core:testing`

## Architecture (`package bifrost`)
- `bifrost/layout.odin`: Two-pass Clay-style topological layout solver (`Fit`, `Grow`, `Fixed`, `z_layer`, out-of-flow anchoring, hierarchical clips, and stable `z_order`).
- `bifrost/renderer.odin`: Double-buffered `Screen` (`[]Cell`), 50% RGB backdrop dimming (`Dim_Screen`, `Dim_Rect`), `ui_modal`, border/scrollbar/text rasterizer, and DEC Mode 2026 ANSI diff emitter.
- `bifrost/input.odin`: Zero-allocation `Input_State`, reverse `z_order` mouse hit-testing, modal capture shielding, focus history stack, and scoped `Tab` / `F6` navigation.
- `bifrost/scroll.odin`: Persistent `Scroll_Slot` table, `ui_virtual_list` viewport slicer for `xitdb` collections, z-aware wheel bubbling, and proportional scrollbars.
- `bifrost/text_input.odin`: Byte-exact UTF-8 `ui_text_input` widget, Telescope-style `linked_list_id` forwarding, and moment/query-cached `Xitdb_Filter`.
- `bifrost/splitter_keymap.odin`: Interactive 1-cell `ui_splitter` dividers (same-frame drag/key resize) and 3-tier global/scoped keybinding router.
- `bifrost/command_palette.odin`: Composable `Ctrl+P` fuzzy command palette (`ui_command_palette`) with subsequence scoring and automatic shortcut badge discovery.
- `bifrost/terminal.odin` & `bifrost/actor_bridge.odin`: Raw POSIX terminal backend, ANSI input parser actor, and `sleipnir` + `xitdb` UI coordinator actor loop.

## Testing
- `odin test bifrost -vet -strict-style` — Unit and verification test suites for layout, diff rendering, z-layer dimming, focus/input capture, virtualized `xitdb` scrolling, UTF-8 text filtering, splitters/keymaps, and fuzzy command palette.
- `odin test tests` — 4-layer ATDD executable specifications and `sleipnir` + `xitdb` integration tests.
