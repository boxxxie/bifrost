# Technology Stack

## Language & Dependencies
- **Language:** Odin (`dev-2026-09`+)
- **Core Ecosystem Libraries:**
  - **Sleipnir (`package actor`):** `deps/sleipnir/actor` — High-throughput, zero-GC Pony-style actor runtime (`M:N` work-stealing scheduler, intrusive MPSC / wait-free SPSC mailboxes) for UI coordinator, terminal input/timer sources, and background worker actors.
  - **xitdb (`package xitdb`):** `deps/xitdb/xitdb` — Immutable, persistent single-file structural database (`Array_List`, `Linked_Array_List`, `Hash_Map`, `Sorted_Map`, 5-layer DSL & Datalog) for lock-free $O(1)$ actor state handoffs, virtualized viewport slicing, and instant time-travel.
- **Standard Library Dependencies:**
  - `core:fmt`, `core:hash`, `core:mem`, `core:mem/virtual`, `core:strings`, `core:unicode/utf8`, `core:sys/posix`, `core:os`, `core:time`, `core:testing`

## Architecture (`package bifrost` & `package bifrost_codegen`)
- `bifrost/layout.odin`: Two-pass Clay-style topological layout solver (`Fit`, `Grow`, `Fixed`, `z_layer`, out-of-flow anchoring, `nav_overrides`, hierarchical clips, and stable `z_order`).
- `bifrost/renderer.odin`: Double-buffered `Screen` (`[]Cell`), 50% RGB backdrop dimming (`Dim_Screen`, `Dim_Rect`), `ui_modal`, border/scrollbar/text rasterizer, and DEC Mode 2026 ANSI diff emitter.
- `bifrost/focus_scope.odin`: Hierarchical focus scope tree (`Focus_Scope_Node`), Harel statechart shallow/deep history (`H` / `H*`), modal capture shielding, and two-stage `.Navigation` / `.Editing` sub-modes.
- `bifrost/spatial_nav.odin`: 2D directional navigation (`Left`/`Right`/`Up`/`Down`) with projection-overlap cone scoring, scope boundary bubbling, and explicit `nav_overrides`.
- `bifrost/input.odin`: Zero-allocation `Input_State`, reverse `z_order` mouse hit-testing, runtime `Keymap_Style` switching (`.Vim`, `.Helix`, `.Emacs`), prefix/suffix/`C-u` repeat counts, and universal `<F2>`/`<F3>`–`<F5>` style toggles.
- `bifrost/scroll.odin`: Persistent `Scroll_Slot` table, `ui_virtual_list` and `ui_virtual_table` 2D viewport slicers (`offset`, `offset_x`, `select_virtual_col_at_x`), z-aware wheel bubbling, and proportional scrollbars.
- `bifrost/text_input.odin`: Byte-exact UTF-8 `ui_text_input` widget with visual selection (`Shift+Arrows`), zero-CGO OSC 52 terminal clipboard (`Ctrl+C`/`Ctrl+X`), Telescope-style `linked_list_id` forwarding, and moment/query-cached `Xitdb_Filter`.
- `bifrost/splitter.odin`: Interactive 1-cell `ui_splitter` dividers (same-frame mouse drag, keyboard nudging, and `.Resize` sub-mode with `repeat_count`).
- `bifrost/keymap.odin` & `bifrost/codegen/codegen.odin`: Three-tier 1/2-step key-chord router, pending chord timeout, compile-time + runtime conflict detection, struct-tag reflection, and AST code generation (`tools/bifrost_gen`).
- `bifrost/status_bars.odin`: Contextual focus breadcrumb bar (`ui_focus_breadcrumb_bar`), key hint bar (`ui_key_hint_bar`), and auto-populating Which-Key overlay (`ui_which_key_overlay`).
- `bifrost/command_palette.odin`: Composable `Ctrl+P` / `M-x` fuzzy command palette (`ui_command_palette`) with subsequence scoring and automatic shortcut badge discovery.
- `bifrost/text_area.odin`: Multi-line UTF-8 text editor (`ui_text_area`) with sticky `preferred_col` 2D caret motion, dynamic line-number gutter, multi-line selection, single-pass $O(N+M)$ paste, OSC 52 clipboard, and two-stage `.Navigation`/`.Editing` sub-modes.
- `bifrost/tree.odin`: Virtualized collapsible tree (`ui_tree`) with $O(\text{visible\_rows})$ layout node materialization over 10,000+ nodes, box-drawing guides (`├─ `, `╰─ `, `│  `, `▾ `, `▸ `), `h`/`l` expand/collapse + parent jump, and `id_hash` branch persistence.
- `bifrost/tabs.odin`: Focus-scope-integrated tab bar and container (`ui_tabs`, `ui_tab_bar`) with per-tab `Focus_Scope` Deep History ($H^*$) restoration across `[` / `]`, `Alt+1..9`, header `h`/`l`, and mouse clicks.
- `bifrost/canvas.odin`: ISO/TR 11548-1 $2 \times 4$ sub-cell Unicode Braille canvas (`ui_canvas`, `Braille_Canvas`) with Bresenham line/rect/series primitives and 8-level vertical block sparklines (`ui_sparkline`).
- `bifrost/xitdb_bridge.odin`, `bifrost/ui_coordinator.odin`, `bifrost/ui_actions_effects.odin`, `bifrost/workspace_persistence.odin`, `bifrost/terminal.odin`, `bifrost/ansi_parser.odin`: Raw POSIX terminal backend, ANSI/Kitty/SGR input parser actor, `sleipnir` + `xitdb` UI coordinator actor loop, typed actor command sinks, declarative `UI_Effect` queue, and persistent workspace + keymap state in `xitdb`.

## Testing
- `odin test bifrost -vet -strict-style -vet-packages:bifrost` — 41 unit and verification tests for layout, diff rendering, z-layer dimming, focus scopes, 2D spatial nav, virtualized 2D `xitdb` scrolling, UTF-8 text selection + OSC 52, splitters, keymap styles (`Vim`/`Helix`/`Emacs`), Which-Key, and actor coordination.
- `odin test bifrost/codegen -vet -strict-style` — 3 unit tests for AST struct-tag parsing, FNV-1a dispatch generation, and compile-time chord conflict detection.
- `odin test tests -custom-attribute:scenario -vet -strict-style -vet-packages:bifrost,bifrost_tests` — 51 4-layer ATDD executable specifications covering layout, navigation, keymaps, `ui_text_area`, `ui_tree`, `ui_tabs`, `ui_canvas`/`ui_sparkline`, and `sleipnir` + `xitdb` integration tests.
